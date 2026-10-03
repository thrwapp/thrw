import { randomUUID } from "node:crypto";

import type { EventKind, NodeManifest } from "@thrw/protocol";
import { DeviceRegistry, PriorityEngine, type EventPayload } from "@thrw/relay-core";

import { InMemoryBus } from "../in-memory-bus.js";
import { VirtualClock } from "../virtual-clock.js";
import { ANDROID_CADENCE, MAC_CADENCE, mulberry32, sampleGapSeconds } from "../world/cadence.js";
import { NodeModel, type PhysicalSignal } from "../world/node-model.js";
import { DEFAULT_PARAMETERS, type WorldParameters } from "../world/parameters.js";
import { parseDuration, type DeviceId, type Scenario } from "./types.js";

const EVENT_END_KIND = "event_end";

/**
 * A holder change, in the scenario's own vocabulary.
 *
 * Device names rather than node ids: the ids are fresh UUIDs per run, so
 * exposing them made two runs of the same seed incomparable - which is
 * how the reproducibility assertion caught this.
 */
export interface HolderChange {
  readonly atMs: number;
  readonly from: DeviceId | null;
  readonly to: DeviceId | null;
}

export interface RunResult {
  readonly scenario: Scenario;
  readonly holderChanges: readonly HolderChange[];
  /** Holder at a given instant, by replaying `holderChanges`. */
  holderAt(ms: number): DeviceId | null;
  /** Which device physically held the route at that instant. */
  routeAt(ms: number): DeviceId | null;
  readonly failures: readonly string[];
}

interface RouteChange {
  readonly atMs: number;
  readonly device: DeviceId | null;
}

/**
 * Runs one scenario against the **real** relay decision components.
 *
 * ## What is and is not simulated
 *
 * `PriorityEngine` and `DeviceRegistry` are the shipping ones, driven
 * only through the transport callback — never by calling `recordEvent`
 * directly. The clock, the bus, and the two adapters are the
 * substitutions. `RelayService` is deliberately absent: ADR 0003
 * licenses `services/**` under the FSL and `packages/**` not, so
 * `packages/testkit` must not import it (#321 found this the hard way).
 *
 * The cost of that is real and worth stating: `CommandCoalescer`,
 * `reassertHolderClaim` and `releaseStaleFallback` all live in
 * `RelayService`, so scenarios here cannot exercise them. Anything
 * needing those belongs in `services/relay-hosted/test/`.
 *
 * ## The loop step 1 left open
 *
 * `handoff-scenario.test.ts` drives events in and asserts on the holder.
 * It has no notion of the route physically moving. This closes that
 * loop: a holder change dispatches a claim and a release, those take
 * measured time to settle, and when they do the node models are told —
 * which perturbs their own signals. That feedback path is where #295,
 * #298 and #303 all lived, and it cannot be reproduced without it.
 */
export function runScenario(
  scenario: Scenario,
  parameters: WorldParameters = DEFAULT_PARAMETERS,
  options: { readonly cleanTick?: boolean } = {},
): RunResult {
  const account = randomUUID();
  const clock = new VirtualClock();
  const bus = new InMemoryBus({ clock });
  const startMs = clock.now();

  const ids: Record<DeviceId, string> = { mac: randomUUID(), pixel: randomUUID() };
  const byId = new Map<string, DeviceId>([
    [ids.mac, "mac"],
    [ids.pixel, "pixel"],
  ]);

  const registry = new DeviceRegistry();
  for (const device of ["mac", "pixel"] as const) {
    registry.register(manifestFor(device, ids[device]));
  }

  const models: Record<DeviceId, NodeModel> = {
    mac: new NodeModel({ platform: "mac", parameters }),
    pixel: new NodeModel({ platform: "android", parameters }),
  };

  const engine = new PriorityEngine({ scheduler: clock });
  void bus.subscribeAllEvents(account, (payload, node) => {
    const end = payload as { kind?: unknown; type?: EventKind };
    if (end.kind === EVENT_END_KIND) engine.endEvent(node, end.type as EventKind);
    else engine.recordEvent(node, (payload as EventPayload).type);
  });

  const holderChanges: HolderChange[] = [];
  const routeChanges: RouteChange[] = [];
  let lastHolder: string | null = null;
  let route: DeviceId | null = null;

  const publish = (device: DeviceId, payload: unknown): void => {
    bus.nodePublishes(account, ids[device], "audio", payload);
    clock.advance(0);
  };

  const feed = (device: DeviceId, signal: PhysicalSignal): void => {
    for (const emission of models[device].apply(signal, clock.now())) {
      publish(
        device,
        emission.kind === "event"
          ? ({ type: emission.type, priority: 4 } satisfies EventPayload)
          : { kind: EVENT_END_KIND, type: emission.type },
      );
    }
  };

  /**
   * Reconciles the relay's holder with the physical route, which is what
   * `RelayService.syncHolder` does: RELEASE to the outgoing holder, then
   * CLAIM to the incoming one, sequential per ADR 0002.
   *
   * The settle times are the measured ones, so a claim lands ~3.3s after
   * the decision and a release ~0.34s after — and the node models are
   * told at *that* moment, not at the decision.
   */
  const reconcile = (): void => {
    const next = engine.currentHolder();
    if (next === lastHolder) return;
    const previous = lastHolder;
    lastHolder = next;
    holderChanges.push({
      atMs: clock.now() - startMs,
      from: previous === null ? null : (byId.get(previous) ?? null),
      to: next === null ? null : (byId.get(next) ?? null),
    });

    if (previous !== null) {
      const device = byId.get(previous);
      if (device) {
        clock.setTimeout(() => {
          route = null;
          routeChanges.push({ atMs: clock.now() - startMs, device: null });
          feed(device, { kind: "route_left" });
        }, parameters.releaseSettleMs);
      }
    }
    if (next !== null) {
      const device = byId.get(next);
      if (device) {
        // A claim to a node that already holds the route is the skip
        // path, which is ~26ms rather than ~3.3s (#310).
        const settleMs = route === device ? parameters.claimNoOpMs : parameters.claimSettleMs;
        clock.setTimeout(() => {
          route = device;
          routeChanges.push({ atMs: clock.now() - startMs, device });
          feed(device, { kind: "route_arrived" });
        }, settleMs);
      }
    }
  };

  // Registration cadence, sampled per platform unless the caller asked
  // for the clean-tick control (#329 criterion 3).
  const random = mulberry32(scenario.seed ?? 1);
  const scheduleRegistration = (device: DeviceId): void => {
    const profile = device === "mac" ? MAC_CADENCE : ANDROID_CADENCE;
    const gapSeconds = options.cleanTick
      ? profile.nominalSeconds
      : sampleGapSeconds(profile, random);
    clock.setTimeout(() => {
      // A registration restates this node's active triggers, which is
      // what lets the relay's view converge (#178).
      engine.reconcileSignals(ids[device], models[device].activeTriggers());
      reconcile();
      scheduleRegistration(device);
    }, gapSeconds * 1000);
  };

  // Initial state. Set directly, never fed through `apply`: `initial`
  // describes the world before the scenario, not a sequence of things
  // thrw just did. Feeding it as signals armed the holder's self-cooldown,
  // which then suppressed the scenario's own initial media start - caught
  // by R298 failing for the wrong reason.
  const playing = new Set(scenario.initial.playing ?? []);
  for (const device of ["mac", "pixel"] as const) {
    models[device].seedInitialState({
      holdsRoute: scenario.initial.holder === device,
      playing: playing.has(device),
    });
  }
  route = scenario.initial.holder ?? null;

  if (scenario.initial.holder) {
    // Seed the engine's rule-5 fallback the way a real prior session
    // would have: a media trigger that then ends, leaving this node as
    // last-claimed with nothing active.
    const device = scenario.initial.holder;
    publish(device, { type: "media", priority: 4 } satisfies EventPayload);
    publish(device, { kind: EVENT_END_KIND, type: "media" });
  }
  // Then the engine is told what is genuinely active now, in the order
  // the scenario listed it, so most-recently-started ties break the way
  // the file reads.
  for (const device of scenario.initial.playing ?? []) {
    publish(device, { type: "media", priority: 4 } satisfies EventPayload);
  }
  lastHolder = engine.currentHolder();
  if (lastHolder !== null) {
    const device = byId.get(lastHolder) ?? null;
    holderChanges.push({ atMs: 0, from: null, to: device });
    // The world starts *consistent*: whoever the engine computes as the
    // initial holder already has the route, rather than a claim being
    // dispatched for it. `initial` describes the state before the
    // scenario, so simulating a handover into it would make every
    // scenario begin with a transition it never asked for - and left the
    // route null forever when `initial` named no explicit holder.
    if (device !== null) {
      route = device;
      routeChanges.push({ atMs: 0, device });
      models[device].seedInitialState({
        holdsRoute: true,
        playing: playing.has(device),
      });
    }
  }

  scheduleRegistration("mac");
  scheduleRegistration("pixel");

  // Timeline.
  const entries = [...scenario.timeline].sort(
    (a, b) => parseDuration(a.at) - parseDuration(b.at),
  );
  let cursorMs = 0;
  const advanceTo = (targetMs: number): void => {
    // One second at a time so node timers (the Mac's stop debounce) and
    // route settles fall due in order, and `tick` is never skipped over.
    while (cursorMs < targetMs) {
      const step = Math.min(1000, targetMs - cursorMs);
      clock.advance(step);
      cursorMs += step;
      for (const device of ["mac", "pixel"] as const) {
        for (const emission of models[device].tick(clock.now())) {
          publish(
            device,
            emission.kind === "event"
              ? ({ type: emission.type, priority: 4 } satisfies EventPayload)
              : { kind: EVENT_END_KIND, type: emission.type },
          );
        }
      }
      reconcile();
    }
  };

  for (const entry of entries) {
    advanceTo(parseDuration(entry.at));
    feed(entry.device, { kind: entry.event, forMs: entry.forMs } as PhysicalSignal);
    reconcile();
  }
  advanceTo(cursorMs + parseDuration(scenario.runFor ?? "60s"));

  const holderAt = (ms: number): DeviceId | null => {
    let current: DeviceId | null = null;
    for (const change of holderChanges) {
      if (change.atMs > ms) break;
      current = change.to;
    }
    return current;
  };
  const routeAt = (ms: number): DeviceId | null => {
    let current: DeviceId | null = scenario.initial.holder ?? null;
    for (const change of routeChanges) {
      if (change.atMs > ms) break;
      current = change.device;
    }
    return current;
  };

  return {
    scenario,
    holderChanges,
    holderAt,
    routeAt,
    failures: checkExpectations(scenario, holderChanges, holderAt, routeAt),
  };
}

function checkExpectations(
  scenario: Scenario,
  holderChanges: readonly HolderChange[],
  holderAt: (ms: number) => DeviceId | null,
  routeAt: (ms: number) => DeviceId | null,
): string[] {
  const failures: string[] = [];
  for (const expectation of scenario.expect) {
    if (expectation.at !== undefined) {
      const atMs = parseDuration(expectation.at);
      if (expectation.holderIs !== undefined) {
        const actual = holderAt(atMs);
        if (actual !== expectation.holderIs) {
          failures.push(
            `at ${expectation.at}: holder is ${actual ?? "null"}, expected ${expectation.holderIs ?? "null"}`,
          );
        }
      }
      if (expectation.routeIs !== undefined) {
        const actual = routeAt(atMs);
        if (actual !== expectation.routeIs) {
          failures.push(
            `at ${expectation.at}: route is ${actual ?? "null"}, expected ${expectation.routeIs ?? "null"}`,
          );
        }
      }
    }
    if (expectation.during !== undefined) {
      const [fromMs, toMs] = expectation.during.map(parseDuration);
      const within = holderChanges.filter((c) => c.atMs >= fromMs && c.atMs <= toMs);
      if (
        expectation.holderChangesAtMost !== undefined &&
        within.length > expectation.holderChangesAtMost
      ) {
        failures.push(
          `during ${expectation.during.join("..")}: ${within.length} holder changes, expected at most ${expectation.holderChangesAtMost}`,
        );
      }
      if (
        expectation.holderChangesAtLeast !== undefined &&
        within.length < expectation.holderChangesAtLeast
      ) {
        failures.push(
          `during ${expectation.during.join("..")}: ${within.length} holder changes, expected at least ${expectation.holderChangesAtLeast}`,
        );
      }
    }
  }
  return failures;
}

function manifestFor(device: DeviceId, nodeId: string): NodeManifest {
  return {
    nodeId,
    platform: device === "mac" ? "mac" : "android",
    displayName: `simulated ${device}`,
    adapterVersion: "0.2.5",
    // The Mac genuinely cannot detect phone calls
    // (`architecture.md`, "Mac's trigger-detection gap"), and the
    // manifest is where that is declared.
    supportedEventKinds:
      device === "mac"
        ? ["media", "voip", "manual_claim"]
        : ["call", "media", "voip", "manual_claim"],
    supportedResourceTypes: ["audio"],
  };
}
