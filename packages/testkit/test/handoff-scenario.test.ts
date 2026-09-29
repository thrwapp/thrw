import { randomUUID } from "node:crypto";
import type { EventKind, NodeManifest } from "@thrw/protocol";
import { DeviceRegistry, PriorityEngine, type EventPayload } from "@thrw/relay-core";
import { describe, expect, it } from "vitest";
import { InMemoryBus } from "../src/in-memory-bus.js";
import { VirtualClock } from "../src/virtual-clock.js";

/**
 * `relay-core`'s `handoff-integration.test.ts` scenario, on a virtual
 * clock with no broker (#320).
 *
 * That test stays where it is and keeps running against real Mosquitto —
 * it is the one that proves the MQTT wiring itself works, which this
 * cannot. What this adds is the same *decision* scenario made
 * deterministic and instant: the original spends ~650ms on real broker
 * round-trips, three `expect.poll`s and two hard-coded 300ms sleeps, none
 * of which is about the behaviour under test.
 *
 * The distinction matters for what comes next. A scenario suite
 * (`docs/spec/testing-framework.md`) needs hundreds of these, including
 * 14-day soaks — impossible at 650ms and a real broker each, routine at
 * this speed.
 *
 * Note what is *not* faked: `PriorityEngine` and `DeviceRegistry` are the
 * real ones, and events reach the engine only through the transport's
 * `subscribeAllEvents` callback, exactly as in the original. The clock and
 * the bus are the only substitutions.
 */

const EVENT_END_KIND = "event_end";

interface EventEndPayload {
  kind: typeof EVENT_END_KIND;
  type: EventKind;
}

function isEventEndPayload(payload: unknown): payload is EventEndPayload {
  return (
    typeof payload === "object" &&
    payload !== null &&
    (payload as { kind?: unknown }).kind === EVENT_END_KIND
  );
}

function manifest(overrides: Partial<NodeManifest>): NodeManifest {
  return {
    nodeId: randomUUID(),
    platform: "android",
    displayName: "simulated node",
    adapterVersion: "1.0.0",
    supportedEventKinds: ["call", "media"],
    supportedResourceTypes: ["audio"],
    ...overrides,
  };
}

describe("handoff scenario on a virtual clock, with no broker", () => {
  it("drives claim/release through call > media priority and auto-return", () => {
    const account = randomUUID();
    const nodeA = manifest({ platform: "android", supportedEventKinds: ["call"] });
    const nodeB = manifest({ platform: "mac", supportedEventKinds: ["media"] });

    const clock = new VirtualClock();
    const bus = new InMemoryBus({ clock });

    const registry = new DeviceRegistry();
    registry.register(nodeA);
    registry.register(nodeB);
    expect(registry.listAll()).toHaveLength(2);

    const engine = new PriorityEngine({ scheduler: clock });

    // The real wire path: the engine is driven only from this callback,
    // never by the test calling recordEvent/endEvent directly.
    void bus.subscribeAllEvents(account, (payload, node) => {
      if (isEventEndPayload(payload)) engine.endEvent(node, payload.type);
      else engine.recordEvent(node, (payload as EventPayload).type);
    });

    /** Publishes, then lets the bus deliver. No polling: delivery is a clock tick. */
    const publish = (node: string, payload: unknown): void => {
      bus.nodePublishes(account, node, "audio", payload);
      clock.advance(0);
    };

    // A pre-call holder: B starts then ends media, so no signal is active
    // but B is the last-claimed node (rule 5). This is who A's call should
    // return to.
    publish(nodeB.nodeId, { type: "media", priority: 4 } satisfies EventPayload);
    expect(engine.currentHolder()).toBe(nodeB.nodeId);

    publish(nodeB.nodeId, { kind: EVENT_END_KIND, type: "media" });
    expect(engine.currentHolder()).toBe(nodeB.nodeId);

    // (a) A's call takes the headset.
    publish(nodeA.nodeId, { type: "call", priority: 1 } satisfies EventPayload);
    expect(engine.currentHolder()).toBe(nodeA.nodeId);

    // (b) B's media while A's call is live changes nothing - call outranks
    // media. The original needed a 300ms real sleep to show "nothing
    // happened"; here the queue is provably drained instead, which is a
    // stronger statement than waiting and looking again.
    publish(nodeB.nodeId, { type: "media", priority: 4 } satisfies EventPayload);
    expect(engine.currentHolder()).toBe(nodeA.nodeId);

    // End B's media before A's call ends, so nothing else is active when
    // it does - otherwise B's live media would be the computed holder
    // regardless of the auto-return timer, defeating the point of (d).
    publish(nodeB.nodeId, { kind: EVENT_END_KIND, type: "media" });
    expect(engine.currentHolder()).toBe(nodeA.nodeId);

    // (c) A's call ends: an auto-return timer is scheduled, and A keeps
    // the claim through the grace period.
    publish(nodeA.nodeId, { kind: EVENT_END_KIND, type: "call" });
    expect(clock.pendingCount()).toBe(1);
    expect(engine.currentHolder()).toBe(nodeA.nodeId);

    // (d) The timer fires on its own deadline - named nowhere in this
    // test, so it cannot drift from the engine's default.
    clock.advanceToNextTimer();
    expect(engine.currentHolder()).toBe(nodeB.nodeId);
  });

  /**
   * The same scenario's shape, asserted on *timing* rather than only on
   * outcome — which the broker version cannot do, because real transit
   * jitter swamps the numbers it would be asserting.
   */
  it("returns the headset exactly at the auto-return deadline, not before", () => {
    const account = randomUUID();
    const holder = randomUUID();
    const previous = randomUUID();

    const clock = new VirtualClock(0);
    const bus = new InMemoryBus({ clock });
    const engine = new PriorityEngine({ scheduler: clock, autoReturnMs: 90_000 });

    void bus.subscribeAllEvents(account, (payload, node) => {
      if (isEventEndPayload(payload)) engine.endEvent(node, payload.type);
      else engine.recordEvent(node, (payload as EventPayload).type);
    });

    bus.nodePublishes(account, previous, "audio", { type: "media", priority: 4 });
    clock.advance(0);
    bus.nodePublishes(account, previous, "audio", { kind: EVENT_END_KIND, type: "media" });
    clock.advance(0);
    bus.nodePublishes(account, holder, "audio", { type: "call", priority: 1 });
    clock.advance(0);
    bus.nodePublishes(account, holder, "audio", { kind: EVENT_END_KIND, type: "call" });
    clock.advance(0);

    clock.advance(89_999);
    expect(engine.currentHolder()).toBe(holder);

    clock.advance(1);
    expect(engine.currentHolder()).toBe(previous);
  });

  /**
   * Delivery latency is a parameter, so a scenario can reproduce the
   * window where the relay and a node legitimately disagree because a
   * message is still in flight — the shape behind #307 and #308.
   */
  it("holds a message in flight for the configured delivery delay", () => {
    const account = randomUUID();
    const node = randomUUID();

    const clock = new VirtualClock(0);
    const bus = new InMemoryBus({ clock, deliveryDelayMs: 250 });
    const engine = new PriorityEngine({ scheduler: clock });

    void bus.subscribeAllEvents(account, (payload, from) => {
      engine.recordEvent(from, (payload as EventPayload).type);
    });

    bus.nodePublishes(account, node, "audio", { type: "media", priority: 4 });

    clock.advance(249);
    expect(engine.currentHolder()).toBeNull();

    clock.advance(1);
    expect(engine.currentHolder()).toBe(node);
  });
});
