/**
 * Engine tests. The scenarios mirror real situations, including the
 * calculator flaw that motivated this project: insulin injected for a meal
 * you just ate must not be counted as excess insulin.
 *
 * Run: npm test (node --test)
 */

const { test } = require("node:test");
const assert = require("node:assert/strict");

const {
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
} = require("../engine");

// Example therapy used by the tests (NOT a recommendation): ICR 1U:10g,
// ISF 1U:35 mg/dL, half-unit pen, target 110.
const PROFILE = {
  dia_hours: 4,
  insulin_peak_min: 75,
  target_mg_dl: 110,
  low_alarm_mg_dl: 70,
  high_alarm_mg_dl: 240,
  dose_increment_u: 0.5,
  high_snooze_min: 60,
  low_snooze_min: 20,
  alarm_refire_min: 30,
  rise_escape_mg_dl: 40,
};
const ICR = 10;
const ISF = 35;

const T0 = Date.parse("2026-01-01T12:00:00Z");
const min = (n) => n * 60000;

// ------------------------------------------------------------------- IOB

test("iobFraction: full at injection, zero after DIA, monotonic decay", () => {
  assert.equal(iobFraction(0, 240, 75), 1);
  assert.equal(iobFraction(240, 240, 75), 0);
  assert.equal(iobFraction(300, 240, 75), 0);

  let prev = 1;
  for (let t = 10; t <= 240; t += 10) {
    const f = iobFraction(t, 240, 75);
    assert.ok(f <= prev, `IOB must decay (t=${t})`);
    prev = f;
  }
});

test("computeIOB: sums boluses, excludes basal", () => {
  const doses = [
    { units: 4, type: "bolus", injected_at: T0 - min(60) },
    { units: 26, type: "basal", injected_at: T0 - min(60) },
  ];
  const iob = computeIOB(doses, T0, PROFILE);
  assert.ok(iob > 0 && iob < 4, `basal excluded, bolus decayed (got ${iob})`);
});

// ------------------------------------------------------------------- COB

test("computeCOB: full before delay, decays linearly, zero when absorbed", () => {
  const meal = [{ carbs_g: 30, fpu: 0, eaten_at: T0 }];
  // 30 g at 30 g/h = 60 min absorption, starting after 15 min delay.
  assert.equal(computeCOB(meal, T0 + min(10), PROFILE), 30); // still in delay
  const mid = computeCOB(meal, T0 + min(45), PROFILE); // 30 min in = half
  assert.ok(Math.abs(mid - 15) < 0.01, `half absorbed (got ${mid})`);
  assert.equal(computeCOB(meal, T0 + min(80), PROFILE), 0);
});

test("computeCOB: FPUs act later and longer than fast carbs", () => {
  const meal = [{ carbs_g: 0, fpu: 2, eaten_at: T0 }]; // 2 FPU = 20 g over 4 h
  // fpu_delay_min = 120 (2h) — a personal calibration, not the Warsaw paper.
  assert.equal(computeCOB(meal, T0 + min(60), PROFILE), 20); // still in delay
  const later = computeCOB(meal, T0 + min(120 + 120), PROFILE); // half of 4 h
  assert.ok(Math.abs(later - 10) < 0.01, `half of FPU left (got ${later})`);
  assert.equal(computeCOB(meal, T0 + min(120 + 241), PROFILE), 0);
});

test("fpuDurationHours follows the Warsaw method", () => {
  assert.equal(fpuDurationHours(1), 3);
  assert.equal(fpuDurationHours(2), 4);
  assert.equal(fpuDurationHours(3), 5);
  assert.equal(fpuDurationHours(4), 8);
});

// ----------------------------------------------------------------- ratios

test("ratioAt picks the active segment and wraps overnight", () => {
  const segs = [
    { start_minute: 0, value: 15 },
    { start_minute: 420, value: 10 }, // 07:00
    { start_minute: 1320, value: 12 }, // 22:00
  ];
  assert.equal(ratioAt(segs, Date.parse("2026-01-01T06:00:00Z")), 15);
  assert.equal(ratioAt(segs, Date.parse("2026-01-01T12:00:00Z")), 10);
  assert.equal(ratioAt(segs, Date.parse("2026-01-01T23:00:00Z")), 12);
});

// --------------------------------------------------------------- rounding

test("doses round DOWN to the pen increment; rescue carbs round UP to 5 g", () => {
  assert.equal(roundDoseDown(3.74, 0.5), 3.5);
  assert.equal(roundDoseDown(3.99, 0.5), 3.5);
  assert.equal(roundDoseDown(4.0, 0.5), 4.0);
  assert.equal(roundDoseDown(-1, 0.5), 0);
  assert.equal(roundCarbsUp(23.7), 25);
  assert.equal(roundCarbsUp(20), 20);
});

// ------------------------------------ the common calculator flaw, fixed

test("second meal 30 min after a bolused meal still gets covered (COB-aware fix)", () => {
  // 12:00 — BG 110, ate 50 g, injected 5 U (correct per ICR 1:10).
  // 12:30 — BG 140, eating 30 g more. A naive calculator does:
  //   30/10 + (140-110)/35 - IOB(~4.7) ≈ -0.9 -> "too much insulin", 0 U.
  // But those 4.7 U are covering the 50 g still absorbing. The new 30 g
  // must get its own ~3 U.
  const doses = [{ units: 5, type: "bolus", injected_at: T0 }];
  const meals = [{ carbs_g: 50, fpu: 0, eaten_at: T0 }];

  const rec = recommendBolus({
    bg: 140,
    carbs_g: 30,
    doses,
    meals,
    icr: ICR,
    isf: ISF,
    now: T0 + min(30),
    profile: PROFILE,
  });

  assert.ok(
    rec.recommended_units >= 2.5,
    `new meal must be covered (got ${rec.recommended_units} U)`
  );
  assert.equal(rec.rescue_carbs_g, 0);
});

test("true excess insulin with no food on board yields a lower/zero dose", () => {
  // Same IOB but NOTHING eaten: now the insulin really is excess.
  const doses = [{ units: 5, type: "bolus", injected_at: T0 }];

  const rec = recommendBolus({
    bg: 140,
    carbs_g: 30,
    doses,
    meals: [], // no COB
    icr: ICR,
    isf: ISF,
    now: T0 + min(30),
    profile: PROFILE,
  });

  assert.ok(
    rec.recommended_units < 2.5,
    `without COB the dose must shrink (got ${rec.recommended_units} U)`
  );
});

// ------------------------------------------------------- rescue carbs

test("predicted low suggests rescue carbs instead of insulin", () => {
  // BG 90 with ~1.9 U still active and nothing eaten -> heading low.
  const doses = [{ units: 2, type: "bolus", injected_at: T0 - min(30) }];

  const rec = recommendBolus({
    bg: 90,
    carbs_g: 0,
    doses,
    meals: [],
    icr: ICR,
    isf: ISF,
    now: T0,
    profile: PROFILE,
  });

  assert.equal(rec.recommended_units, 0);
  assert.ok(rec.rescue_carbs_g >= 15, `needs carbs (got ${rec.rescue_carbs_g} g)`);
  assert.equal(rec.rescue_carbs_g % 5, 0, "rescue carbs in 5 g steps");
});

// ---------------------------------------------------------- high alarm

test("high alarm fires with no recent injection", () => {
  const r = evaluateHighAlarm({ bg: 250, now: T0, profile: PROFILE });
  assert.deepEqual(r, { fire: true, reason: "high" });
});

test("high alarm suppressed within 1h of the last injection, even if BG dips and re-crosses", () => {
  // Injected at 12:00. BG 250 at 12:20 -> silent. Dips to 230, back to 246
  // at 12:45 -> STILL silent: the clock counts from the injection.
  const base = { profile: PROFILE, lastDoseAt: T0, bgAtLastDose: 246 };

  assert.equal(
    evaluateHighAlarm({ ...base, bg: 250, now: T0 + min(20) }).fire,
    false
  );
  assert.equal(
    evaluateHighAlarm({ ...base, bg: 246, now: T0 + min(45) }).fire,
    false
  );
  // 12:00 + 65 min, still high -> now it fires.
  assert.equal(
    evaluateHighAlarm({ ...base, bg: 246, now: T0 + min(65) }).fire,
    true
  );
});

test("high alarm escape: sharp rise despite insulin pierces the snooze", () => {
  const r = evaluateHighAlarm({
    bg: 290, // +44 above BG at injection
    now: T0 + min(30),
    lastDoseAt: T0,
    bgAtLastDose: 246,
    profile: PROFILE,
  });
  assert.deepEqual(r, { fire: true, reason: "rising_despite_insulin" });
});

test("a fired high alarm does not re-fire immediately", () => {
  const r = evaluateHighAlarm({
    bg: 250,
    now: T0,
    lastFiredAt: T0 - min(10),
    profile: PROFILE,
  });
  assert.deepEqual(r, { fire: false, reason: "recently_fired" });
});

// ----------------------------------------------------------- low alarm

test("low alarm fires normally and is snoozed by recent carbs", () => {
  assert.equal(evaluateLowAlarm({ bg: 65, now: T0, profile: PROFILE }).fire, true);

  const snoozed = evaluateLowAlarm({
    bg: 65,
    now: T0,
    lastCarbsAt: T0 - min(10),
    profile: PROFILE,
  });
  assert.deepEqual(snoozed, { fire: false, reason: "snoozed_recent_carbs" });

  // 25 min after eating, still low -> carbs did not work, alarm again.
  assert.equal(
    evaluateLowAlarm({ bg: 65, now: T0, lastCarbsAt: T0 - min(25), profile: PROFILE })
      .fire,
    true
  );
});

test("urgent low is NEVER suppressed", () => {
  const r = evaluateLowAlarm({
    bg: 54,
    now: T0,
    lastCarbsAt: T0 - min(5), // just ate — does not matter at 54
    lastFiredAt: T0 - min(5), // just fired — does not matter either
    profile: PROFILE,
  });
  assert.deepEqual(r, { fire: true, reason: "urgent_low" });
});
