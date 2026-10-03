import { describe, expect, it } from "vitest";

import {
  ANDROID_CADENCE,
  MAC_CADENCE,
  NOMINAL_REGISTRATION_SECONDS,
  cleanTickSeconds,
  mulberry32,
  sampleGapSeconds,
} from "../src/world/cadence.js";

/**
 * #329 acceptance criterion 3. These assert the *measurement* is being
 * honoured, not that a random number generator works.
 */
describe("registration cadence", () => {
  function draw(profile: typeof MAC_CADENCE, n: number, seed = 1): number[] {
    const random = mulberry32(seed);
    return Array.from({ length: n }, () => sampleGapSeconds(profile, random));
  }

  function median(xs: number[]): number {
    const sorted = [...xs].sort((a, b) => a - b);
    return sorted[Math.floor(sorted.length / 2)];
  }

  it("is reproducible from its seed alone", () => {
    // A scenario that fails once and cannot be re-run identically is an
    // anecdote, which is the whole reason this is seeded.
    expect(draw(MAC_CADENCE, 50, 42)).toEqual(draw(MAC_CADENCE, 50, 42));
  });

  it("gives different runs for different seeds", () => {
    expect(draw(MAC_CADENCE, 50, 1)).not.toEqual(draw(MAC_CADENCE, 50, 2));
  });

  /**
   * The headline measurement: both platforms routinely exceed the 120s
   * they intend. A model that did not reproduce this would make every
   * timeout scenario unable to fail.
   */
  it("exceeds the nominal interval far more often than not", () => {
    for (const profile of [MAC_CADENCE, ANDROID_CADENCE]) {
      const over = draw(profile, 2000).filter((g) => g > NOMINAL_REGISTRATION_SECONDS);
      expect(over.length / 2000).toBeGreaterThan(0.5);
    }
  });

  /**
   * The Mac's median gap is ~855s against a 120s nominal — over 7x. This
   * is the number that makes a 360s signal-expiry bound (the fix
   * retracted on #316) unworkable, so it is worth pinning.
   */
  it("reproduces the Mac's median of roughly 855s", () => {
    expect(median(draw(MAC_CADENCE, 4000))).toBeGreaterThan(600);
    expect(median(draw(MAC_CADENCE, 4000))).toBeLessThan(1100);
  });

  it("reproduces the Pixel's much tighter median", () => {
    const m = median(draw(ANDROID_CADENCE, 4000));
    expect(m).toBeGreaterThan(100);
    expect(m).toBeLessThan(260);
  });

  /**
   * **The structural finding.** The Mac is bimodal: a cluster under 130s
   * ("awake, registering on time") and another at 800-1600s ("asleep,
   * registers on wake"), with a near-empty gap between.
   *
   * Asserted because a lognormal fitted to the Mac's p50 would put most
   * of its mass in 400-800s — values that essentially never occur — and
   * almost none in the ~15-minute range that routinely does. Getting this
   * wrong would make the model *look* calibrated while generating
   * hardware behaviour that does not happen.
   */
  it("keeps the Mac bimodal rather than smoothing it into a tail", () => {
    const gaps = draw(MAC_CADENCE, 4000);
    const awake = gaps.filter((g) => g < 130).length;
    const asleep = gaps.filter((g) => g >= 800 && g < 1600).length;
    const between = gaps.filter((g) => g >= 130 && g < 400).length;

    expect(awake).toBeGreaterThan(500);
    expect(asleep).toBeGreaterThan(500);
    // The trough is the evidence: both clusters individually outweigh
    // everything between them.
    expect(between).toBeLessThan(awake);
    expect(between).toBeLessThan(asleep);
  });

  it("keeps the Pixel unimodal, decaying from the nominal", () => {
    const gaps = draw(ANDROID_CADENCE, 4000);
    const near = gaps.filter((g) => g < 130).length;
    const mid = gaps.filter((g) => g >= 130 && g < 400).length;
    const far = gaps.filter((g) => g >= 400).length;

    // Monotone decay, which is what "unimodal with a long tail" means
    // here and is the opposite of the Mac's shape.
    expect(near).toBeGreaterThan(mid);
    expect(mid).toBeGreaterThan(far);
  });

  /**
   * The Pixel's worst observed gap is 8.6 hours. Kept rather than
   * trimmed as an outlier: a node silent that long is a real thing the
   * relay must survive, and reproducing it is what R2 is for.
   */
  it("can still draw the multi-hour excursions that were observed", () => {
    const worst = Math.max(...draw(ANDROID_CADENCE, 20000));
    expect(worst).toBeGreaterThan(3200);
  });

  it("offers a clean tick as the control to compare against", () => {
    expect(cleanTickSeconds(MAC_CADENCE)).toBe(NOMINAL_REGISTRATION_SECONDS);
    expect(cleanTickSeconds(ANDROID_CADENCE)).toBe(NOMINAL_REGISTRATION_SECONDS);
  });
});
