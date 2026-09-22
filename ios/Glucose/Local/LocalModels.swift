import Foundation
import SwiftData

/// On-device persistence. Starts empty on first launch: LibreLinkUp only
/// exposes ~12h of history via /graph (plus ~14 days of event readings via
/// /logbook), so the app accumulates its own history going forward.

@Model
final class LReading {
    /// Sentinel for "LibreLinkUp reported no trend arrow for this reading"
    /// (the graphData history never does). Kept as a sentinel rather than an
    /// optional so existing stores need no schema migration; 0 is outside
    /// the Trend enum's 1...5, so it renders as no arrow rather than "flat".
    static let unknownTrend = 0

    @Attribute(.unique) var measuredAt: Date
    var valueMgDl: Double
    var trend: Int
    var isHigh: Bool
    var isLow: Bool
    var localId: Int

    init(measuredAt: Date, valueMgDl: Double, trend: Int, isHigh: Bool, isLow: Bool, localId: Int) {
        self.measuredAt = measuredAt
        self.valueMgDl = valueMgDl
        self.trend = trend
        self.isHigh = isHigh
        self.isLow = isLow
        self.localId = localId
    }
}

@Model
final class LMeal {
    var eatenAt: Date
    var carbsG: Double
    var proteinG: Double
    var fatG: Double
    var fiberG: Double
    var fpu: Double
    var mealDescription: String?
    var localId: Int

    init(eatenAt: Date, carbsG: Double, proteinG: Double, fatG: Double, fiberG: Double, fpu: Double, mealDescription: String?, localId: Int) {
        self.eatenAt = eatenAt
        self.carbsG = carbsG
        self.proteinG = proteinG
        self.fatG = fatG
        self.fiberG = fiberG
        self.fpu = fpu
        self.mealDescription = mealDescription
        self.localId = localId
    }
}

@Model
final class LDose {
    var injectedAt: Date
    var units: Double
    var type: String
    var localId: Int

    init(injectedAt: Date, units: Double, type: String, localId: Int) {
        self.injectedAt = injectedAt
        self.units = units
        self.type = type
        self.localId = localId
    }
}

@Model
final class LFavorite {
    var name: String
    var carbsG: Double
    var fpu: Double
    var useCount: Int
    var localId: Int

    init(name: String, carbsG: Double, fpu: Double, useCount: Int, localId: Int) {
        self.name = name
        self.carbsG = carbsG
        self.fpu = fpu
        self.useCount = useCount
        self.localId = localId
    }
}

@Model
final class LAlertEvent {
    var createdAt: Date
    var type: String // "high" | "low"
    var valueMgDl: Double
    var fired: Bool
    var reason: String
    var localId: Int

    init(createdAt: Date, type: String, valueMgDl: Double, fired: Bool, reason: String, localId: Int) {
        self.createdAt = createdAt
        self.type = type
        self.valueMgDl = valueMgDl
        self.fired = fired
        self.reason = reason
        self.localId = localId
    }
}

@Model
final class LExercise {
    var startedAt: Date
    var type: String
    var intensity: String
    var durationMin: Int

    init(startedAt: Date, type: String, intensity: String, durationMin: Int) {
        self.startedAt = startedAt
        self.type = type
        self.intensity = intensity
        self.durationMin = durationMin
    }
}

@Model
final class LRecommendation {
    var createdAt: Date
    var bg: Double
    var iob: Double
    var cob: Double
    var icr: Double
    var isf: Double
    var targetMgDl: Double
    var eventualBg: Double
    var mealUnits: Double
    var correctionUnits: Double
    var recommendedUnits: Double
    var rescueCarbsG: Double
    var accepted: Bool?
    var localId: Int

    init(createdAt: Date, bg: Double, iob: Double, cob: Double, icr: Double, isf: Double,
         targetMgDl: Double, eventualBg: Double, mealUnits: Double, correctionUnits: Double,
         recommendedUnits: Double, rescueCarbsG: Double, localId: Int) {
        self.createdAt = createdAt
        self.bg = bg
        self.iob = iob
        self.cob = cob
        self.icr = icr
        self.isf = isf
        self.targetMgDl = targetMgDl
        self.eventualBg = eventualBg
        self.mealUnits = mealUnits
        self.correctionUnits = correctionUnits
        self.recommendedUnits = recommendedUnits
        self.rescueCarbsG = rescueCarbsG
        self.localId = localId
    }
}

/// Single all-day therapy profile (no time-of-day ratio schedules).
///
/// The numbers below are NOT anyone's therapy — they are placeholders so
/// the struct is never half-built. Dose and rescue suggestions stay
/// disabled until the user saves their own profile (see
/// LocalStore.isTherapyProfileConfigured). Only the target range defaults
/// to the international time-in-range consensus (70–180 mg/dL).
struct StoredTherapyProfile: Codable {
    var icrGPerU: Double = 10
    var isfMgDlPerU: Double = 40
    /// The value a dose aims for — not the range.
    var targetMgDl: Double = 110
    /// The target range (min...max, inclusive). The ONE place these bounds
    /// live: time-in-range %, calendar/streaks, chart lines, colors, and
    /// every alarm (low below it, high and forecast above/below it) read
    /// them.
    var lowAlarmMgDl: Double = 70
    var highAlarmMgDl: Double = 180
    var diaHours: Double = 4
    /// Smallest dose the pen can dial. Suggestions round DOWN to it.
    var doseIncrementU: Double = 1

    var targetRange: ClosedRange<Double> { lowAlarmMgDl...highAlarmMgDl }

    func toEngineProfile() -> EngineProfile {
        var p = EngineProfile()
        p.targetMgDl = targetMgDl
        p.lowAlarmMgDl = lowAlarmMgDl
        p.highAlarmMgDl = highAlarmMgDl
        p.diaHours = diaHours
        p.doseIncrementU = doseIncrementU
        return p
    }
}

/// Monotonic id source so on-device records keep the same Int-identifiable
/// contract the views already rely on (Reading.id, Meal.id, ...).
enum LocalID {
    static func next() -> Int {
        let key = "localNextRecordId"
        let n = UserDefaults.standard.integer(forKey: key) + 1
        UserDefaults.standard.set(n, forKey: key)
        return n
    }
}
