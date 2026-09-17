import { randomUUID } from "node:crypto";
import { eventsTopic, type EventKind, type NodeManifest } from "@thrw/protocol";
import mqtt, { type MqttClient } from "mqtt";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  defaultMqttBrokerUrl,
  DeviceRegistry,
  PriorityEngine,
  RelayMqttClient,
  type EventPayload,
  type Scheduler,
} from "../src/index";

// docs/roadmap.md's M3.3: "simulated call-start on the Android side
// correctly drives a claim/release cycle observed by the Mac side through
// relay-core." A real cross-language test isn't achievable in one CI job
// (see issue #113's description), and packages/adapter-mac has no
// MQTT/node-interface wiring yet regardless. This validates the same
// claim/release cycle at the layer that's actually testable today: two
// independent simulated nodes, each driving relay-core's own real
// components (RelayMqttClient, DeviceRegistry, PriorityEngine) over the
// real local Mosquitto broker this package's other tests already use.
const BROKER_URL = defaultMqttBrokerUrl();

// The wire shape the Android adapter already publishes for "the trigger I
// reported earlier stopped" (packages/adapter-android/.../protocol/Payloads.kt's
// EventEndPayload, see docs/handoffs/68.md) - a `kind: "event_end"`
// discriminator riding the same (frozen, per ADR 0001) events topic as a
// normal EventPayload, since PriorityEngine.endEvent needs a wire signal but
// the topic set has no topic of its own to spare for it. Per that handoff,
// "the relay does not consume this yet" - nothing in relay-core parses this
// discriminator. That consumer is exactly what this test's wiring exercises,
// kept local to the test rather than added to RelayMqttClient/PriorityIngine,
// since this issue adds a test, not a feature (acceptance criterion 4).
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

// Deterministic, fully controllable stand-in for the injectable time source,
// same shape as index.test.ts's own (duplicated rather than shared - this
// package's existing test files don't share helpers across each other).
class FakeScheduler implements Scheduler {
  private nextId = 1;
  private readonly timers = new Map<number, { callback: () => void; ms: number }>();

  setTimeout(callback: () => void, ms: number): unknown {
    const id = this.nextId++;
    this.timers.set(id, { callback, ms });
    return id;
  }

  clearTimeout(handle: unknown): void {
    this.timers.delete(handle as number);
  }

  pendingCount(): number {
    return this.timers.size;
  }

  fire(ms: number): void {
    for (const [id, timer] of this.timers) {
      if (timer.ms <= ms) {
        this.timers.delete(id);
        timer.callback();
      }
    }
  }
}

function manifest(overrides: Partial<NodeManifest>): NodeManifest {
  return {
    nodeId: randomUUID(),
    platform: "android",
    displayName: "simulated node",
    adapterVersion: "1.0.0",
    supportedEventKinds: ["call", "media"],
    ...overrides,
  };
}

function connectRawClient(): Promise<MqttClient> {
  return new Promise((resolve, reject) => {
    const client = mqtt.connect(BROKER_URL);
    client.once("connect", () => resolve(client));
    client.once("error", reject);
  });
}

// The event_end wire message has no RelayMqttClient method to publish it
// (see comment above) - a raw client publishing directly to
// @thrw/protocol's own eventsTopic builder is this test's stand-in for
// "the node's own connection", the same way mqtt-client.test.ts's
// `verifier` publishes on behalf of arbitrary node ids.
function publishEventEnd(
  client: MqttClient,
  account: string,
  node: string,
  type: EventKind,
): Promise<void> {
  const payload: EventEndPayload = { kind: EVENT_END_KIND, type };
  return new Promise((resolve, reject) => {
    client.publish(eventsTopic(account, node), JSON.stringify(payload), { qos: 1 }, (err) =>
      err ? reject(err) : resolve(),
    );
  });
}

describe("handoff integration: two simulated nodes driving PriorityEngine over the real broker", () => {
  let nodeAClient: RelayMqttClient;
  let nodeBClient: RelayMqttClient;
  let relayListener: RelayMqttClient;
  let rawClient: MqttClient;

  beforeAll(async () => {
    nodeAClient = await RelayMqttClient.connect(BROKER_URL);
    nodeBClient = await RelayMqttClient.connect(BROKER_URL);
    relayListener = await RelayMqttClient.connect(BROKER_URL);
    rawClient = await connectRawClient();
  });

  afterAll(async () => {
    await nodeAClient.end();
    await nodeBClient.end();
    await relayListener.end();
    await new Promise<void>((resolve) => rawClient.end(false, {}, () => resolve()));
  });

  it("registers both nodes, then drives claim/release through call > media priority and auto-return via real MQTT events", async () => {
    const account = randomUUID();
    const nodeA = manifest({ platform: "android", supportedEventKinds: ["call"] });
    const nodeB = manifest({ platform: "mac", supportedEventKinds: ["media"] });

    // Acceptance criterion 3: both nodes registered and retrievable, with
    // nothing in this test branching on `platform` - the registry's own
    // design never does, and neither does this test's assertions or event
    // flow below (both nodes are driven through the exact same
    // RelayMqttClient/PriorityEngine calls regardless of which platform
    // their manifest names).
    const registry = new DeviceRegistry();
    registry.register(nodeA);
    registry.register(nodeB);

    expect(registry.getById(nodeA.nodeId)).toEqual(nodeA);
    expect(registry.getById(nodeB.nodeId)).toEqual(nodeB);
    expect(registry.listAll()).toEqual(expect.arrayContaining([nodeA, nodeB]));
    expect(registry.listAll()).toHaveLength(2);

    const scheduler = new FakeScheduler();
    const engine = new PriorityEngine({ scheduler });

    // The real wire path (acceptance criterion 1): subscribeAllEvents,
    // not PriorityEngine.recordEvent/endEvent called directly from the
    // test. This callback is the only place those methods are invoked.
    await relayListener.subscribeAllEvents(account, (payload, node) => {
      if (isEventEndPayload(payload)) {
        engine.endEvent(node, payload.type);
      } else {
        engine.recordEvent(node, (payload as EventPayload).type);
      }
    });

    // Set up a pre-call holder: node B starts, then ends, a media signal.
    // No active signal remains, but B is now the last-claimed node
    // (PriorityEngine rule 5) - this is the holder A's later call should
    // return to.
    await nodeBClient.publishEvent(account, nodeB.nodeId, { type: "media", priority: 4 });
    await expect.poll(() => engine.currentHolder(), { timeout: 2000 }).toBe(nodeB.nodeId);

    await publishEventEnd(rawClient, account, nodeB.nodeId, "media");
    await expect.poll(() => engine.currentHolder(), { timeout: 2000 }).toBe(nodeB.nodeId);

    // (a) node A emits a call event -> A becomes holder.
    await nodeAClient.publishEvent(account, nodeA.nodeId, { type: "call", priority: 1 });
    await expect.poll(() => engine.currentHolder(), { timeout: 2000 }).toBe(nodeA.nodeId);

    // (b) node B then emits media while A's call is still active -> holder
    // stays A (call outranks media, per PRIORITY_ORDER).
    await nodeBClient.publishEvent(account, nodeB.nodeId, { type: "media", priority: 4 });
    await new Promise((resolve) => setTimeout(resolve, 300));
    expect(engine.currentHolder()).toBe(nodeA.nodeId);

    // End B's media before A's call ends, so nothing else is active by the
    // time A's call ends - otherwise B's still-active media would already
    // make it the computed holder regardless of the auto-return timer,
    // which would defeat testing the timer's effect below.
    await publishEventEnd(rawClient, account, nodeB.nodeId, "media");
    await new Promise((resolve) => setTimeout(resolve, 300));
    expect(engine.currentHolder()).toBe(nodeA.nodeId);

    // (c) A ends the call -> an auto-return timer is scheduled back to
    // whichever node held the claim before A's call started (node B).
    // Immediately after, A (the last-claimed node) still holds the grace
    // period, per PriorityEngine's own documented behaviour.
    await publishEventEnd(rawClient, account, nodeA.nodeId, "call");
    await expect
      .poll(() => scheduler.pendingCount(), { timeout: 2000 })
      .toBe(1);
    expect(engine.currentHolder()).toBe(nodeA.nodeId);

    // (d) firing the injected scheduler's timer (no real 90s wait) returns
    // the pre-call holder, node B.
    scheduler.fire(90_000);
    expect(engine.currentHolder()).toBe(nodeB.nodeId);
  });
});
