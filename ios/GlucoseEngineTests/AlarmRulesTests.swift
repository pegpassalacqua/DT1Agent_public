import XCTest
@testable import Glucose

/// The app's alarm rules (see README → "Alarmes"). Not parity tests: the
/// rules differ from the reference engine.js on purpose.
final class AlarmRulesTests: XCTestCase {
    /// The app's real mapping: the stored target range (70...180 by
    /// default) becomes the alarm thresholds.
    private var profile = StoredTherapyProfile().toEngineProfile()
    private let now: Double = 1_800_000_000_000

    private func minutesAgo(_ m: Double) -> Double { now - m * 60000 }

    private func check(_ result: AlarmResult, fire: Bool, reason: String, line: UInt = #line) {
        XCTAssertEqual(result.fire, fire, "fire", line: line)
        XCTAssertEqual(result.reason, reason, "reason", line: line)
    }

    private func low(bg: Double, carbsAgo: Double? = nil, firedAgo: Double? = nil) -> AlarmResult {
        DosingEngine.evaluateLowAlarm(
            bg: bg, now: now,
            lastCarbsAt: carbsAgo.map { minutesAgo($0) },
            lastFiredAt: firedAgo.map { minutesAgo($0) },
            profile: profile
        )
    }

    private func high(bg: Double, doseAgo: Double? = nil, firedAgo: Double? = nil) -> AlarmResult {
        DosingEngine.evaluateHighAlarm(
            bg: bg, now: now,
            lastDoseAt: doseAgo.map { minutesAgo($0) },
            lastFiredAt: firedAgo.map { minutesAgo($0) },
            profile: profile
        )
    }

    private func forecast(_ eventual: Double, doseAgo: Double? = nil, firedAgo: Double? = nil) -> AlarmResult {
        DosingEngine.evaluateForecastAlarm(
            eventualBg: eventual, now: now,
            lastDoseAt: doseAgo.map { minutesAgo($0) },
            lastFiredAt: firedAgo.map { minutesAgo($0) },
            profile: profile
        )
    }

    // MARK: - Low: below the range, every 15 min; 20 min snooze after carbs; <=55 never snoozed

    func testLowThresholdIsTheRangeMinimum() {
        check(low(bg: 70), fire: false, reason: "above_threshold") // 70 is in range
        check(low(bg: 69), fire: true, reason: "low")
    }

    func testLowSnoozedForTwentyMinutesAfterCarbs() {
        check(low(bg: 65, carbsAgo: 19), fire: false, reason: "snoozed_recent_carbs")
        check(low(bg: 65, carbsAgo: 20), fire: true, reason: "low")
    }

    func testLowRepeatsEveryFifteenMinutes() {
        check(low(bg: 65, firedAgo: 14), fire: false, reason: "recently_fired")
        check(low(bg: 65, firedAgo: 15), fire: true, reason: "low")
    }

    func testUrgentLowIsNeverSuppressed() {
        check(low(bg: 55, carbsAgo: 1, firedAgo: 1), fire: true, reason: "urgent_low")
    }

    // MARK: - High: above the range, only if the last injection was more than 2 h ago

    func testHighThresholdIsTheRangeMaximum() {
        check(high(bg: 180), fire: false, reason: "below_threshold") // 180 is in range
        check(high(bg: 181), fire: true, reason: "high")
    }

    func testHighWaitsTwoHoursAfterInjection() {
        check(high(bg: 250, doseAgo: 119), fire: false, reason: "snoozed_recent_injection")
        check(high(bg: 250, doseAgo: 120), fire: true, reason: "high")
    }

    func testHighHasNoRisingDespiteInsulinEscape() {
        // The old engine fired here (+40 over the value at injection). Now
        // the 2 h wait always holds.
        check(high(bg: 380, doseAgo: 30), fire: false, reason: "snoozed_recent_injection")
    }

    func testHighRepeatsEveryThirtyMinutes() {
        check(high(bg: 250, firedAgo: 29), fire: false, reason: "recently_fired")
        check(high(bg: 250, firedAgo: 30), fire: true, reason: "high")
    }

    // MARK: - Forecast: projection outside the range, same 2 h condition

    func testForecastRangeBoundsAreInclusive() {
        check(forecast(180), fire: false, reason: "in_range")
        check(forecast(70), fire: false, reason: "in_range")
    }

    func testForecastOutsideRangeFiresInBothDirections() {
        check(forecast(181), fire: true, reason: "forecast_high")
        check(forecast(69), fire: true, reason: "forecast_low")
    }

    func testForecastWaitsTwoHoursAfterInjection() {
        check(forecast(220, doseAgo: 119), fire: false, reason: "snoozed_recent_injection")
        check(forecast(220, doseAgo: 120), fire: true, reason: "forecast_high")
    }

    func testForecastRepeatsEveryThirtyMinutes() {
        check(forecast(220, firedAgo: 29), fire: false, reason: "recently_fired")
        check(forecast(220, firedAgo: 30), fire: true, reason: "forecast_high")
    }

    /// No separate alarm thresholds: changing the stored range moves every
    /// alarm with it.
    func testAlarmsFollowTheConfiguredRange() {
        var stored = StoredTherapyProfile()
        stored.lowAlarmMgDl = 80
        stored.highAlarmMgDl = 160
        profile = stored.toEngineProfile()

        check(low(bg: 79), fire: true, reason: "low")
        check(low(bg: 80), fire: false, reason: "above_threshold")
        check(high(bg: 161), fire: true, reason: "high")
        check(high(bg: 160), fire: false, reason: "below_threshold")
        check(forecast(161), fire: true, reason: "forecast_high")
        check(forecast(79), fire: true, reason: "forecast_low")
        check(forecast(120), fire: false, reason: "in_range")
    }

    /// The case the alarm exists for: BG looks fine now, but a fatty meal's
    /// FPU tail (starting ~2 h after eating) is still to come.
    func testFatProteinTailRaisesForecastWhileBgIsInRange() {
        let meals = [MealInput(carbsG: 20, fpu: 4, eatenAt: minutesAgo(150))]
        let doses = [DoseInput(units: 2, type: "bolus", injectedAt: minutesAgo(150))]
        let projection = DosingEngine.recommendBolus(
            bg: 130, doses: doses, meals: meals, icr: 10, isf: 35, now: now, profile: profile
        )
        XCTAssertGreaterThan(projection.cob, 30, "most of the 40 g FPU equivalent is still on board")
        XCTAssertGreaterThan(projection.eventualBg, 180)

        check(
            DosingEngine.evaluateForecastAlarm(
                eventualBg: projection.eventualBg, now: now,
                lastDoseAt: minutesAgo(150), profile: profile
            ),
            fire: true, reason: "forecast_high"
        )
    }
}
