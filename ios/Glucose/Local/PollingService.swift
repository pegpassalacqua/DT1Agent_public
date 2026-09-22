import Foundation
import UserNotifications

/// Orchestrates a poll cycle: LibreLinkUp -> local store -> alarm
/// evaluation -> local notification. Runs from the foreground timer AND
/// from the background refresh task (BackgroundScheduler), so it must be
/// safe to call repeatedly and cheap when there is nothing new.
///
/// Because LibreLinkUp's /graph endpoint always returns the last ~12h,
/// any background wake inside that window fully recovers from a gap —
/// see BackgroundScheduler.swift.
@MainActor
final class PollingService {
    static let shared = PollingService()

    private let client = LibreLinkUpClient()
    private let store = LocalStore.shared

    /// Last LibreLinkUp failure, nil once a poll succeeds again. Surfaced
    /// in the UI — a failing fetch must never look like "no new data".
    private(set) var lastPollError: String?
    private(set) var lastPollSuccessAt: Date?

    /// Hooks installed by AlarmManager (which owns the audio session).
    /// Whether it can play sound itself right now — if so, calm alarms rely
    /// on its chime (audible even on silent) instead of a notification sound.
    var inAppSoundAvailable: () -> Bool = { false }
    /// Called after a fired alert row is stored, so the in-app alarm reacts
    /// immediately instead of on its next 60 s tick.
    var onAlertFired: () -> Void = {}
    /// Called after every poll, success or failure. Installed by AppState:
    /// without it, the screen only picked up the first fetch's data (or its
    /// error) on the next 60 s refresh — "A carregar…" for up to a minute.
    var onPollCompleted: () -> Void = {}

    enum PollError: LocalizedError {
        case notConfigured
        var errorDescription: String? { String(localized: "Enter your LibreLinkUp email and password in Settings.") }
    }

    var credentials: (email: String, password: String)? {
        var email = Keychain.get("lluEmail")
        var password = Keychain.get("lluPassword")
        #if DEBUG
        // Simulator only: lets tests configure credentials from the command
        // line. Never in release builds — UserDefaults is plain text.
        email = email ?? UserDefaults.standard.string(forKey: "lluEmail")
        password = password ?? UserDefaults.standard.string(forKey: "lluPassword")
        #endif
        guard let email, !email.isEmpty, let password, !password.isEmpty else { return nil }
        return (email, password)
    }

    /// Drops the cached LibreLinkUp session so the next request logs in
    /// again with whatever credentials are stored now. Without this, edited
    /// credentials were ignored until the app restarted.
    func resetSession() async {
        await client.signOut()
    }

    private func ensureAuthenticated() async throws {
        guard await !client.isAuthenticated else { return }
        guard let creds = credentials else { throw PollError.notConfigured }
        try await client.authenticate(email: creds.email, password: creds.password)
    }

    /// One poll cycle. Returns the number of NEW readings stored (0 if the
    /// latest LibreLinkUp value was already known).
    @discardableResult
    func pollOnce() async throws -> Int {
        defer { onPollCompleted() }
        do {
            let inserted = try await fetchAndStore()
            lastPollError = nil
            lastPollSuccessAt = Date()
            return inserted
        } catch {
            // A cancelled request (e.g. pull-to-refresh released early) is
            // not a LibreLinkUp failure — don't flag the connection for it.
            if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                lastPollError = error.localizedDescription
            }
            throw error
        }
    }

    private func fetchAndStore() async throws -> Int {
        try await ensureAuthenticated()
        let (current, history) = try await client.graph()

        var inserted = 0
        // `current` (connection.glucoseMeasurement) is a separate field from
        // the graphData history array — pylibrelinkup's own `latest()` reads
        // it in preference to history.last, and it is measurably fresher
        // (observed ~20 min ahead of the newest graphData point). It is also
        // the ONLY one carrying a trend arrow, so it goes in first: if the
        // same timestamp also shows up in history, the arrow is already
        // stored and the duplicate is simply skipped.
        if let current, store.insertReading(current) {
            inserted += 1
        }
        for reading in history where store.insertReading(reading) {
            inserted += 1
        }

        if inserted > 0, let latest = store.latestReading() {
            await evaluateAlarms(for: latest)
        }
        return inserted
    }

    /// Runs once per new reading. Only one alarm kind applies at a time,
    /// all against the one configurable target range: high above it, low
    /// below it, and the forecast alarm inside it (the case where BG looks
    /// fine now but what is still on board will take it out of range).
    private func evaluateAlarms(for reading: LReading) async {
        let profile = store.engineProfile
        let bg = reading.valueMgDl
        let now = reading.measuredAt.timeIntervalSince1970 * 1000
        let lastDoseAt = store.lastActiveDose().map { $0.injectedAt.timeIntervalSince1970 * 1000 }
        func lastFiredAt(_ type: String) -> Double? {
            store.lastFiredAlert(type: type).map { $0.createdAt.timeIntervalSince1970 * 1000 }
        }

        let type: String
        let evaluation: AlarmResult
        var alertValue = bg

        if bg > profile.highAlarmMgDl {
            type = "high"
            evaluation = DosingEngine.evaluateHighAlarm(
                bg: bg, now: now, lastDoseAt: lastDoseAt,
                lastFiredAt: lastFiredAt("high"), profile: profile
            )
        } else if bg < profile.lowAlarmMgDl {
            type = "low"
            evaluation = DosingEngine.evaluateLowAlarm(
                bg: bg, now: now,
                lastCarbsAt: store.lastCarbMeal().map { $0.eatenAt.timeIntervalSince1970 * 1000 },
                lastFiredAt: lastFiredAt("low"), profile: profile
            )
        } else {
            // The projection needs the user's own ratios; with placeholders
            // it would be a forecast for nobody.
            guard store.isTherapyProfileConfigured else { return }
            type = "forecast"
            // Same projection the "Baixa" screen shows (no new meal).
            let inputs = store.engineInputs(at: reading.measuredAt)
            let therapy = store.therapyProfile
            alertValue = DosingEngine.recommendBolus(
                bg: bg, doses: inputs.doses, meals: inputs.meals,
                icr: therapy.icrGPerU, isf: therapy.isfMgDlPerU,
                now: now, profile: profile
            ).eventualBg
            evaluation = DosingEngine.evaluateForecastAlarm(
                eventualBg: alertValue, now: now, lastDoseAt: lastDoseAt,
                lastFiredAt: lastFiredAt("forecast"), profile: profile
            )
            // Every in-range reading lands here — only log the interesting ones.
            if evaluation.reason == "in_range" { return }
        }

        // For forecast rows, valueMgDl is the PROJECTED value that triggered it.
        store.insertAlertEvent(type: type, valueMgDl: alertValue, fired: evaluation.fire,
                               reason: evaluation.reason, at: reading.measuredAt)

        if evaluation.fire {
            await fireNotification(type: type, reason: evaluation.reason, value: alertValue, currentBg: bg)
            onAlertFired()
        }
    }

    private func fireNotification(type: String, reason: String, value: Double, currentBg: Double) async {
        let content = UNMutableNotificationContent()
        if type == "low" {
            content.title = String(localized: "Low glucose")
            content.body = "\(Int(value)) mg/dL"
            content.sound = .defaultCritical
            content.interruptionLevel = .timeSensitive
        } else {
            // Calm alarms: at most ONE gentle sound. If the app is alive it
            // plays its own soft chime (audible even on silent), so the
            // notification stays quiet; otherwise the notification sounds.
            if type == "high" {
                content.title = String(localized: "High glucose")
                content.body = "\(Int(value)) mg/dL"
            } else {
                content.title = reason == "forecast_low"
                    ? String(localized: "Forecast below target")
                    : String(localized: "Forecast above target")
                content.body = String(localized: "Now \(Int(currentBg)) → forecast \(Int(value)) mg/dL")
            }
            content.sound = inAppSoundAvailable() ? nil : .default
            content.interruptionLevel = .active
        }

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// One-off (or occasional) backfill from /logbook — ~14 days of
    /// event-related readings, the maximum LibreLinkUp exposes beyond the
    /// rolling 12h /graph window. Safe to call repeatedly: insertReading
    /// dedupes by exact timestamp. Deliberately does not evaluate alarms:
    /// these are past readings, and the current one is pollOnce's job.
    @discardableResult
    func backfillLogbook() async throws -> Int {
        try await ensureAuthenticated()
        let rows = try await client.logbook()
        var inserted = 0
        for row in rows where store.insertReading(row) {
            inserted += 1
        }
        return inserted
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }
}
