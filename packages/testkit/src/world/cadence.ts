/**
 * How often each platform *actually* re-registers, as measured (#329).
 *
 * ## Why this is a distribution and not a number
 *
 * Both adapters intend a 120s interval — `RegistrationPublisher.swift:16`
 * and `.kt:65`, pinned as a shared constant in
 * `packages/protocol/fixtures/wire.json` (#325). The hardware does
 * something else entirely, because the OS defers timers: the Pixel dozes
 * and the Mac sleeps.
 *
 * A node model that registers on a clean 120s tick makes every
 * timeout-related scenario **unable to fail**. R1 (sleep/wake), R2 (relay
 * restart) and R4 (adapter restart) have no interesting behaviour except
 * in the tail of this distribution, and the relay's own 300s departure
 * timer was tuned against it (`relay-service.ts`'s
 * `DEFAULT_NODE_DEPARTURE_TIMEOUT_MS`). Model the nominal and the suite
 * passes while the product breaks.
 *
 * ## Source
 *
 * Derived from two production relay archives covering 2026-09-23,
 * `relay-service-20260923T102201Z.log` and
 * `relay-service-20260923T203636Z.log`, by measuring the gap between
 * consecutive `registration` events per node. 534 gaps total.
 *
 * Reproducing the narrower window that the existing
 * `DEFAULT_NODE_DEPARTURE_TIMEOUT_MS` comment cites (the second archive
 * alone) gives Android p50 160s / max 2263s and Mac p50 439s / max 1127s,
 * against its recorded 160/2263 and 438/1126. That agreement is why these
 * wider numbers are trusted.
 *
 * ## The shape matters, and percentiles hid it
 *
 * **The Mac is bimodal, not long-tailed.** 55 of its 165 gaps are under
 * 130s and 79 are between 800s and 1600s, with almost nothing between —
 * two clusters, "awake and registering on time" and "asleep, registering
 * when it wakes". Sampling a lognormal fitted to its p50 would generate a
 * mass of 400-800s gaps that essentially never happen, and few of the
 * ~15-minute ones that routinely do.
 *
 * **The Pixel is unimodal with a long tail**: p50 138s against a 120s
 * nominal, decaying smoothly, with rare excursions to hours.
 *
 * Counter-intuitively the **Mac** is the worse offender at the median —
 * you would expect the phone's doze to dominate, and at p50 it is the
 * Mac's sleep that does.
 */

/** A measured bucket: gaps in `[fromSeconds, toSeconds)`, seen `count` times. */
export interface CadenceBucket {
  readonly fromSeconds: number;
  readonly toSeconds: number;
  readonly count: number;
}

export interface CadenceProfile {
  readonly platform: "mac" | "android";
  /** What the adapter intends, for contrast and for the clean-tick control. */
  readonly nominalSeconds: number;
  readonly buckets: readonly CadenceBucket[];
}

/** `wire.json`'s `registrationIntervalMs`, in seconds. */
export const NOMINAL_REGISTRATION_SECONDS = 120;

/**
 * Pixel 10 Pro. 369 gaps.
 *
 * p10 102 / p25 120 / p50 138 / p75 226 / p90 363 / max 30985.
 */
export const ANDROID_CADENCE: CadenceProfile = {
  platform: "android",
  nominalSeconds: NOMINAL_REGISTRATION_SECONDS,
  buckets: [
    { fromSeconds: 0, toSeconds: 130, count: 170 },
    { fromSeconds: 130, toSeconds: 200, count: 82 },
    { fromSeconds: 200, toSeconds: 400, count: 85 },
    { fromSeconds: 400, toSeconds: 800, count: 25 },
    { fromSeconds: 800, toSeconds: 1600, count: 4 },
    { fromSeconds: 1600, toSeconds: 3200, count: 1 },
    // One gap of 30985s - the phone was off or out of contact. Kept
    // rather than trimmed: a node silent for 8.6 hours is a real thing
    // the relay has to survive, and it is what R2 is about.
    { fromSeconds: 3200, toSeconds: 31000, count: 2 },
  ],
};

/**
 * MacBook Air M4. 165 gaps.
 *
 * p10 124 / p25 126 / p50 855 / p75 1012 / p90 1056 / max 3996. The two
 * clusters are the `0-130` and `800-1600` buckets; the near-empty
 * `130-200` bucket between them is the evidence for bimodality.
 */
export const MAC_CADENCE: CadenceProfile = {
  platform: "mac",
  nominalSeconds: NOMINAL_REGISTRATION_SECONDS,
  buckets: [
    { fromSeconds: 0, toSeconds: 130, count: 55 },
    { fromSeconds: 130, toSeconds: 200, count: 4 },
    { fromSeconds: 200, toSeconds: 400, count: 10 },
    { fromSeconds: 400, toSeconds: 800, count: 12 },
    { fromSeconds: 800, toSeconds: 1600, count: 79 },
    { fromSeconds: 1600, toSeconds: 3200, count: 4 },
    { fromSeconds: 3200, toSeconds: 4000, count: 1 },
  ],
};

/**
 * A seeded sampler, so a run is reproducible from its seed alone.
 *
 * Deliberately not `Math.random`: a scenario that fails once and cannot
 * be re-run identically is an anecdote. `mulberry32` because it is four
 * lines, has no dependency, and the statistical quality needed here is
 * "not obviously patterned" rather than cryptographic.
 */
export function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/**
 * Draws a registration gap in seconds from `profile`.
 *
 * Picks a bucket by its measured weight, then a value uniformly inside
 * it. Uniform-within-bucket is a deliberate simplification: the buckets
 * are narrow enough that the shape *between* edges does not change any
 * scenario's outcome, and pretending to know it would be false precision.
 */
export function sampleGapSeconds(profile: CadenceProfile, random: () => number): number {
  const total = profile.buckets.reduce((sum, b) => sum + b.count, 0);
  let roll = random() * total;
  for (const bucket of profile.buckets) {
    roll -= bucket.count;
    if (roll <= 0) {
      return bucket.fromSeconds + random() * (bucket.toSeconds - bucket.fromSeconds);
    }
  }
  // Floating-point slack only; the loop above covers the whole mass.
  const last = profile.buckets[profile.buckets.length - 1];
  return last.fromSeconds;
}

/**
 * The control a scenario is compared against, to prove the distribution
 * is doing work (#329 acceptance criterion 3).
 *
 * If a tail-sensitive scenario behaves the same against this as against
 * the measured profile, the model is not honouring the measurement.
 */
export function cleanTickSeconds(profile: CadenceProfile): number {
  return profile.nominalSeconds;
}
