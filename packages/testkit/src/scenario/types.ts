import type { PhysicalSignal } from "../world/node-model.js";

/** Which device a physical event happens on. */
export type DeviceId = "mac" | "pixel";

/**
 * One entry in a scenario's timeline.
 *
 * `at` is a duration from the scenario's start, written as `"10s"` or
 * `"500ms"` so the file reads like the situation it describes rather than
 * a column of milliseconds.
 */
export interface TimelineEntry {
  readonly at: string;
  readonly device: DeviceId;
  readonly event: PhysicalSignal["kind"];
  /** For `audio_blip`. */
  readonly forMs?: number;
}

/** What a scenario asserts. All optional; a scenario uses what it needs. */
export interface Expectation {
  /** At this instant, the relay's holder must be this device (or null). */
  readonly at?: string;
  readonly holderIs?: DeviceId | null;
  /** The device physically holding the audio route must be this. */
  readonly routeIs?: DeviceId | null;
  /** Across this window, at most this many holder changes. */
  readonly during?: readonly [string, string];
  readonly holderChangesAtMost?: number;
  /** Across the window, at least this many - for "it must move". */
  readonly holderChangesAtLeast?: number;
}

export interface Scenario {
  /** Stable ID from `docs/spec/scenarios.md`. Never reused. */
  readonly id: string;
  readonly title: string;
  /**
   * Set before the timeline runs. `holder` seeds the relay's belief and
   * the physical route together, which is the only consistent starting
   * point - a scenario that wants them to disagree says so in its
   * timeline.
   */
  readonly initial: {
    readonly holder?: DeviceId | null;
    readonly playing?: readonly DeviceId[];
  };
  readonly timeline: readonly TimelineEntry[];
  readonly expect: readonly Expectation[];
  /** How long to run after the last timeline entry. Default `"60s"`. */
  readonly runFor?: string;
  /**
   * Known to fail on the current build, with the reason.
   *
   * #329 criterion 5: a failing scenario is marked, never skipped, and a
   * marked scenario that starts **passing** also fails the suite — so the
   * backlog cannot rot quietly. The string is the explanation, usually an
   * issue number.
   */
  readonly expectedFail?: string;
  /** Seed for the cadence sampler, so a run is reproducible. */
  readonly seed?: number;
}

/** `"10s"` / `"500ms"` / `"2m"` → milliseconds. */
export function parseDuration(text: string): number {
  const match = /^(\d+(?:\.\d+)?)(ms|s|m)$/.exec(text.trim());
  if (!match) throw new Error(`unparseable duration: ${JSON.stringify(text)}`);
  const value = Number(match[1]);
  switch (match[2]) {
    case "ms":
      return value;
    case "s":
      return value * 1000;
    default:
      return value * 60_000;
  }
}
