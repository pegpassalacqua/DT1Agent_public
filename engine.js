/**
 * Deterministic dosing engine: IOB, COB, bolus recommendation, rescue carbs,
 * and treatment-aware alarm suppression.
 *
 * The actual pharmacokinetic/nutritional math (IOB curve, FPU/Warsaw
 * method, COB) lives in medicalMath.js, documented there against real
 * sources (oref0/Loop for IOB, Pankowska et al. for FPU) — see that file
 * for citations and for which parameters are genuine approximations vs.
 * sourced from the literature. This file is the app-specific orchestration
 * on top: turning those primitives into a dose recommendation and alarms.
 *
 * SAFETY PRINCIPLES
 * - Pure functions only: same inputs -> same outputs, fully unit-testable.
 * - No AI, no randomness, no network. This module never depends on the
 *   AI layer (Phase 5).
 * - Doses round DOWN to the pen increment; rescue carbs round UP to 5 g.
 *   When in doubt, err on the side of less insulin / more carbs.
 * - This engine SUGGESTS. The human decides.
 *
 * All timestamps are ISO strings or epoch ms; internally we use minutes.
 */

const medicalMath = require("./medicalMath");

const DEFAULTS = {
  // Clinical — reference defaults only; the app always uses the user's
  // own profile (values from their diabetes team).
  dia_hours: 3.5, // duration of insulin action
  insulin_peak_min: 75, // rapid-acting activity peak (oref0 default)
  target_mg_dl: 110,
  low_alarm_mg_dl: 70,
  high_alarm_mg_dl: 240,
  urgent_low_mg_dl: 55, // below this, alarms are NEVER suppressed

  // Carb model
  carb_absorption_g_per_h: 30, // fallback for meals logged before the speed picker existed
  carb_delay_min: 15, // digestion lag before carbs start absorbing
  fpu_delay_min: 120, // fat/protein starts acting ~2h after the meal — the original author's observed onset; the Warsaw method itself specifies no delay, see medicalMath.js
  fpu_carb_equivalent_g: 10, // 1 FPU ≈ 10 g slow carbs (Warsaw method)

  // Device
  dose_increment_u: 0.5, // half-unit pen (the app lets each user pick 1 or 0.5)

  // Alarm suppression (treatment-aware)
  high_snooze_min: 60, // high alarm silent for 1h after the LAST injection
  low_snooze_min: 20, // low alarm silent 20 min after eating carbs
  alarm_refire_min: 30, // a fired alarm does not re-fire for this long
  rise_escape_mg_dl: 40, // rise above BG-at-injection that pierces the snooze
};

/** Merges stored profile values over the defaults. */
function resolveProfile(profile = {}) {
  return { ...DEFAULTS, ...profile };
}

function toMs(t) {
  return typeof t === "number" ? t : Date.parse(t);
}

// -------------------------------------------- IOB / COB (see medicalMath.js)

const { iobFraction, fpuDurationHours, ratioAt } = medicalMath;

/** Total insulin-on-board (units) at `now`. See medicalMath.js for the model. */
function computeIOB(doses, now, profile) {
  return medicalMath.computeIOB(doses, now, resolveProfile, profile);
}

/** Total carbs-on-board (grams) at `now`. See medicalMath.js for the model. */
function computeCOB(meals, now, profile) {
  return medicalMath.computeCOB(meals, now, resolveProfile, profile);
}

// ------------------------------------------------------------- rounding

function roundDoseDown(units, increment) {
  return Math.max(0, Math.floor(units / increment + 1e-9) * increment);
}

function roundCarbsUp(grams) {
  return Math.max(0, Math.ceil(grams / 5) * 5);
}

// -------------------------------------------------------- recommendation

/**
 * Bolus recommendation that is COB-aware — the fix for a common calculator flaw.
 *
 * Standard calculators do: dose = carbs/ICR + (BG-target)/ISF - IOB, which
 * double-penalizes insulin you just injected for food you just ate. We
 * instead project the eventual BG counting BOTH active insulin and active
 * carbs, and correct from there:
 *
 *   eventualBG = BG - IOB*ISF + COB*(ISF/ICR)
 *   dose       = newCarbs/ICR + (eventualBG - target)/ISF
 *
 * Algebraically this credits IOB with the COB it is already covering.
 * If the dose comes out negative, it becomes a rescue-carbs suggestion.
 *
 * Inputs: bg (mg/dL), carbs_g/fpu of the NEW meal (0 if just correcting),
 * doses and meals = recent history rows, icr/isf = resolved ratio values.
 */
function recommendBolus({
  bg,
  carbs_g = 0,
  fpu = 0,
  doses = [],
  meals = [],
  icr,
  isf,
  now,
  profile,
}) {
  const p = resolveProfile(profile);
  const iob = computeIOB(doses, now, p);
  const cob = computeCOB(meals, now, p);

  const eventualBG = bg - iob * isf + cob * (isf / icr);

  const mealUnits = carbs_g / icr;
  const correctionUnits = (eventualBG - p.target_mg_dl) / isf;
  const totalUnits = mealUnits + correctionUnits;

  const recommended = roundDoseDown(totalUnits, p.dose_increment_u);

  const result = {
    bg,
    iob: round2(iob),
    cob: round2(cob),
    icr,
    isf,
    target_mg_dl: p.target_mg_dl,
    eventual_bg: Math.round(eventualBG),
    meal_units: round2(mealUnits),
    correction_units: round2(correctionUnits),
    total_units_unrounded: round2(totalUnits),
    recommended_units: recommended,
    rescue_carbs_g: 0,
    // The new meal's FPU do not change today's dose split here; they are
    // recorded with the meal and covered by the COB curve going forward.
    new_meal: { carbs_g, fpu },
  };

  // Predicted low: instead of insulin, suggest grams to eat.
  // grams = deficit * ICR / ISF (how many carbs offset the excess insulin).
  const projectedAfterMeal = eventualBG + (carbs_g * isf) / icr;
  if (projectedAfterMeal < p.low_alarm_mg_dl) {
    const deficit = p.target_mg_dl - projectedAfterMeal;
    result.rescue_carbs_g = roundCarbsUp((deficit * icr) / isf);
    result.recommended_units = 0;
  }

  return result;
}

// ----------------------------------------------------------------- alarms

/**
 * High alarm with treatment-aware suppression.
 * The clock counts from the LAST injection, not from the last alarm:
 * BG oscillating around the threshold within the snooze window stays silent.
 *
 * Escape hatch: if BG has risen rise_escape_mg_dl above the value at
 * injection time, the snooze is pierced (possible failed dose/site).
 */
function evaluateHighAlarm({
  bg,
  now,
  lastDoseAt = null, // last bolus/correction injection (ISO or ms)
  bgAtLastDose = null, // reading closest to that injection, if known
  lastFiredAt = null, // last time a high alarm actually fired
  profile,
}) {
  const p = resolveProfile(profile);

  if (bg < p.high_alarm_mg_dl) {
    return { fire: false, reason: "below_threshold" };
  }

  const nowMs = toMs(now);

  // Don't nag: an alarm that already fired stays quiet for alarm_refire_min.
  if (lastFiredAt !== null) {
    const sinceFired = (nowMs - toMs(lastFiredAt)) / 60000;
    if (sinceFired < p.alarm_refire_min) {
      return { fire: false, reason: "recently_fired" };
    }
  }

  if (lastDoseAt !== null) {
    const sinceDose = (nowMs - toMs(lastDoseAt)) / 60000;
    if (sinceDose < p.high_snooze_min) {
      if (
        bgAtLastDose !== null &&
        bg >= bgAtLastDose + p.rise_escape_mg_dl
      ) {
        return { fire: true, reason: "rising_despite_insulin" };
      }
      return { fire: false, reason: "snoozed_recent_injection" };
    }
  }

  return { fire: true, reason: "high" };
}

/**
 * Low alarm with treatment-aware suppression: eating carbs snoozes it for
 * low_snooze_min. Below urgent_low_mg_dl nothing ever suppresses it.
 */
function evaluateLowAlarm({
  bg,
  now,
  lastCarbsAt = null, // last meal with carbs_g > 0
  lastFiredAt = null,
  profile,
}) {
  const p = resolveProfile(profile);

  if (bg > p.low_alarm_mg_dl) {
    return { fire: false, reason: "above_threshold" };
  }

  const nowMs = toMs(now);

  if (bg <= p.urgent_low_mg_dl) {
    return { fire: true, reason: "urgent_low" }; // never suppressed
  }

  if (lastFiredAt !== null) {
    const sinceFired = (nowMs - toMs(lastFiredAt)) / 60000;
    if (sinceFired < p.alarm_refire_min) {
      return { fire: false, reason: "recently_fired" };
    }
  }

  if (lastCarbsAt !== null) {
    const sinceCarbs = (nowMs - toMs(lastCarbsAt)) / 60000;
    if (sinceCarbs < p.low_snooze_min) {
      return { fire: false, reason: "snoozed_recent_carbs" };
    }
  }

  return { fire: true, reason: "low" };
}

function round2(x) {
  return Math.round(x * 100) / 100;
}

module.exports = {
  DEFAULTS,
  resolveProfile,
  iobFraction,
  computeIOB,
  computeCOB,
  fpuDurationHours,
  ratioAt,
  roundDoseDown,
  roundCarbsUp,
  recommendBolus,
  evaluateHighAlarm,
  evaluateLowAlarm,
};
