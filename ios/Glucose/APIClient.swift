import Foundation

enum APIError: LocalizedError {
    case notConfigured
    case badStatus(Int, String)
    case notAvailable(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: String(localized: "Set up LibreLinkUp in Settings.")
        case .badStatus(let code, let body): String(localized: "Error \(code): \(body)")
        case .notAvailable(let reason): reason
        }
    }

    /// True when retrying can never succeed. Kept for the offline-queue
    /// contract in AppState even though everything is now on-device —
    /// pending ops still exist for the brief window before LibreLinkUp
    /// auth succeeds.
    var isPermanent: Bool { false }
}

/// Facade over the on-device data layer (LocalStore + LibreLinkUpClient +
/// DosingEngine) — the single API the Views call.
/// @MainActor because LocalStore (SwiftData ModelContext) is MainActor-bound.
@MainActor
struct APIClient {
    static var baseURL: URL? { URL(string: "local://on-device") }

    static var token: String? { PollingService.shared.credentials != nil ? "local" : nil }

    // MARK: - Status / live refresh

    static func status() async throws -> Status {
        let store = LocalStore.shared
        let profile = store.engineProfile
        guard let latest = store.latestReading() else {
            return Status(reading: nil, minutesAgo: nil, iobUnits: 0, cobG: 0, targetMgDl: profile.targetMgDl)
        }
        let now = Date()
        let nowMs = now.timeIntervalSince1970 * 1000
        let inputs = store.engineInputs(at: now)
        let iob = DosingEngine.computeIOB(doses: inputs.doses, now: nowMs, profile: profile)
        let cob = DosingEngine.computeCOB(meals: inputs.meals, now: nowMs, profile: profile)
        let minutesAgo = Int(Date().timeIntervalSince(latest.measuredAt) / 60)

        return Status(
            reading: reading(from: latest),
            minutesAgo: minutesAgo,
            iobUnits: (iob * 100).rounded() / 100,
            cobG: (cob * 100).rounded() / 100,
            targetMgDl: profile.targetMgDl
        )
    }

    /// Live pull straight from LibreLinkUp, run directly on-device now —
    /// no server round-trip.
    static func fetchLatestLive() async throws {
        _ = try await PollingService.shared.pollOnce()
    }

    // MARK: - History

    static func history(hours: Int) async throws -> [Reading] {
        LocalStore.shared.readings(since: Date().addingTimeInterval(-Double(hours) * 3600)).map(reading(from:))
    }

    static func favorites() async throws -> [FavoriteMeal] {
        LocalStore.shared.favorites().map {
            FavoriteMeal(id: $0.localId, name: $0.name, carbsG: $0.carbsG, fpu: $0.fpu, useCount: $0.useCount)
        }
    }

    static func meals(hours: Int = 24) async throws -> [Meal] {
        LocalStore.shared.meals(since: Date().addingTimeInterval(-Double(hours) * 3600)).map(meal(from:))
    }

    static func doses(hours: Int = 24) async throws -> [Dose] {
        LocalStore.shared.doses(since: Date().addingTimeInterval(-Double(hours) * 3600)).map(dose(from:))
    }

    static func alerts(hours: Int = 1) async throws -> [AlertEvent] {
        LocalStore.shared.alerts(since: Date().addingTimeInterval(-Double(hours) * 3600)).map {
            AlertEvent(id: $0.localId, type: $0.type, valueMgDl: $0.valueMgDl, fired: $0.fired ? 1 : 0,
                       reason: $0.reason, createdAt: ISO.fractional.string(from: $0.createdAt))
        }
    }

    /// Last computed daily TIR and what it was computed from. refresh() asks
    /// for 180 days every 60 s; recomputing meant walking every reading on
    /// the main thread each minute, although the result only changes when
    /// a reading is added (or the day rolls over).
    private static var tirCache: (key: String, value: [DailyTIR])?

    static func dailyTIR(days: Int = 180) async throws -> [DailyTIR] {
        let store = LocalStore.shared
        let range = store.therapyProfile.targetRange
        let latest = store.latestReading()?.measuredAt.timeIntervalSince1970 ?? 0
        let key = "\(days)|\(range)|\(store.readingCount())|\(latest)|\(LocalDay.formatter.string(from: Date()))"
        if let cached = tirCache, cached.key == key { return cached.value }

        var byDay: [String: (total: Int, low: Int, high: Int)] = [:]
        for r in store.readingValues(since: Date().addingTimeInterval(-Double(days) * 24 * 3600)) {
            let day = LocalDay.formatter.string(from: r.date)
            var bucket = byDay[day] ?? (0, 0, 0)
            bucket.total += 1
            if r.value < range.lowerBound { bucket.low += 1 }
            if r.value > range.upperBound { bucket.high += 1 }
            byDay[day] = bucket
        }

        let result = byDay.keys.sorted().map { day in
            let b = byDay[day]!
            let inRange = b.total - b.low - b.high
            let pct = b.total > 0 ? (Double(inRange) / Double(b.total) * 1000).rounded() / 10 : 0
            return DailyTIR(day: day, total: b.total, low: b.low, high: b.high, inRange: inRange, pctInRange: pct)
        }
        tirCache = (key, result)
        return result
    }

    struct DayDetail: Codable {
        let readings: [Reading]
        let meals: [Meal]
        let doses: [Dose]
    }

    static func day(_ date: String) async throws -> DayDetail {
        // A calendar day, not +24 h: DST days are 23 h or 25 h long.
        guard let dayStart = LocalDay.formatter.date(from: date),
              let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart)
        else {
            return DayDetail(readings: [], meals: [], doses: [])
        }
        let store = LocalStore.shared
        return DayDetail(
            readings: store.readings(from: dayStart, to: dayEnd).map(reading(from:)),
            meals: store.meals(since: dayStart).filter { $0.eatenAt < dayEnd }.map(meal(from:)),
            doses: store.doses(since: dayStart).filter { $0.injectedAt < dayEnd }.map(dose(from:))
        )
    }

    // MARK: - Logging

    @discardableResult
    static func logMeal(
        carbs: Double, protein: Double = 0, fat: Double = 0, fiber: Double = 0,
        description: String?, at date: Date? = nil
    ) async throws -> Meal {
        let row = LocalStore.shared.insertMeal(
            carbsG: carbs, proteinG: protein, fatG: fat, fiberG: fiber,
            description: description, eatenAt: date ?? Date()
        )
        return meal(from: row)
    }

    @discardableResult
    static func logFavorite(id: Int) async throws -> Meal {
        let store = LocalStore.shared
        guard let fav = store.favorite(localId: id) else { throw APIError.badStatus(404, String(localized: "favorite not found")) }
        store.bumpFavoriteUse(fav)
        let row = store.insertMeal(
            carbsG: fav.carbsG, proteinG: 0, fatG: 0, fiberG: 0, description: fav.name,
            eatenAt: Date(), fpuOverride: fav.fpu
        )
        return meal(from: row)
    }

    static func addFavorite(name: String, carbs: Double, fpu: Double) async throws {
        LocalStore.shared.addFavorite(name: name, carbsG: carbs, fpu: fpu)
    }

    static func deleteFavorite(id: Int) async throws {
        LocalStore.shared.deleteFavorite(localId: id)
    }

    static func deleteMeal(id: Int) async throws {
        LocalStore.shared.deleteMeal(localId: id)
    }

    static func deleteDose(id: Int) async throws {
        LocalStore.shared.deleteDose(localId: id)
    }

    static func updateMeal(
        id: Int, carbs: Double, protein: Double, fat: Double, fiber: Double,
        description: String?, at date: Date
    ) async throws {
        LocalStore.shared.updateMeal(localId: id, carbsG: carbs, proteinG: protein, fatG: fat, fiberG: fiber,
                                      description: description, eatenAt: date)
    }

    static func updateDose(id: Int, units: Double, type: String, at date: Date) async throws {
        LocalStore.shared.updateDose(localId: id, units: units, type: type, injectedAt: date)
    }

    @discardableResult
    static func logInsulin(
        units: Double, type: String = "bolus", at date: Date? = nil
    ) async throws -> Dose {
        let row = LocalStore.shared.insertDose(units: units, type: type, injectedAt: date ?? Date())
        return dose(from: row)
    }

    static func logExercise(type: String, intensity: String, durationMin: Int) async throws {
        LocalStore.shared.insertExercise(type: type, intensity: intensity, durationMin: durationMin, at: Date())
    }

    // MARK: - Bolus recommendation

    static func recommend(carbs: Double, fpu: Double, bg: Double? = nil)
        async throws -> RecommendationEnvelope
    {
        let store = LocalStore.shared
        guard store.isTherapyProfileConfigured else {
            throw APIError.notAvailable(String(localized: "First set up your profile in Settings → Ratios & targets (values from your doctor). Without it the app suggests no doses."))
        }
        let profile = store.engineProfile
        let now = Date()
        let nowMs = now.timeIntervalSince1970 * 1000

        let currentBg: Double
        if let bg {
            currentBg = bg
        } else if let latest = store.latestReading(), now.timeIntervalSince(latest.measuredAt) < 15 * 60 {
            currentBg = latest.valueMgDl
        } else {
            // Never compute a dose or rescue carbs from a stale reading.
            // Callers without a fresh reading must pass a measured bg
            // (Tratamento asks for one; Baixa falls back to the 15 g rule).
            throw APIError.notAvailable(String(localized: "No recent sensor reading (under 15 min)."))
        }

        let inputs = store.engineInputs(at: now)
        let result = DosingEngine.recommendBolus(
            bg: currentBg, carbsG: carbs, fpu: fpu, doses: inputs.doses, meals: inputs.meals,
            icr: store.therapyProfile.icrGPerU, isf: store.therapyProfile.isfMgDlPerU,
            now: nowMs, profile: profile
        )
        let row = store.insertRecommendation(result, at: now)

        return RecommendationEnvelope(recommendationId: row.localId, data: Recommendation(
            bg: result.bg, iob: result.iob, cob: result.cob, icr: result.icr, isf: result.isf,
            targetMgDl: result.targetMgDl, eventualBg: result.eventualBg, mealUnits: result.mealUnits,
            correctionUnits: result.correctionUnits, recommendedUnits: result.recommendedUnits,
            rescueCarbsG: result.rescueCarbsG
        ))
    }

    static func markRecommendation(id: Int, accepted: Bool) async throws {
        LocalStore.shared.markRecommendation(localId: id, accepted: accepted)
    }

    // MARK: - Therapy profile

    struct TherapyProfile {
        var icrGPerU: Double
        var isfMgDlPerU: Double
        var targetMgDl: Double
        var lowAlarmMgDl: Double
        var highAlarmMgDl: Double
        var diaHours: Double
        var doseIncrementU: Double
    }

    /// nil until the user has saved their own profile — so the settings
    /// screen starts empty instead of showing placeholder ratios as if
    /// they were someone's real values.
    static func fetchTherapyProfile() async throws -> TherapyProfile? {
        let store = LocalStore.shared
        guard store.isTherapyProfileConfigured else { return nil }
        let p = store.therapyProfile
        return TherapyProfile(icrGPerU: p.icrGPerU, isfMgDlPerU: p.isfMgDlPerU, targetMgDl: p.targetMgDl,
                               lowAlarmMgDl: p.lowAlarmMgDl, highAlarmMgDl: p.highAlarmMgDl,
                               diaHours: p.diaHours, doseIncrementU: p.doseIncrementU)
    }

    static func saveTherapyProfile(_ t: TherapyProfile) async throws {
        LocalStore.shared.therapyProfile = StoredTherapyProfile(
            icrGPerU: t.icrGPerU, isfMgDlPerU: t.isfMgDlPerU, targetMgDl: t.targetMgDl,
            lowAlarmMgDl: t.lowAlarmMgDl, highAlarmMgDl: t.highAlarmMgDl, diaHours: t.diaHours,
            doseIncrementU: t.doseIncrementU
        )
    }

    /// Tests LibreLinkUp login instead of a server /health probe. Forces a
    /// fresh login with the credentials as stored now — reusing the cached
    /// session reported "Ligado" even for a wrong password. Returns the
    /// actual failure reason (wrong password vs. rate-limited vs. outage
    /// are different problems with different fixes — "confirma a password"
    /// is bad advice for the other two).
    static func testConnection(urlString: String) async -> Result<Void, Error> {
        await PollingService.shared.resetSession()
        do {
            _ = try await PollingService.shared.pollOnce()
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Model conversion

    private static func reading(from r: LReading) -> Reading {
        Reading(id: r.localId, valueMgDl: r.valueMgDl,
                trend: r.trend == LReading.unknownTrend ? nil : r.trend,
                isHigh: r.isHigh ? 1 : 0, isLow: r.isLow ? 1 : 0,
                measuredAt: ISO.fractional.string(from: r.measuredAt))
    }

    private static func meal(from m: LMeal) -> Meal {
        Meal(id: m.localId, carbsG: m.carbsG, proteinG: m.proteinG, fatG: m.fatG, fiberG: m.fiberG,
             fpu: m.fpu, description: m.mealDescription, eatenAt: ISO.fractional.string(from: m.eatenAt))
    }

    private static func dose(from d: LDose) -> Dose {
        Dose(id: d.localId, units: d.units, type: d.type, injectedAt: ISO.fractional.string(from: d.injectedAt))
    }
}
