/**
 * Every number the world model uses, with its source (#329 criterion 2).
 *
 * One file so a later hardware capture tightens the model by changing a
 * value here, not by hunting through logic. A number without a citation
 * is a guess wearing a constant's clothes, and this file is where that
 * becomes obvious.
 *
 * Sources are one of:
 *   - **measured**, with the issue or archive it came from;
 *   - **constant**, read from the shipping code or `wire.json`;
 *   - **assumed**, where nothing has measured it yet — these are the
 *     ones a capture should attack first, and they are listed together
 *     at the end so they are easy to find.
 */

export interface WorldParameters {
  // ---- measured: how long the hardware takes ----

  /**
   * Claim dispatched → audio route observed on the target.
   *
   * measured: 3340ms incoming call Mac→Pixel (#310, 2026-09-26) and
   * ~4900ms (#254). Two samples on one pair; the spread is why
   * `DEFAULT_CLAIM_WINDOW_MS` is 6000 rather than 5000.
   */
  readonly claimSettleMs: number;

  /**
   * Release dispatched → route leaves.
   *
   * measured: 341ms (#310), 781ms, 700ms, and ~2200ms (#254). Much
   * faster and much tighter than a claim, which is why ADR 0020's
   * window is asymmetric.
   */
  readonly releaseSettleMs: number;

  /**
   * A claim to a node that already holds the route.
   *
   * measured: 25ms and 26ms (#310) — `BluetoothConnectionManager` takes
   * its already-connected skip path. Modelled because a scenario that
   * treats this as a full claim will mis-time every re-assert.
   */
  readonly claimNoOpMs: number;

  // ---- constant: read from the shipping code ----

  /**
   * ADR 0010's self-cooldown. `call` and `manual_claim` are exempt
   * (`bypassesSelfCooldown`).
   *
   * constant: `SelfCooldown`, 6s.
   */
  readonly selfCooldownMs: number;

  /**
   * How long after a claim or release a node withholds its route
   * reading, reporting `observedRoutes: {}` instead.
   *
   * constant: `defaultRouteSettle`, 6s, both adapters.
   */
  readonly routeSettleMs: number;

  /**
   * The Mac's media-stop debounce.
   *
   * constant: `MediaTriggerMonitor.defaultMediaStopDebounce`, 4s (#298).
   * Exists because the Mac's media trigger watches the *default output
   * device*, which thrw itself changes on every handover.
   */
  readonly macMediaStopDebounceMs: number;

  /**
   * ADR 0019's bound on a command resolving.
   *
   * constant: `COMMAND_OUTCOME_TIMEOUT_MS` = 8000, pinned across all
   * three languages in `wire.json` (#317).
   */
  readonly commandOutcomeTimeoutMs: number;

  /** constant: `DEFAULT_AUTO_RETURN_MS`, 90s. */
  readonly autoReturnMs: number;

  /** constant: heartbeat interval, 30s, pinned in `wire.json`. */
  readonly heartbeatIntervalMs: number;

  // ---- measured: thrw's own perturbations ----

  /**
   * How long `kAudioDevicePropertyDeviceIsRunningSomewhere` reads false
   * when the *default output device* changes, even though the user's
   * media never stopped.
   *
   * measured: ~500ms, the root cause of #298 — and of #295 and #303 by
   * extension. **This is the single most important number here.** A
   * world model without it cannot reproduce the bug class that caused
   * most of September's defects, because the signal the Mac reads is
   * perturbed by thrw's own action.
   */
  readonly macDeviceChangeAudioGapMs: number;

  /**
   * The Android audio gate pauses the user's media for the duration of a
   * handover and resumes it after.
   *
   * constant: `AndroidNode`'s `audioGate.silence()` / `restore()`
   * bracketing. Modelled because #295 is thrw reading its own
   * suppression as the user stopping their music.
   */
  readonly androidGatePausesMedia: boolean;

  /**
   * The macOS gate attempts to mute and, on AirPods, **fails** — they
   * expose no readable main-element volume (#304), so `silence()`
   * declines. So the Mac's media keeps playing audibly through the
   * handover, and the signal is not perturbed by a pause the way
   * Android's is.
   *
   * measured: "volume of 74-15-F5-12-2A-21:output is unreadable; not
   * muting for handover", three occurrences, 2026-09-25.
   */
  readonly macGateMutesSuccessfully: boolean;

  // ---- assumed: nothing has measured these ----

  /**
   * assumed. Spotify's periodic buffering, which presents as
   * `STATE_BUFFERING` and is why #288 added `TRANSIENT`. Observed to
   * happen; its period was never measured.
   */
  readonly androidBufferingEveryMs: number;

  /** assumed. How long such a buffering blip lasts. */
  readonly androidBufferingForMs: number;

  /**
   * assumed. Ring → answer, for M1's "lands no later than the call being
   * answered". #310 verified it lands at answer rather than ring, but
   * did not record the interval.
   */
  readonly callRingToAnswerMs: number;
}

export const DEFAULT_PARAMETERS: WorldParameters = {
  claimSettleMs: 3340,
  releaseSettleMs: 341,
  claimNoOpMs: 26,

  selfCooldownMs: 6_000,
  routeSettleMs: 6_000,
  macMediaStopDebounceMs: 4_000,
  commandOutcomeTimeoutMs: 8_000,
  autoReturnMs: 90_000,
  heartbeatIntervalMs: 30_000,

  macDeviceChangeAudioGapMs: 500,
  androidGatePausesMedia: true,
  macGateMutesSuccessfully: false,

  androidBufferingEveryMs: 30_000,
  androidBufferingForMs: 800,
  callRingToAnswerMs: 4_000,
};

/**
 * The four `assumed` parameters, named so a hardware capture knows what
 * to go after and a reader knows what not to trust.
 */
export const ASSUMED_PARAMETERS: readonly (keyof WorldParameters)[] = [
  "androidBufferingEveryMs",
  "androidBufferingForMs",
  "callRingToAnswerMs",
  // Measured once, on one pair, with no distribution behind it - #254's
  // own handoff says exactly that, so it is listed here rather than
  // among the trusted figures.
  "claimSettleMs",
];
