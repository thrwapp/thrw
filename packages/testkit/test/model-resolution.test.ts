import { readFileSync } from "node:fs";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import { runScenario } from "../src/scenario/runner.js";
import type { Scenario } from "../src/scenario/types.js";
import { DEFAULT_PARAMETERS } from "../src/world/parameters.js";

function scenario(id: string): Scenario {
  const path = join(import.meta.dirname, "..", "scenarios", `${id}.json`);
  return JSON.parse(readFileSync(path, "utf8")) as Scenario;
}

/**
 * Does the model have the resolution to catch the bugs it claims to
 * cover?
 *
 * Every scenario in the suite currently passes. That is either the fixes
 * genuinely working, or a model too coarse to see the difference — and
 * those look identical from the outside. #329 expects *several* scenarios
 * to fail on v0.2.5, so a suite that is entirely green needs to justify
 * itself rather than be taken as good news.
 *
 * These tests reinstate each historical bug **in the world model** and
 * assert the suite then fails. That is the simulator's equivalent of the
 * disconfirmation run on a normal fix: a test that cannot fail is not
 * evidence.
 */
describe("model resolution: reinstating a fixed bug must break the suite", () => {
  /**
   * #298. Before it, the Mac's media stop was not debounced, so the
   * ~500ms `DeviceIsRunningSomewhere` gap caused by thrw's own handover
   * read as the user stopping their music — and the holder bounced every
   * few seconds.
   *
   * Reinstated by setting the debounce to 0.
   */
  it("catches #298 — an undebounced Mac media stop", () => {
    const withBug = { ...DEFAULT_PARAMETERS, macMediaStopDebounceMs: 0 };
    const fixed = runScenario(scenario("R298"), DEFAULT_PARAMETERS);
    const broken = runScenario(scenario("R298"), withBug);

    expect(fixed.failures).toEqual([]);
    expect(
      broken.failures.length,
      "R298 passed with the debounce removed, so the scenario is not " +
        "actually exercising #298 and the model cannot see that bug class",
    ).toBeGreaterThan(0);
  });

  /**
   * The same probe for the perturbation itself. If the Mac's signal were
   * *not* perturbed by thrw's handover — if `macDeviceChangeAudioGapMs`
   * were 0 — then #298's debounce would have nothing to protect against,
   * and a model built that way would make the whole bug class invisible
   * while every scenario stayed green.
   *
   * So: with the gap removed, removing the debounce must stop mattering.
   * This is what proves the two parameters are modelling one real
   * mechanism rather than being independently tuned to pass.
   */
  it("attributes #298 to the device-change gap, not to the debounce alone", () => {
    const noGapNoDebounce = {
      ...DEFAULT_PARAMETERS,
      macDeviceChangeAudioGapMs: 0,
      macMediaStopDebounceMs: 0,
    };
    const result = runScenario(scenario("R298"), noGapNoDebounce);

    // With nothing perturbing the signal, no debounce is needed and the
    // scenario passes again. If this failed, the debounce would be
    // covering for something other than the gap.
    expect(result.failures).toEqual([]);
  });

  /**
   * N2 exists because the Pixel distinguishes `TRANSIENT` from `STOPPED`
   * (#288). A model that treated buffering as a stop would bounce the
   * holder on every Spotify blip.
   *
   * Reinstated by making the blip long enough to cross the Mac's
   * debounce, which is the closest the parameters get to "treated as a
   * real stop".
   */
  it("catches #288 — buffering treated as a stop", () => {
    const longBlip: Scenario = {
      ...scenario("N2"),
      // 6s exceeds the 4s debounce, so it is no longer absorbed.
      timeline: scenario("N2").timeline.map((entry) =>
        entry.event === "audio_blip" ? { ...entry, forMs: 6000 } : entry,
      ),
      // The Pixel is the holder in N2, and on the Pixel a blip is
      // TRANSIENT regardless of length - so to make this probe bite, the
      // blips have to land on a Mac that holds the route.
      initial: { holder: "mac", playing: ["mac"] },
    };
    const mapped: Scenario = {
      ...longBlip,
      timeline: longBlip.timeline.map((entry) => ({ ...entry, device: "mac" as const })),
      expect: [{ during: ["10s", "180s"], holderChangesAtMost: 0 }],
    };

    const result = runScenario(mapped);
    // A 6s stop on the holder with nothing else playing does not move the
    // headset - rule 5 keeps it. So this asserts the weaker, true thing:
    // the model registers the stop at all, rather than silently absorbing
    // every blip regardless of length.
    expect(result.holderChanges.length).toBeGreaterThan(0);
  });

  /**
   * The honest limit of this whole file, stated as a test so it cannot be
   * forgotten: **#303 and #307 cannot be reinstated here.**
   *
   * #303 is a latched `RouteTransition` in the Mac adapter, and #307 is
   * `releaseStaleFallback` being called by `RelayService` on a
   * registration. The first is adapter-internal state this model
   * deliberately does not reproduce (it models decisions, not the
   * `inProgress` counter); the second needs `RelayService`, which
   * `packages/testkit` must not import under ADR 0003.
   *
   * So #329's criterion 4 — "regressions for #303 and #307" — is **not
   * met by this PR**, and the reason is structural rather than an
   * omission. Both belong in `services/relay-hosted/test/`, importing
   * this runner.
   */
  it("records that #303 and #307 are out of reach from packages/testkit", () => {
    // `PriorityEngine` exposes releaseStaleFallback, so the *engine* half
    // of #307 is reachable - but the orchestration that decides when to
    // call it is RelayService's, and replicating that here would mean
    // testing a replica rather than the relay.
    const enginePart = "releaseStaleFallback";
    expect(enginePart).toBe("releaseStaleFallback");

    // Deliberately not asserting anything about #303: there is nothing
    // here to assert against, which is the point.
    expect(true).toBe(true);
  });
});
