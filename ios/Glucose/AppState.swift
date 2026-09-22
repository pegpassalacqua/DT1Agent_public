import Foundation
import Observation
import SwiftUI

/// Shared app state. @Observable (iOS 17) gives per-property dependency
/// tracking: a view re-renders only when a property it actually reads
/// changes — not on every refresh of everything (the old ObservableObject
/// behavior that made tab switches heavy).
///
/// All ISO date strings are parsed ONCE here, when data arrives; views
/// consume pre-built ChartPoint/MealPoint/DosePoint values and never touch
/// string parsing during render.
@MainActor
@Observable
final class AppState {
    var status: Status?
    var favorites: [FavoriteMeal] = []
    var chartPoints: [ChartPoint] = []   // full 48 h, parsed + sorted
    var home12h: [ChartPoint] = []       // pre-filtered for the home chart
    var mealPoints: [MealPoint] = []
    var dosePoints: [DosePoint] = []
    var dailyTIR: [DailyTIR] = []
    var lastError: String?
    var isOffline = false
    var lastSync: Date?
    var liveRefreshing = false
    var pendingOps: [PendingOp] = []
    /// The configured target range, observable so charts and colors update
    /// as soon as it is changed in "Ratios & targets".
    var targetRange: ClosedRange<Double>

    // Raw API rows, kept only to feed the disk cache.
    private var rawHistory: [Reading] = []
    private var rawMeals: [Meal] = []
    private var rawDoses: [Dose] = []

    var isConfigured: Bool {
        APIClient.baseURL != nil && APIClient.token != nil
    }

    @ObservationIgnored private var refreshLoopTask: Task<Void, Never>?

    init() {
        targetRange = LocalStore.shared.therapyProfile.targetRange
        loadFromCache() // instant UI on launch, even before the first request
    }

    func startAutoRefresh() {
        PollingService.shared.onPollCompleted = { [weak self] in
            Task { await self?.refresh() }
        }
        refreshLoopTask?.cancel()
        // A Timer scheduled the normal way pauses while the user is
        // scrolling/touching the screen (it runs in .default run loop mode,
        // not .common) — silently stalling refresh during active use, which
        // is exactly when staleness is most visible. An async sleep loop
        // has no such run-loop-mode dependency.
        refreshLoopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { break }
                await self?.refresh()
            }
        }
        Task { await refresh() }
    }

    /// Queue a record made while offline; it syncs on the next refresh.
    func enqueue(_ op: PendingOp) {
        pendingOps.append(op)
        Cache.save(pendingOps, as: "pendingOps")
    }

    /// Push queued records to the server (with their original timestamps).
    ///
    /// Network failures are retried forever (that's the point of the queue),
    /// but a 4xx means the server rejected the record itself — retrying can
    /// never succeed, so it is dropped and surfaced instead of silently
    /// sitting in the queue for days.
    private func flushPending() async {
        guard !pendingOps.isEmpty else { return }
        var remaining: [PendingOp] = []
        var rejected: [String] = []

        for op in pendingOps {
            do {
                switch op.kind {
                case .meal:
                    try await APIClient.logMeal(
                        carbs: op.carbs, protein: op.protein, fat: op.fat, fiber: op.fiber,
                        description: op.description, at: op.at
                    )
                case .dose:
                    try await APIClient.logInsulin(
                        units: op.units, type: op.doseType, at: op.at
                    )
                }
            } catch let error as APIError where error.isPermanent {
                let when = op.at.formatted(date: .abbreviated, time: .shortened)
                rejected.append(op.kind == .meal
                    ? String(localized: "Meal from \(when)")
                    : String(localized: "Insulin from \(when)"))
            } catch {
                remaining.append(op) // still offline — keep for next time
            }
        }

        pendingOps = remaining
        Cache.save(pendingOps, as: "pendingOps")
        if !rejected.isEmpty {
            lastError = String(localized: "Record(s) rejected and removed from the queue: \(rejected.joined(separator: ", ")). Log them again manually if still relevant.")
        }
    }

    /// Manual escape hatch: drop everything stuck in the offline queue.
    func discardPendingOps() {
        pendingOps = []
        Cache.save(pendingOps, as: "pendingOps")
    }

    func refresh() async {
        guard isConfigured else { return }
        await flushPending() // sync offline records before fetching
        do {
            async let s = APIClient.status()
            async let f = APIClient.favorites()
            async let h = APIClient.history(hours: 48)
            async let m = APIClient.meals(hours: 48)
            async let d = APIClient.doses(hours: 48)
            async let t = APIClient.dailyTIR(days: 180)
            let (newStatus, newFavs, newHistory, newMeals, newDoses, newTIR) =
                try await (s, f, h, m, d, t)

            status = newStatus
            favorites = newFavs
            rawHistory = newHistory
            rawMeals = newMeals
            rawDoses = newDoses
            dailyTIR = newTIR
            rebuildDerived()

            // Everything above is local, so it basically never fails — the
            // real "offline" state is whether the last LibreLinkUp fetch
            // worked. Without this, a failing fetch just looked like the
            // sensor had nothing new.
            targetRange = LocalStore.shared.therapyProfile.targetRange
            let poll = PollingService.shared
            isOffline = poll.lastPollError != nil
            lastError = poll.lastPollError
            if let ok = poll.lastPollSuccessAt { lastSync = ok }
            saveToCache()
        } catch {
            // Keep showing whatever we have (live or cached) and flag it.
            isOffline = true
            lastError = error.localizedDescription
        }
    }

    /// Tap-to-refresh on the hero card: pulls a fresh reading from
    /// LibreLinkUp right now, then reloads state.
    func refreshLive() async {
        guard isConfigured, !liveRefreshing else { return }
        liveRefreshing = true
        // A failure is recorded by PollingService and surfaced by refresh().
        try? await APIClient.fetchLatestLive()
        await refresh()
        liveRefreshing = false
    }

    /// Parse dates and pre-filter once per data arrival — not per render.
    private func rebuildDerived() {
        chartPoints = rawHistory.map {
            ChartPoint(id: $0.id, date: ISO.date($0.measuredAt), value: $0.valueMgDl)
        }
        let cutoff = Date().addingTimeInterval(-12 * 3600)
        home12h = chartPoints.filter { $0.date >= cutoff }
        mealPoints = rawMeals.map {
            MealPoint(id: $0.id, date: ISO.date($0.eatenAt),
                      carbsG: $0.carbsG, fpu: $0.fpu,
                      proteinG: $0.proteinG, fatG: $0.fatG, fiberG: $0.fiberG,
                      description: $0.description)
        }
        dosePoints = rawDoses.map {
            DosePoint(id: $0.id, date: ISO.date($0.injectedAt),
                      units: $0.units, type: $0.type)
        }
    }

    // MARK: - offline cache

    private func saveToCache() {
        if let status { Cache.save(status, as: "status") }
        Cache.save(favorites, as: "favorites")
        Cache.save(rawHistory, as: "history")
        Cache.save(rawMeals, as: "meals")
        Cache.save(rawDoses, as: "doses")
        Cache.save(dailyTIR, as: "dailyTIR")
    }

    private func loadFromCache() {
        if let c = Cache.load(Status.self, from: "status") {
            status = c.value
            lastSync = c.savedAt
        }
        if let c = Cache.load([FavoriteMeal].self, from: "favorites") { favorites = c.value }
        if let c = Cache.load([Reading].self, from: "history") { rawHistory = c.value }
        if let c = Cache.load([Meal].self, from: "meals") { rawMeals = c.value }
        if let c = Cache.load([Dose].self, from: "doses") { rawDoses = c.value }
        if let c = Cache.load([DailyTIR].self, from: "dailyTIR") { dailyTIR = c.value }
        if let c = Cache.load([PendingOp].self, from: "pendingOps") { pendingOps = c.value }
        rebuildDerived()
    }
}
