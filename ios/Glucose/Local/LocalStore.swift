import Foundation
import SwiftData

/// On-device data layer. Owns the SwiftData container and every
/// read/write the app needs; APIClient is a thin facade over this.
@MainActor
final class LocalStore {
    static let shared = LocalStore()

    let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    private init() {
        let schema = Schema([LReading.self, LMeal.self, LDose.self, LFavorite.self, LAlertEvent.self, LExercise.self, LRecommendation.self])
        let config = ModelConfiguration(schema: schema)
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not open the local store: \(error)")
        }
    }

    // MARK: - Therapy profile (single all-day segment; see StoredTherapyProfile)

    private static let profileKey = "storedTherapyProfile"

    /// Decoded once and kept in memory — colors read it on every render.
    private var cachedProfile: StoredTherapyProfile?

    var therapyProfile: StoredTherapyProfile {
        get {
            if let cachedProfile { return cachedProfile }
            let p = UserDefaults.standard.data(forKey: Self.profileKey)
                .flatMap { try? JSONDecoder().decode(StoredTherapyProfile.self, from: $0) }
                ?? StoredTherapyProfile()
            cachedProfile = p
            return p
        }
        set {
            cachedProfile = newValue
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: Self.profileKey)
            }
        }
    }

    /// True once the user has saved their own profile. Until then the
    /// placeholder ratios must never produce a dose or rescue suggestion.
    var isTherapyProfileConfigured: Bool {
        UserDefaults.standard.data(forKey: Self.profileKey) != nil
    }

    var engineProfile: EngineProfile { therapyProfile.toEngineProfile() }

    // MARK: - Readings

    /// Inserts if `measuredAt` is new; returns true if a row was added
    /// (mirrors db.js's UNIQUE-measured_at dedupe).
    @discardableResult
    func insertReading(_ r: LibreLinkUpClient.RawReading) -> Bool {
        let timestamp = r.timestamp
        var d = FetchDescriptor<LReading>(predicate: #Predicate { $0.measuredAt == timestamp })
        d.fetchLimit = 1
        if let row = try? context.fetch(d).first {
            // Same reading can arrive twice: once from graphData (no trend
            // arrow at all) and once as the "current" measurement (which has
            // one). Whichever lands second must not discard a known arrow,
            // so fill it in rather than just skipping the duplicate.
            if row.trend == LReading.unknownTrend, let trend = r.trend {
                row.trend = trend
                try? context.save()
            }
            return false
        }
        let row = LReading(measuredAt: r.timestamp, valueMgDl: r.valueMgDl,
                            trend: r.trend ?? LReading.unknownTrend,
                            isHigh: r.isHigh, isLow: r.isLow, localId: LocalID.next())
        context.insert(row)
        try? context.save()
        return true
    }

    func latestReading() -> LReading? {
        var d = FetchDescriptor<LReading>(sortBy: [SortDescriptor(\.measuredAt, order: .reverse)])
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    func readings(since: Date) -> [LReading] {
        let d = FetchDescriptor<LReading>(
            predicate: #Predicate { $0.measuredAt >= since },
            sortBy: [SortDescriptor(\.measuredAt, order: .forward)]
        )
        return (try? context.fetch(d)) ?? []
    }

    func readings(from start: Date, to end: Date) -> [LReading] {
        let d = FetchDescriptor<LReading>(
            predicate: #Predicate { $0.measuredAt >= start && $0.measuredAt < end },
            sortBy: [SortDescriptor(\.measuredAt, order: .forward)]
        )
        return (try? context.fetch(d)) ?? []
    }

    /// Only the two columns the daily TIR needs. Months of history is tens
    /// of thousands of rows — faulting in only these keeps it cheap.
    func readingValues(since: Date) -> [(date: Date, value: Double)] {
        var d = FetchDescriptor<LReading>(predicate: #Predicate { $0.measuredAt >= since })
        d.propertiesToFetch = [\.measuredAt, \.valueMgDl]
        return ((try? context.fetch(d)) ?? []).map { ($0.measuredAt, $0.valueMgDl) }
    }

    func readingCount() -> Int {
        (try? context.fetchCount(FetchDescriptor<LReading>())) ?? 0
    }

    /// Doses and meals the engine needs to project BG at `date`: anything
    /// still acting then (DIA and the longest FPU tail both fit in 12 h).
    func engineInputs(at date: Date) -> (doses: [DoseInput], meals: [MealInput]) {
        let since = date.addingTimeInterval(-12 * 3600)
        let doses = self.doses(since: since).map {
            DoseInput(units: $0.units, type: $0.type, injectedAt: $0.injectedAt.timeIntervalSince1970 * 1000)
        }
        let meals = self.meals(since: since).map {
            MealInput(carbsG: $0.carbsG, fpu: $0.fpu, eatenAt: $0.eatenAt.timeIntervalSince1970 * 1000)
        }
        return (doses, meals)
    }

    // MARK: - Meals

    /// `fpuOverride` is for favorites, which store an FPU but no macros —
    /// deriving it from zero protein/fat would silently record FPU 0.
    @discardableResult
    func insertMeal(carbsG: Double, proteinG: Double, fatG: Double, fiberG: Double, description: String?,
                    eatenAt: Date, fpuOverride: Double? = nil) -> LMeal {
        let fpu = fpuOverride ?? MedicalMath.calculateFPU(fatG: fatG, proteinG: proteinG)
        let row = LMeal(eatenAt: eatenAt, carbsG: carbsG, proteinG: proteinG, fatG: fatG, fiberG: fiberG,
                         fpu: fpu, mealDescription: description, localId: LocalID.next())
        context.insert(row)
        try? context.save()
        return row
    }

    func meals(since: Date) -> [LMeal] {
        let d = FetchDescriptor<LMeal>(
            predicate: #Predicate { $0.eatenAt >= since },
            sortBy: [SortDescriptor(\.eatenAt, order: .forward)]
        )
        return (try? context.fetch(d)) ?? []
    }

    func deleteMeal(localId: Int) {
        let d = FetchDescriptor<LMeal>(predicate: #Predicate { $0.localId == localId })
        if let row = try? context.fetch(d).first { context.delete(row); try? context.save() }
    }

    func updateMeal(localId: Int, carbsG: Double, proteinG: Double, fatG: Double, fiberG: Double, description: String?, eatenAt: Date) {
        let d = FetchDescriptor<LMeal>(predicate: #Predicate { $0.localId == localId })
        guard let row = try? context.fetch(d).first else { return }
        row.carbsG = carbsG; row.proteinG = proteinG; row.fatG = fatG; row.fiberG = fiberG
        row.fpu = MedicalMath.calculateFPU(fatG: fatG, proteinG: proteinG)
        row.mealDescription = description; row.eatenAt = eatenAt
        try? context.save()
    }

    // MARK: - Doses

    @discardableResult
    func insertDose(units: Double, type: String, injectedAt: Date) -> LDose {
        let row = LDose(injectedAt: injectedAt, units: units, type: type, localId: LocalID.next())
        context.insert(row)
        try? context.save()
        return row
    }

    func doses(since: Date) -> [LDose] {
        let d = FetchDescriptor<LDose>(
            predicate: #Predicate { $0.injectedAt >= since },
            sortBy: [SortDescriptor(\.injectedAt, order: .forward)]
        )
        return (try? context.fetch(d)) ?? []
    }

    func deleteDose(localId: Int) {
        let d = FetchDescriptor<LDose>(predicate: #Predicate { $0.localId == localId })
        if let row = try? context.fetch(d).first { context.delete(row); try? context.save() }
    }

    func updateDose(localId: Int, units: Double, type: String, injectedAt: Date) {
        let d = FetchDescriptor<LDose>(predicate: #Predicate { $0.localId == localId })
        guard let row = try? context.fetch(d).first else { return }
        row.units = units; row.type = type; row.injectedAt = injectedAt
        try? context.save()
    }

    func lastActiveDose() -> LDose? {
        let d = FetchDescriptor<LDose>(
            predicate: #Predicate { $0.type != "basal" },
            sortBy: [SortDescriptor(\.injectedAt, order: .reverse)]
        )
        var desc = d; desc.fetchLimit = 1
        return try? context.fetch(desc).first
    }

    func readingNear(_ date: Date, windowMin: Double = 15) -> LReading? {
        let lower = date.addingTimeInterval(-windowMin * 60)
        let upper = date.addingTimeInterval(windowMin * 60)
        let d = FetchDescriptor<LReading>(predicate: #Predicate { $0.measuredAt >= lower && $0.measuredAt <= upper })
        let rows = (try? context.fetch(d)) ?? []
        return rows.min(by: { abs($0.measuredAt.timeIntervalSince(date)) < abs($1.measuredAt.timeIntervalSince(date)) })
    }

    func lastCarbMeal() -> LMeal? {
        let d = FetchDescriptor<LMeal>(
            predicate: #Predicate { $0.carbsG > 0 },
            sortBy: [SortDescriptor(\.eatenAt, order: .reverse)]
        )
        var desc = d; desc.fetchLimit = 1
        return try? context.fetch(desc).first
    }

    // MARK: - Favorites

    func favorites() -> [LFavorite] {
        let d = FetchDescriptor<LFavorite>(sortBy: [SortDescriptor(\.useCount, order: .reverse)])
        return (try? context.fetch(d)) ?? []
    }

    func addFavorite(name: String, carbsG: Double, fpu: Double) {
        context.insert(LFavorite(name: name, carbsG: carbsG, fpu: fpu, useCount: 0, localId: LocalID.next()))
        try? context.save()
    }

    func deleteFavorite(localId: Int) {
        let d = FetchDescriptor<LFavorite>(predicate: #Predicate { $0.localId == localId })
        if let row = try? context.fetch(d).first { context.delete(row); try? context.save() }
    }

    func favorite(localId: Int) -> LFavorite? {
        let d = FetchDescriptor<LFavorite>(predicate: #Predicate { $0.localId == localId })
        return try? context.fetch(d).first
    }

    func bumpFavoriteUse(_ fav: LFavorite) {
        fav.useCount += 1
        try? context.save()
    }

    // MARK: - Alerts

    @discardableResult
    func insertAlertEvent(type: String, valueMgDl: Double, fired: Bool, reason: String, at: Date) -> LAlertEvent {
        let row = LAlertEvent(createdAt: at, type: type, valueMgDl: valueMgDl, fired: fired, reason: reason, localId: LocalID.next())
        context.insert(row)
        try? context.save()
        return row
    }

    func alerts(since: Date) -> [LAlertEvent] {
        let d = FetchDescriptor<LAlertEvent>(
            predicate: #Predicate { $0.createdAt >= since },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return (try? context.fetch(d)) ?? []
    }

    func lastFiredAlert(type: String) -> LAlertEvent? {
        let d = FetchDescriptor<LAlertEvent>(
            predicate: #Predicate { $0.type == type && $0.fired == true },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        var desc = d; desc.fetchLimit = 1
        return try? context.fetch(desc).first
    }

    // MARK: - Exercise

    func insertExercise(type: String, intensity: String, durationMin: Int, at: Date) {
        context.insert(LExercise(startedAt: at, type: type, intensity: intensity, durationMin: durationMin))
        try? context.save()
    }

    // MARK: - Recommendations

    @discardableResult
    func insertRecommendation(_ r: BolusRecommendation, at: Date) -> LRecommendation {
        let row = LRecommendation(
            createdAt: at, bg: r.bg, iob: r.iob, cob: r.cob, icr: r.icr, isf: r.isf,
            targetMgDl: r.targetMgDl, eventualBg: r.eventualBg, mealUnits: r.mealUnits,
            correctionUnits: r.correctionUnits, recommendedUnits: r.recommendedUnits,
            rescueCarbsG: r.rescueCarbsG, localId: LocalID.next()
        )
        context.insert(row)
        try? context.save()
        return row
    }

    func markRecommendation(localId: Int, accepted: Bool) {
        let d = FetchDescriptor<LRecommendation>(predicate: #Predicate { $0.localId == localId })
        guard let row = try? context.fetch(d).first else { return }
        row.accepted = accepted
        try? context.save()
    }
}
