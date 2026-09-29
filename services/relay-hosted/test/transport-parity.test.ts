import { randomUUID } from "node:crypto";
import { commandsTopic, RESOURCE_AUDIO, type NodeManifest } from "@thrw/protocol";
import {
  defaultMqttBrokerUrl,
  RelayMqttClient,
  type SequencedCommandPayload,
} from "@thrw/relay-core";
import { InMemoryBus, VirtualClock } from "@thrw/testkit";
import mqtt, { type MqttClient } from "mqtt";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { RelayService } from "../src/relay-service";

/**
 * The transport seam, from both sides (#320).
 *
 * Two things are proved here, and this is the only place in the tree that
 * can prove either: it is the one package that may import **both**
 * `RelayMqttClient` and `@thrw/testkit`.
 *
 * 1. `RelayService` — the real one, unmodified — runs against a
 *    broker-less transport on a virtual clock. That is what
 *    `docs/spec/testing-framework.md` is built on, and it is worth an
 *    explicit test rather than being implied by the types compiling.
 * 2. The two transports stamp ADR 0018's epoch and sequence numbers
 *    **identically**, because they share one `CommandSequencer` rather
 *    than each implementing the scheme.
 *
 * ## Why it is here and not in `packages/testkit`
 *
 * ADR 0003 licenses `services/**` under the FSL and `packages/**` not, so
 * `packages/testkit` must not import `RelayService`. The dependency only
 * runs this way round: a service may use a package, never the reverse.
 * That is also why the virtual-clock port of the handoff scenario lives in
 * `packages/testkit` at the `PriorityEngine` level — the layer that is
 * actually available to it.
 */

const BROKER_URL = defaultMqttBrokerUrl();

function manifest(overrides: Partial<NodeManifest> = {}): NodeManifest {
  return {
    nodeId: randomUUID(),
    platform: "mac",
    displayName: "simulated node",
    adapterVersion: "0.2.5",
    supportedEventKinds: ["call", "media"],
    supportedResourceTypes: ["audio"],
    ...overrides,
  };
}

describe("RelayService on a broker-less transport", () => {
  const services: RelayService[] = [];

  afterEach(() => {
    for (const service of services) service.stop();
    services.length = 0;
  });

  /**
   * `now` comes from the same clock the scheduler does. Passing
   * `Date.now` here while the scheduler was virtual is the mistake this
   * makes hard to make: heartbeat staleness is computed from `now()` and
   * swept by a scheduled timer, so two different time sources would have
   * the sweep firing against timestamps that never age.
   */
  function start(accounts: string[], clock: VirtualClock, bus: InMemoryBus): Promise<void> {
    const service = new RelayService({
      client: bus,
      accounts,
      scheduler: clock,
      now: () => clock.now(),
    });
    services.push(service);
    return service.start();
  }

  it("registers a node and dispatches a claim, with no broker and no real time", async () => {
    const account = randomUUID();
    const node = manifest();
    const clock = new VirtualClock();
    const bus = new InMemoryBus({ clock });

    await start([account], clock, bus);

    bus.nodePublishes(account, node.nodeId, RESOURCE_AUDIO, {
      kind: "register",
      manifest: node,
      activeEvents: [],
      observedRoutes: {},
    });
    clock.advance(0);

    expect(services[0]?.registryFor(account)?.getById(node.nodeId)).toEqual(node);

    bus.nodePublishes(account, node.nodeId, RESOURCE_AUDIO, { type: "call", priority: 0 });
    clock.advance(0);

    // The coalescer may hold a first dispatch briefly; let whatever timer
    // it scheduled come due rather than hard-coding its window here.
    if (bus.commands.length === 0) clock.advanceToNextTimer();

    const claims = bus.commandsTo(account, node.nodeId, RESOURCE_AUDIO);
    expect(claims.map((c) => c.payload.type)).toContain("claim");
  });

  /**
   * The retained state topic (#229), which is how both adapters learn who
   * holds the headset — and the source of truth #308 is about.
   */
  it("publishes the holder on the retained state topic", async () => {
    const account = randomUUID();
    const node = manifest();
    const clock = new VirtualClock();
    const bus = new InMemoryBus({ clock });

    await start([account], clock, bus);

    bus.nodePublishes(account, node.nodeId, RESOURCE_AUDIO, {
      kind: "register",
      manifest: node,
      activeEvents: [],
      observedRoutes: {},
    });
    clock.advance(0);
    bus.nodePublishes(account, node.nodeId, RESOURCE_AUDIO, { type: "media", priority: 3 });
    clock.advance(0);
    if (bus.states.length === 0) clock.advanceToNextTimer();

    expect(bus.latestState(account, RESOURCE_AUDIO)).toEqual({ holder: node.nodeId });
  });

  /**
   * A 14-day soak is one of v1's exit criteria, and it is only reachable
   * because virtual time costs nothing. This is the cheap proof that
   * advancing far does not wedge or explode the service — the heartbeat
   * sweep alone fires ~80,000 times here.
   */
  it("survives two weeks of virtual time in milliseconds", async () => {
    const account = randomUUID();
    const clock = new VirtualClock();
    const bus = new InMemoryBus({ clock });

    await start([account], clock, bus);

    const fourteenDays = 14 * 24 * 60 * 60 * 1000;
    const startedAt = Date.now();
    clock.advance(fourteenDays);

    expect(clock.now()).toBeGreaterThanOrEqual(fourteenDays);
    // Real elapsed time, not virtual - the whole point of the exercise.
    expect(Date.now() - startedAt).toBeLessThan(5000);
  });
});

describe("both transports stamp ADR 0018 identically", () => {
  let rawClient: MqttClient;
  const clients: RelayMqttClient[] = [];

  beforeAll(async () => {
    rawClient = await new Promise<MqttClient>((resolve, reject) => {
      const client = mqtt.connect(BROKER_URL);
      client.once("connect", () => resolve(client));
      client.once("error", reject);
    });
  });

  afterAll(async () => {
    for (const client of clients) await client.end();
    await new Promise<void>((resolve) => rawClient.end(false, {}, () => resolve()));
  });

  /**
   * Criterion 3, demonstrated rather than asserted in a comment: the same
   * call sequence through each transport produces the same sequence
   * numbers, one stable epoch each, and the same payload shape.
   *
   * Epochs differ between the two **by design** — they identify a relay
   * process, and these are two. So the assertion is on their *behaviour*
   * (present, non-empty, constant within a transport), not their equality.
   */
  it("produces the same sequence progression and payload shape", async () => {
    const account = randomUUID();
    const node = randomUUID();
    const topic = commandsTopic(account, node, RESOURCE_AUDIO);

    const overTheWire: SequencedCommandPayload[] = [];
    await new Promise<void>((resolve, reject) => {
      rawClient.subscribe(topic, { qos: 1 }, (err) => (err ? reject(err) : resolve()));
    });
    rawClient.on("message", (messageTopic, message) => {
      if (messageTopic === topic) {
        overTheWire.push(JSON.parse(message.toString()) as SequencedCommandPayload);
      }
    });

    const real = await RelayMqttClient.connect(BROKER_URL);
    clients.push(real);

    const clock = new VirtualClock();
    const bus = new InMemoryBus({ clock });

    // The same three calls, in the same order, through each transport.
    const calls = [{ type: "claim" }, { type: "release" }, { type: "claim" }] as const;
    for (const payload of calls) {
      await real.publishCommand(account, node, RESOURCE_AUDIO, payload);
      await bus.publishCommand(account, node, RESOURCE_AUDIO, payload);
    }
    clock.advance(0);

    await expect.poll(() => overTheWire.length, { timeout: 2000 }).toBe(calls.length);

    const fromBus = bus.commandsTo(account, node, RESOURCE_AUDIO).map((c) => c.payload);

    expect(fromBus.map((p) => p.seq)).toEqual([1, 2, 3]);
    expect(overTheWire.map((p) => p.seq)).toEqual(fromBus.map((p) => p.seq));
    expect(overTheWire.map((p) => p.type)).toEqual(fromBus.map((p) => p.type));

    // One stable, non-empty epoch per transport.
    for (const set of [overTheWire, fromBus]) {
      const epochs = new Set(set.map((p) => p.epoch));
      expect(epochs.size).toBe(1);
      expect([...epochs][0]).toBeTruthy();
    }

    // Same keys on the wire from both, so neither adds nor drops a field.
    expect(Object.keys(fromBus[0] ?? {}).sort()).toEqual(
      Object.keys(overTheWire[0] ?? {}).sort(),
    );
  });

  /**
   * Sequence numbers are per `(account, node, resource)`, and the bus must
   * partition them the same way — a shared counter would make the number
   * useless as evidence of ordering for any one node.
   */
  it("sequences each node independently in the broker-less transport", async () => {
    const account = randomUUID();
    const nodeA = randomUUID();
    const nodeB = randomUUID();
    const clock = new VirtualClock();
    const bus = new InMemoryBus({ clock });

    await bus.publishCommand(account, nodeA, RESOURCE_AUDIO, { type: "claim" });
    await bus.publishCommand(account, nodeB, RESOURCE_AUDIO, { type: "claim" });
    await bus.publishCommand(account, nodeA, RESOURCE_AUDIO, { type: "release" });

    expect(bus.commandsTo(account, nodeA, RESOURCE_AUDIO).map((c) => c.payload.seq)).toEqual([1, 2]);
    expect(bus.commandsTo(account, nodeB, RESOURCE_AUDIO).map((c) => c.payload.seq)).toEqual([1]);
  });
});
