import Foundation

/// Direct Swift port of `medicalMath.js` — the pharmacokinetic/nutritional
/// math behind the dosing engine. Keep this file in lockstep with the JS
/// original; do not "improve" the formulas here without updating both and
/// regenerating parity fixtures (`scripts/generate-parity-fixtures.js`).
/// See medicalMath.js for citations (oref0/Loop for IOB, Pankowska et al.
/// for FPU/Warsaw method) and for which parameters are genuine
/// approximations vs. sourced from the literature.
enum MedicalMath {

    // MARK: - IOB (oref0/Loop exponential model)

    static func iobFraction(minutesSince: Double, diaMin: Double, peakMin: Double) -> Double {
        if minutesSince <= 0 { return 1 }
        if minutesSince >= diaMin { return 0 }

        let td = diaMin
        let tp = peakMin
        let tau = (tp * (1 - tp / td)) / (1 - (2 * tp) / td)
        let a = (2 * tau) / td
        let S = 1 / (1 - a + (1 + a) * exp(-td / tau))
        let t = minutesSince

        let frac =
            1 -
            S *
            (1 - a) *
            (((t * t) / (tau * td * (1 - a)) - t / tau - 1) * exp(-t / tau) + 1)
        return min(1, max(0, frac))
    }

    /// Sums IOB across every non-basal dose (bolus + correction) still
    /// active at `now`. Basal is excluded — see medicalMath.js.
    static func computeIOB(doses: [DoseInput], now: Double, profile: EngineProfile) -> Double {
        let diaMin = profile.diaHours * 60
        var iob = 0.0
        for dose in doses {
            if dose.type == "basal" { continue }
            let minutes = (now - dose.injectedAt) / 60000
            iob += dose.units * iobFraction(minutesSince: minutes, diaMin: diaMin, peakMin: profile.insulinPeakMin)
        }
        return iob
    }

    // MARK: - FPU (Warsaw method)

    /// FPU from raw macros. FPU = (fat_g × 9 + protein_g × 4) / 100.
    static func calculateFPU(fatG: Double, proteinG: Double) -> Double {
        (fatG * 9 + proteinG * 4) / 100
    }

    static func fpuDurationHours(_ fpu: Double) -> Double {
        if fpu <= 1 { return 3 }
        if fpu <= 2 { return 4 }
        if fpu <= 3 { return 5 }
        return 8
    }

    /// Remaining grams of a linear absorption starting at startMs over durMin.
    static func remainingLinear(totalG: Double, startMs: Double, durMin: Double, nowMs: Double) -> Double {
        if totalG <= 0 { return 0 }
        let elapsedMin = (nowMs - startMs) / 60000
        if elapsedMin <= 0 { return totalG }
        if elapsedMin >= durMin { return 0 }
        return totalG * (1 - elapsedMin / durMin)
    }

    // MARK: - COB

    /// Two independent, additive components per meal: fast carbs (linear
    /// absorption after carb_delay_min) and slow carbs from fat/protein
    /// (Warsaw method, linear absorption after fpu_delay_min). See
    /// medicalMath.js for why the two channels simply add.
    static func computeCOB(meals: [MealInput], now: Double, profile: EngineProfile) -> Double {
        var cob = 0.0
        for meal in meals {
            let carbDurMin = (meal.carbsG / profile.carbAbsorptionGPerH) * 60
            cob += remainingLinear(
                totalG: meal.carbsG,
                startMs: meal.eatenAt + profile.carbDelayMin * 60000,
                durMin: carbDurMin,
                nowMs: now
            )

            let fpu = meal.fpu ?? 0
            if fpu > 0 {
                let fpuGrams = fpu * profile.fpuCarbEquivalentG
                cob += remainingLinear(
                    totalG: fpuGrams,
                    startMs: meal.eatenAt + profile.fpuDelayMin * 60000,
                    durMin: fpuDurationHours(fpu) * 60,
                    nowMs: now
                )
            }
        }
        return cob
    }

    // MARK: - Ratio schedule lookup

    /// Time-of-day schedule lookup (ICR g/U or ISF mg/dL per U). start_minute
    /// is LOCAL time-of-day; pass utcOffsetMin to convert from UTC.
    static func ratioAt(segments: [ScheduleSegment], now: Double, utcOffsetMin: Double = 0) -> Double? {
        guard !segments.isEmpty else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let d = Date(timeIntervalSince1970: (now + utcOffsetMin * 60000) / 1000)
        let comps = cal.dateComponents([.hour, .minute], from: d)
        let minute = Double((comps.hour ?? 0) * 60 + (comps.minute ?? 0))

        let sorted = segments.sorted { $0.startMinute < $1.startMinute }
        var active = sorted[sorted.count - 1] // before first segment -> wrap to last
        for seg in sorted where seg.startMinute <= minute {
            active = seg
        }
        return active.value
    }
}

struct ScheduleSegment {
    let startMinute: Double
    let value: Double
}
