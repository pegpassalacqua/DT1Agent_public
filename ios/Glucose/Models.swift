import Foundation

// Decoded with .convertFromSnakeCase — property names mirror the API JSON.

struct Envelope<T: Codable>: Codable {
    let data: T
}

/// Shared formatters — creating ISO8601DateFormatter per call is expensive
/// and was the cause of visible lag when switching tabs (thousands of
/// allocations per chart render).
enum ISO {
    static let plain = ISO8601DateFormatter()
    static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func date(_ s: String) -> Date {
        fractional.date(from: s) ?? plain.date(from: s) ?? .distantPast
    }
}

/// Parses a number typed by the user. The decimal pad types a comma in
/// Portuguese (and most European) locales, and `Double("12,5")` is nil —
/// which callers used to turn into 0, silently logging a 12.5 g meal as 0 g.
func parseDecimal(_ s: String) -> Double? {
    Double(s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
}

/// "yyyy-MM-dd" keys for a local calendar day. Fixed POSIX locale and
/// Gregorian calendar: these are lookup keys, not user-facing text — a
/// device set to another calendar system would otherwise produce different
/// years and the TIR/calendar/basal-reminder keys would stop matching.
enum LocalDay {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        return f
    }()
}

struct Reading: Codable, Identifiable {
    let id: Int
    let valueMgDl: Double
    let trend: Int?
    let isHigh: Int
    let isLow: Int
    let measuredAt: String

    var date: Date { ISO.date(measuredAt) }
}

struct Status: Codable {
    let reading: Reading?
    let minutesAgo: Int?
    let iobUnits: Double
    let cobG: Double
    let targetMgDl: Double
}

struct FavoriteMeal: Codable, Identifiable {
    let id: Int
    let name: String
    let carbsG: Double
    let fpu: Double
    let useCount: Int
}

struct Meal: Codable, Identifiable {
    let id: Int
    let carbsG: Double
    let proteinG: Double
    let fatG: Double
    let fiberG: Double
    let fpu: Double // derived server-side from proteinG/fatG (Warsaw method)
    let description: String?
    let eatenAt: String
}

struct Dose: Codable, Identifiable {
    let id: Int
    let units: Double
    let type: String
    let injectedAt: String
}

struct Recommendation: Codable {
    let bg: Double
    let iob: Double
    let cob: Double
    let icr: Double
    let isf: Double
    let targetMgDl: Double
    let eventualBg: Double
    let mealUnits: Double
    let correctionUnits: Double
    let recommendedUnits: Double
    let rescueCarbsG: Double
}

struct RecommendationEnvelope: Codable {
    let recommendationId: Int
    let data: Recommendation
}

struct AlertEvent: Codable, Identifiable {
    let id: Int
    let type: String // "high" | "low"
    let valueMgDl: Double
    let fired: Int
    let reason: String
    let createdAt: String
}

struct DailyTIR: Codable, Identifiable, Equatable {
    let day: String        // "2026-07-13" (local)
    let total: Int
    let low: Int
    let high: Int
    let inRange: Int
    let pctInRange: Double

    var id: String { day }
}

/// A record made while offline, kept on-device (with its real timestamp)
/// until the server is reachable again.
struct PendingOp: Codable, Identifiable {
    enum Kind: String, Codable { case meal, dose }
    let id: UUID
    let kind: Kind
    var carbs: Double = 0
    var protein: Double = 0
    var fat: Double = 0
    var fiber: Double = 0
    var description: String?
    var units: Double = 0
    var doseType: String = "bolus"
    let at: Date
}

// MARK: - Pre-parsed chart/list models
// Built once when data arrives — views never parse ISO strings during render.

struct ChartPoint: Identifiable, Equatable {
    let id: Int
    let date: Date
    let value: Double
}

struct MealPoint: Identifiable, Equatable {
    let id: Int
    let date: Date
    let carbsG: Double
    let fpu: Double
    let proteinG: Double
    let fatG: Double
    let fiberG: Double
    let description: String?
}

struct DosePoint: Identifiable, Equatable {
    let id: Int
    let date: Date
    let units: Double
    let type: String
}

// MARK: - Presentation helpers

/// Display name for a stored dose type ("bolus" | "correction" | "basal").
enum DoseKind {
    static func label(_ type: String) -> String {
        switch type {
        case "basal": String(localized: "Basal")
        case "correction": String(localized: "Correction")
        default: String(localized: "Bolus")
        }
    }
}

enum Trend: Int {
    case fallingFast = 1, falling = 2, stable = 3, rising = 4, risingFast = 5

    var symbol: String {
        switch self {
        case .fallingFast: "arrow.down"
        case .falling: "arrow.down.right"
        case .stable: "arrow.right"
        case .rising: "arrow.up.right"
        case .risingFast: "arrow.up"
        }
    }
}

import SwiftUI

/// Red below the target range, green inside it (inclusive), orange above —
/// the same range the time-in-range % and the alarms use.
func glucoseColor(_ value: Double, range: ClosedRange<Double>) -> Color {
    if value < range.lowerBound { return .red }
    if value <= range.upperBound { return .green }
    return .orange
}
