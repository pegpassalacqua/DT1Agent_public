#!/usr/bin/env node
/**
 * Generates deterministic bolus-recommendation and alarm-evaluation
 * fixtures by running the REAL engine.js — no reimplementation, no
 * reasoning about what the answer "should" be. The Swift port
 * (DiabetesEngine's ParityTests) replays the same inputs and must match
 * every output to within 1e-9.
 *
 * Scenarios are generated with a seeded linear congruential generator
 * (not Math.random) so this script produces byte-identical output on
 * every run — required for the fixtures to be a stable, reviewable
 * artifact rather than something that silently drifts between runs.
 *
 * Usage: node scripts/generate-parity-fixtures.js > fixtures.json
 */

const engine = require("../engine");

// --------------------------------------------------------- seeded PRNG

let seed = 42;
function nextRandom() {
  // A standard 32-bit LCG (Numerical Recipes constants). Deterministic
  // and good enough for generating varied test scenarios — this is not
  // used for anything security- or medically-sensitive.
  seed = (seed * 1664525 + 1013904223) >>> 0;
  return seed / 4294967296;
}
function randomBetween(min, max) {
  return min + nextRandom() * (max - min);
}
function randomInt(min, max) {
  return Math.floor(randomBetween(min, max + 1));
}
function pick(array) {
  return array[randomInt(0, array.length - 1)];
}

const T0 = Date.parse("2026-01-01T12:00:00Z");
const min = (n) => n * 60000;

// ----------------------------------------------------- bolus scenarios

function randomBolusScenario(index) {
  const icr = pick([8, 10, 12, 15]);
  const isf = pick([25, 30, 35, 40, 50]);
  const bg = Math.round(randomBetween(50, 350));
  const carbsG = Math.round(randomBetween(0, 120));
  const fpu = Math.round(randomBetween(0, 4) * 10) / 10;

  const doseCount = randomInt(0, 3);
  const doses = [];
  for (let i = 0; i < doseCount; i++) {
    doses.push({
      units: Math.round(randomBetween(0.5, 8) * 2) / 2, // half-unit steps
      type: pick(["bolus", "correction", "basal"]),
      injected_at: T0 - min(randomInt(0, 300)),
    });
  }

  const mealCount = randomInt(0, 3);
  const meals = [];
  for (let i = 0; i < mealCount; i++) {
    meals.push({
      carbs_g: Math.round(randomBetween(0, 100)),
      fpu: Math.round(randomBetween(0, 3) * 10) / 10,
      eaten_at: T0 - min(randomInt(0, 300)),
    });
  }

  const nowOffsetMin = randomInt(-60, 60);
  const now = T0 + min(nowOffsetMin);

  const profile = {
    dia_hours: pick([3, 3.5, 4, 4.5]),
    insulin_peak_min: pick([50, 65, 75, 90]),
    target_mg_dl: pick([100, 110, 120]),
    low_alarm_mg_dl: 70,
    high_alarm_mg_dl: 240,
    urgent_low_mg_dl: 55,
    carb_absorption_g_per_h: 30,
    carb_delay_min: 15,
    fpu_delay_min: pick([60, 90, 120]),
    fpu_carb_equivalent_g: 10,
    dose_increment_u: pick([0.5, 1]),
    high_snooze_min: 60,
    low_snooze_min: 20,
    alarm_refire_min: 30,
    rise_escape_mg_dl: 40,
  };

  const input = { bg, carbs_g: carbsG, fpu, doses, meals, icr, isf, now, profile };
  const result = engine.recommendBolus(input);

  return {
    id: `bolus-${index}`,
    input: { ...input, now_offset_min: nowOffsetMin, t0_iso: new Date(T0).toISOString() },
    result,
  };
}

// ---------------------------------------------------- alarm scenarios

function randomHighAlarmScenario(index) {
  const profile = { high_alarm_mg_dl: 240, alarm_refire_min: 30, high_snooze_min: 60, rise_escape_mg_dl: 40 };
  const bg = Math.round(randomBetween(150, 320));
  const hasLastDose = nextRandom() > 0.3;
  const lastDoseOffsetMin = randomInt(0, 120);
  const bgAtLastDose = Math.round(randomBetween(150, 300));
  const hasLastFired = nextRandom() > 0.6;
  const lastFiredOffsetMin = randomInt(0, 60);
  const nowOffsetMin = randomInt(0, 120);

  const input = {
    bg,
    now: T0 + min(nowOffsetMin),
    lastDoseAt: hasLastDose ? T0 - min(lastDoseOffsetMin) : null,
    bgAtLastDose: hasLastDose ? bgAtLastDose : null,
    lastFiredAt: hasLastFired ? T0 - min(lastFiredOffsetMin) : null,
    profile,
  };
  const result = engine.evaluateHighAlarm(input);

  return {
    id: `high-alarm-${index}`,
    input: {
      ...input,
      now_offset_min: nowOffsetMin,
      last_dose_offset_min: hasLastDose ? lastDoseOffsetMin : null,
      last_fired_offset_min: hasLastFired ? lastFiredOffsetMin : null,
      t0_iso: new Date(T0).toISOString(),
    },
    result,
  };
}

function randomLowAlarmScenario(index) {
  const profile = { low_alarm_mg_dl: 70, urgent_low_mg_dl: 55, alarm_refire_min: 30, low_snooze_min: 20 };
  const bg = Math.round(randomBetween(40, 90));
  const hasLastCarbs = nextRandom() > 0.4;
  const lastCarbsOffsetMin = randomInt(0, 40);
  const hasLastFired = nextRandom() > 0.6;
  const lastFiredOffsetMin = randomInt(0, 60);
  const nowOffsetMin = randomInt(0, 60);

  const input = {
    bg,
    now: T0 + min(nowOffsetMin),
    lastCarbsAt: hasLastCarbs ? T0 - min(lastCarbsOffsetMin) : null,
    lastFiredAt: hasLastFired ? T0 - min(lastFiredOffsetMin) : null,
    profile,
  };
  const result = engine.evaluateLowAlarm(input);

  return {
    id: `low-alarm-${index}`,
    input: {
      ...input,
      now_offset_min: nowOffsetMin,
      last_carbs_offset_min: hasLastCarbs ? lastCarbsOffsetMin : null,
      last_fired_offset_min: hasLastFired ? lastFiredOffsetMin : null,
      t0_iso: new Date(T0).toISOString(),
    },
    result,
  };
}

// ------------------------------------------------------------- output

const BOLUS_COUNT = 40;
const HIGH_ALARM_COUNT = 20;
const LOW_ALARM_COUNT = 20;

const fixtures = {
  generatedAt: new Date().toISOString(),
  seed: 42,
  bolusScenarios: Array.from({ length: BOLUS_COUNT }, (_, i) => randomBolusScenario(i)),
  highAlarmScenarios: Array.from({ length: HIGH_ALARM_COUNT }, (_, i) => randomHighAlarmScenario(i)),
  lowAlarmScenarios: Array.from({ length: LOW_ALARM_COUNT }, (_, i) => randomLowAlarmScenario(i)),
};

console.log(JSON.stringify(fixtures, null, 2));
