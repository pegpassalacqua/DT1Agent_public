/**
 * medicalMath.js — the pharmacokinetic/nutritional math behind the dosing
 * engine, documented against real sources (not invented formulas).
 *
 * This file answers "why does the app calculate it this way?" for every
 * number that affects a dose or an alarm. Each function below states:
 *   1. What it computes
 *   2. The source it is based on
 *   3. Where it is a genuine approximation (no source found) — flagged
 *      explicitly rather than presented as settled science
 *
 * Verified against real sources on 2026-07-15 (see README section at the
 * bottom of this file for the verification log). Nothing here should be
 * treated as medical advice — it is a model that SUGGESTS; the user and
 * their care team decide.
 */

// ============================================================ IOB — Insulin

/**
 * IOB — Insulin On Board
 * ======================
 * SOURCE: the "exponential" (bilinear) insulin activity model used by
 * oref0 (OpenAPS reference implementation) and Loop. Verified 2026-07-15
 * against oref0's own IOB documentation — the formula below is a direct
 * match, not a paraphrase:
 *
 *   tau = tp*(1-tp/td) / (1-2*tp/td)
 *   a   = 2*tau/td
 *   S   = 1 / (1-a+(1+a)*exp(-td/tau))
 *   IOB(t) = 1 - S*(1-a)*((t²/(tau*td*(1-a)) - t/tau - 1)*e^(-t/tau) + 1)
 *
 * where td = Duration of Insulin Action (DIA) in minutes, tp = time-to-peak
 * activity in minutes, t = minutes since injection.
 *
 * PARAMETERS — both are patient/insulin-specific and MUST come from the
 * prescribing clinician, not guessed:
 *   - peak time (tp): oref0 documents 50–120 min for rapid-acting insulins
 *     (default 75 min), 35–100 min for ultra-rapid (e.g. Fiasp/Lyumjev).
 *     Lispro/aspart sit at the oref0 default of 75 min.
 *   - DIA (td): commonly 3–6h depending on the individual and insulin;
 *     configurable per-user in `profile.dia_hours`, not hardcoded here.
 *
 * This is a curve model, not a straight-line decay: activity is low right
 * after injection, ramps up to a peak around `tp`, then decays to zero by
 * `td`. Basal insulin is DELIBERATELY excluded from IOB — it is modeled
 * as covering background metabolic need, not meal spikes, matching how
 * every open-source APS (OpenAPS/Loop/AndroidAPS) treats it.
 *
 * @param {number} minutesSince - minutes elapsed since the injection
 * @param {number} diaMin - Duration of Insulin Action, in MINUTES
 * @param {number} peakMin - time-to-peak activity, in MINUTES
 * @returns {number} fraction of the dose still active, 0..1
 */
function iobFraction(minutesSince, diaMin, peakMin) {
  if (minutesSince <= 0) return 1;
  if (minutesSince >= diaMin) return 0;

  const td = diaMin;
  const tp = peakMin;
  const tau = (tp * (1 - tp / td)) / (1 - (2 * tp) / td);
  const a = (2 * tau) / td;
  const S = 1 / (1 - a + (1 + a) * Math.exp(-td / tau));
  const t = minutesSince;

  const frac =
    1 -
    S *
      (1 - a) *
      (((t * t) / (tau * td * (1 - a)) - t / tau - 1) * Math.exp(-t / tau) + 1);
  return Math.min(1, Math.max(0, frac));
}

/**
 * Sums IOB across every non-basal dose (bolus + correction) still active
 * at `now`. See iobFraction() above for the per-dose curve and why basal
 * is excluded.
 */
function computeIOB(doses, now, resolveProfile, profile) {
  const p = resolveProfile(profile);
  const nowMs = typeof now === "number" ? now : Date.parse(now);
  const diaMin = p.dia_hours * 60;

  let iob = 0;
  for (const dose of doses) {
    if (dose.type === "basal") continue;
    const injectedMs = typeof dose.injected_at === "number"
      ? dose.injected_at : Date.parse(dose.injected_at);
    const minutes = (nowMs - injectedMs) / 60000;
    iob += dose.units * iobFraction(minutes, diaMin, p.insulin_peak_min);
  }
  return iob;
}

// ================================================== COB — Carbs on board

/**
 * FPU (Fat-Protein Units) — the Warsaw method
 * ============================================
 * SOURCE: Pankowska E, Błazik M, Groele L, et al. — the "Warsaw method"
 * for dosing high-fat/high-protein meals on insulin pumps (published in
 * Diabetes Technology & Therapeutics, 2012). Verified 2026-07-15 against
 * independent summaries of the original method (multiple clinical/patient
 * references agree on these two numbers):
 *
 *   1 FPU = 100 kcal from fat + protein combined
 *         = (fat_g × 9 + protein_g × 4) / 100
 *
 *   1 FPU is dosed as if it were 10 g of carbohydrate — i.e. the extra
 *   insulin for the fat/protein load = (FPU × 10) / ICR, using the SAME
 *   insulin-to-carb ratio as normal meals.
 *
 * CONFIRMED — this app's `fpu_carb_equivalent_g = 10` matches the Warsaw
 * method exactly. No change made.
 *
 * Extended-bolus duration table — also confirmed against the original
 * method:
 *
 *     FPU        Duration of extended delivery
 *     ≤ 1        3 hours
 *     ≤ 2        4 hours
 *     ≤ 3        5 hours
 *     > 3        8 hours
 *
 * CONFIRMED — this app's fpuDurationHours() below matches exactly.
 *
 * ⚠️ WHAT IS *NOT* FROM THE ORIGINAL METHOD (engineering approximation):
 * The Warsaw method specifies how long an extended bolus should be
 * DELIVERED on a pump — it does not specify a "delay before the fat/
 * protein starts raising blood glucose". This app models that delay via
 * `fpu_delay_min`, a tunable parameter, not a number from the paper.
 *
 * UPDATED 2026-07-15: default changed from 60 min to 120 min, based on
 * the original author's own observed pattern (high-fat meals visibly
 * start raising BG closer to 2h post-meal than 1h). This is a case of
 * personal calibration overriding a generic engineering guess — exactly the kind
 * of adjustment this parameter exists to allow. If future data suggests
 * yet another value fits better, change `fpu_delay_min` in the profile,
 * not this file.
 */
/**
 * FPU from raw macros — the actual Warsaw method formula.
 * SOURCE: confirmed 2026-07-15 (same verification pass as the rest of this
 * file): 1 FPU = 100 kcal from fat + protein combined, using the standard
 * Atwater factors (fat = 9 kcal/g, protein = 4 kcal/g).
 *
 *   FPU = (fat_g × 9 + protein_g × 4) / 100
 *
 * This lets the user log FACTS (grams of fat/protein from a label) instead
 * of estimating FPU directly — the app derives it, rather than asking for
 * a guess dressed up as data entry.
 *
 * Fiber is NOT part of this formula. We looked for a validated grams-to-
 * hours (or grams-to-FPU) conversion for dietary fiber and found none —
 * only qualitative descriptions ("soluble fiber slows gastric emptying").
 * The ADA's own guidance (checked 2026-07-15) advises AGAINST inventing a
 * fixed subtraction/adjustment for fiber, recommending individual
 * monitoring instead. So: fiber grams are recorded (useful context for
 * spotting the user's own patterns, including for the chat assistant) but
 * deliberately do NOT change the COB curve — that would be a fabricated
 * formula, not a sourced one.
 */
function calculateFPU(fat_g = 0, protein_g = 0) {
  return (fat_g * 9 + protein_g * 4) / 100;
}

function fpuDurationHours(fpu) {
  if (fpu <= 1) return 3;
  if (fpu <= 2) return 4;
  if (fpu <= 3) return 5;
  return 8;
}

/** Remaining grams of a linear absorption starting at startMs over durMin. */
function remainingLinear(totalG, startMs, durMin, nowMs) {
  if (totalG <= 0) return 0;
  const elapsedMin = (nowMs - startMs) / 60000;
  if (elapsedMin <= 0) return totalG; // not started absorbing yet
  if (elapsedMin >= durMin) return 0;
  return totalG * (1 - elapsedMin / durMin);
}

/**
 * Fast-carb absorption rate: fixed 30 g/h approximation
 * ========================================================
 * Not sourced from a specific study — a common simplification also used
 * by other open-source dosing systems as a default. Considered (and
 * rejected) two alternatives:
 *
 *   - Loop's "fast/medium/slow" picker: rejected because it asks the user
 *     to manually judge a category rather than log facts — the opposite
 *     of what was wanted here.
 *   - A fiber-grams-based automatic adjustment: rejected because no
 *     validated gram-to-hours (or gram-to-speed) formula exists in the
 *     literature (checked 2026-07-15) — the ADA explicitly advises against
 *     inventing a fixed fiber adjustment, recommending individual
 *     monitoring instead. Fabricating a formula here would be worse than
 *     just keeping the flat rate honestly labeled as an approximation.
 *
 * Fiber grams ARE still recorded per meal (see calculateFPU note above) —
 * as context for spotting the user's own patterns over time, not as an
 * input to this formula.
 */

/**
 * COB — Carbohydrates On Board
 * =============================
 * Two independent, additive components per meal:
 *
 * 1. FAST CARBS (the `carbs_g` field) — LINEAR absorption over the meal's
 *    chosen speed category (see CARB_SPEED_HOURS above), starting after a
 *    short digestion lag (`carb_delay_min`, default 15 min — not itself
 *    sourced from a study, a reasonable digestion-lag assumption).
 *
 * 2. SLOW CARBS FROM FAT/PROTEIN (the `fpu` field) — modeled per the
 *    Warsaw method above: converted to a carb-equivalent (FPU × 10 g),
 *    starting after `fpu_delay_min` (see note above — 2h, a personal
 *    calibration, not from the literature) and absorbing LINEARLY over the
 *    Warsaw-method duration table.
 *
 * The two channels run in parallel and simply add up — this is exactly
 * how the "second meal 30 min after a bolused meal still gets covered"
 * fix (the reason this whole engine exists) works: insulin already
 * covering yesterday's fast carbs doesn't double-count against new food.
 */
function computeCOB(meals, now, resolveProfile, profile) {
  const p = resolveProfile(profile);
  const nowMs = typeof now === "number" ? now : Date.parse(now);

  let cob = 0;
  for (const meal of meals) {
    const eatenMs = typeof meal.eaten_at === "number"
      ? meal.eaten_at : Date.parse(meal.eaten_at);

    const carbDurMin = (meal.carbs_g / p.carb_absorption_g_per_h) * 60;
    cob += remainingLinear(
      meal.carbs_g,
      eatenMs + p.carb_delay_min * 60000,
      carbDurMin,
      nowMs
    );

    const fpu = meal.fpu || 0;
    if (fpu > 0) {
      const fpuGrams = fpu * p.fpu_carb_equivalent_g;
      cob += remainingLinear(
        fpuGrams,
        eatenMs + p.fpu_delay_min * 60000,
        fpuDurationHours(fpu) * 60,
        nowMs
      );
    }
  }
  return cob;
}

// =============================================================== Ratios

/**
 * Time-of-day schedule lookup (ICR g/U or ISF mg/dL per U). Not a medical
 * formula — just picks which schedule segment is active "now", wrapping
 * past midnight. start_minute is LOCAL time-of-day; pass utcOffsetMin to
 * convert from UTC (e.g. 60 for Portugal summer time, WEST).
 */
function ratioAt(segments, now, utcOffsetMin = 0) {
  if (!segments || segments.length === 0) return null;
  const nowMs = typeof now === "number" ? now : Date.parse(now);
  const d = new Date(nowMs + utcOffsetMin * 60000);
  const minute = d.getUTCHours() * 60 + d.getUTCMinutes();

  const sorted = [...segments].sort((a, b) => a.start_minute - b.start_minute);
  let active = sorted[sorted.length - 1]; // before first segment -> wrap to last
  for (const seg of sorted) {
    if (seg.start_minute <= minute) active = seg;
  }
  return active.value;
}

module.exports = {
  iobFraction,
  computeIOB,
  calculateFPU,
  fpuDurationHours,
  computeCOB,
  ratioAt,
};

/**
 * ============================================================
 * VERIFICATION LOG (2026-07-15)
 * ============================================================
 * Checked against live sources before writing the documentation above:
 *
 * 1. oref0 IOB exponential model — confirmed formula (tau/a/S) and peak
 *    time ranges (50–120 min rapid-acting, default 75) match this file
 *    exactly. Source referenced in oref0's own docs: a Loop GitHub
 *    engineering discussion (github.com/LoopKit/Loop/issues/388).
 *
 * 2. Warsaw method (Pankowska et al., Diabetes Technol Ther 2012) — the
 *    original paper itself was not reachable directly, but its numbers
 *    are independently and consistently reproduced across multiple
 *    diabetes-technology calculator references:
 *      - 1 FPU = 100 kcal fat+protein combined: CONFIRMED
 *      - 1 FPU ≈ 10 g carb-equivalent for insulin dosing: CONFIRMED
 *      - Duration table (1→3h, 2→4h, 3→5h, >3→8h): CONFIRMED
 *
 * 3. Fast-carb absorption rate (30 g/h) and both delay parameters
 *    (carb_delay_min=15, fpu_delay_min=60): NOT independently sourced.
 *    These are reasonable, commonly-used engineering approximations
 *    (similar simplifications appear in other open-source systems) but
 *    are NOT a direct citation from a specific study. Flagged above at
 *    the relevant functions rather than presented as settled fact.
 *
 * No values were changed as a result of this check — everything already
 * in the engine matched the sources found, except the two explicitly
 * flagged approximations, which have no clearer literature value to
 * replace them with (hence: kept, but documented honestly, and exposed
 * as configurable in the profile so they can be tuned against real data).
 */
