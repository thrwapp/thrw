import { randomUUID } from "node:crypto";
import { commandsTopic, eventsTopic, heartbeatTopic, type EventKind, type NodeManifest } from "@thrw/protocol";
import {
  defaultMqttBrokerUrl,
  RelayMqttClient,
  type CommandPayload,
  type Scheduler,
} from "@thrw/relay-core";
import mqtt, { type MqttClient } from "mqtt";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { RelayService, type RouteDrift } from "../src/relay-service";

// Integration tests against a real MQTT broker, same pattern
// packages/relay-core's own tests use (acceptance criterion 4) - CI
// starts Mosquitto and sets MQTT_BROKER_URL; defaultMqttBrokerUrl() falls
// back to the same address for local dev.
const BROKER_URL = defaultMqttBrokerUrl();

const REGISTRATION_KIND = "register";
const EVENT_END_KIND = "event_end";

// Deterministic, fully controllable stand-in for the injectable time
// source - same shape as packages/relay-core/test/handoff-integration.test.ts's
// own FakeScheduler (duplicated rather than shared - this repo's existing
// test files don't share helpers across packages/services either).
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

  /**
   * Fires every timer pending *at the moment this is called* whose delay
   * is `<= ms` - snapshotting the due set first, rather than
   * handoff-integration.test.ts's simpler live-iteration version, matters
   * here specifically: `RelayService`'s heartbeat sweep reschedules
   * itself (`scheduler.setTimeout(...)` again) from inside its own fired
   * callback, and iterating the same `Map` live while a callback inserts
   * into it is exactly the recipe for an infinite loop (confirmed the
   * hard way - a live-iteration version of this spun at 100% CPU with no
   * output). PriorityEngine's own one-shot auto-return timer never
   * reschedules itself, so this distinction never mattered for that
   * existing test.
   */
  fire(ms: number): void {
    const due = [...this.timers.entries()].filter(([, timer]) => timer.ms <= ms);
    for (const [id, timer] of due) {
      this.timers.delete(id);
      timer.callback();
    }
  }
}

function manifest(overrides: Partial<NodeManifest> = {}): NodeManifest {
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

function publishJson(client: MqttClient, topic: string, payload: unknown, qos: 0 | 1 | 2 = 1): Promise<void> {
  return new Promise((resolve, reject) => {
    client.publish(topic, JSON.stringify(payload), { qos }, (err) => (err ? reject(err) : resolve()));
  });
}

function publishRegistration(
  client: MqttClient,
  account: string,
  nodeManifest: NodeManifest,
  activeEvents?: EventKind[],
  observedRoutes?: Record<string, boolean>,
): Promise<void> {
  return publishJson(client, eventsTopic(account, nodeManifest.nodeId), {
    kind: REGISTRATION_KIND,
    manifest: nodeManifest,
    ...(activeEvents ? { activeEvents } : {}),
    ...(observedRoutes ? { observedRoutes } : {}),
  });
}

function publishEventEnd(client: MqttClient, account: string, node: string, type: EventKind): Promise<void> {
  return publishJson(client, eventsTopic(account, node), { kind: EVENT_END_KIND, type });
}

function publishEvent(client: MqttClient, account: string, node: string, type: EventKind): Promise<void> {
  return publishJson(client, eventsTopic(account, node), { type, priority: 1 });
}

/**
 * Lets the real broker deliver in-flight messages and the service process
 * them. Used where there's no observable state change to poll on - a
 * heartbeat arriving updates only private bookkeeping (#142).
 */
function settle(ms = 300): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function collectCommands(client: MqttClient, account: string, node: string): CommandPayload[] {
  const received: CommandPayload[] = [];
  const topic = commandsTopic(account, node);
  client.subscribe(topic, { qos: 1 });
  client.on("message", (messageTopic, message) => {
    if (messageTopic !== topic) return;
    received.push(JSON.parse(message.toString()) as CommandPayload);
  });
  return received;
}

describe("RelayService (real broker)", () => {
  let rawClient: MqttClient;

  beforeAll(async () => {
    rawClient = await connectRawClient();
  });

  afterAll(async () => {
    await new Promise<void>((resolve) => rawClient.end(false, {}, () => resolve()));
  });

  const services: RelayService[] = [];
  const clients: RelayMqttClient[] = [];

  afterEach(async () => {
    for (const service of services) service.stop();
    services.length = 0;
    for (const client of clients) await client.end();
    clients.length = 0;
    rawClient.removeAllListeners("message");
  });

  async function startService(
    accounts: string[],
    scheduler?: Scheduler,
    now?: () => number,
    onRouteDrift?: (drift: RouteDrift) => void,
  ): Promise<RelayService> {
    const client = await RelayMqttClient.connect(BROKER_URL);
    clients.push(client);
    const service = new RelayService({
      client,
      accounts,
      scheduler,
      now,
      onRouteDrift,
      heartbeatSweepIntervalMs: 5_000,
    });
    await service.start();
    services.push(service);
    return service;
  }

  it("registers a node from its RegistrationPayload", async () => {
    const account = randomUUID();
    const nodeA = manifest();
    const service = await startService([account]);

    await publishRegistration(rawClient, account, nodeA);

    await expect
      .poll(() => service.registryFor(account)?.getById(nodeA.nodeId), { timeout: 2000 })
      .toEqual(nodeA);
  });

  it("publishes CLAIM to the first holder, then RELEASE+CLAIM on a real handoff, over the real broker", async () => {
    const account = randomUUID();
    const nodeA = manifest({ supportedEventKinds: ["call"] });
    const nodeB = manifest({ supportedEventKinds: ["call"] });
    await startService([account]);

    const commandsA = collectCommands(rawClient, account, nodeA.nodeId);
    const commandsB = collectCommands(rawClient, account, nodeB.nodeId);

    // A's call starts first -> A becomes holder. No prior holder, so only
    // a CLAIM is published (nothing to RELEASE yet).
    await publishEvent(rawClient, account, nodeA.nodeId, "call");
    await expect.poll(() => commandsA, { timeout: 2000 }).toEqual([{ type: "claim" }]);
    expect(commandsB).toEqual([]);

    // B's call starts while A's is still active -> tie-break picks the
    // more recently started signal (PriorityEngine's own documented
    // behaviour), so B becomes the new holder. Sequential handoff means
    // both commands go out: RELEASE to the loser, CLAIM to the winner.
    await publishEvent(rawClient, account, nodeB.nodeId, "call");
    await expect.poll(() => commandsA, { timeout: 2000 }).toEqual([{ type: "claim" }, { type: "release" }]);
    await expect.poll(() => commandsB, { timeout: 2000 }).toEqual([{ type: "claim" }]);

    // B's call ends, but A's call is *still* active underneath (never
    // ended) - the holder reverts to A immediately, another real
    // RELEASE(B)+CLAIM(A) pair.
    await publishEventEnd(rawClient, account, nodeB.nodeId, "call");
    await expect
      .poll(() => commandsA, { timeout: 2000 })
      .toEqual([{ type: "claim" }, { type: "release" }, { type: "claim" }]);
    await expect.poll(() => commandsB, { timeout: 2000 }).toEqual([{ type: "claim" }, { type: "release" }]);

    // A's call ends too - nothing else is active, and A was already the
    // holder (rule 5, last-claimed keeps it) - no new command.
    await publishEventEnd(rawClient, account, nodeA.nodeId, "call");
    await new Promise((resolve) => setTimeout(resolve, 300));
    expect(commandsA).toEqual([{ type: "claim" }, { type: "release" }, { type: "claim" }]);
  });

  it("keeps each account's registry and holder fully independent", async () => {
    const accountX = randomUUID();
    const accountY = randomUUID();
    const nodeX = manifest();
    const nodeY = manifest();
    const service = await startService([accountX, accountY]);

    await publishRegistration(rawClient, accountX, nodeX);
    await publishEvent(rawClient, accountX, nodeX.nodeId, "call");
    await expect.poll(() => service.engineFor(accountX)?.currentHolder(), { timeout: 2000 }).toBe(nodeX.nodeId);

    // accountY never sees any of accountX's traffic - registry stays
    // empty and its engine reports no holder.
    await new Promise((resolve) => setTimeout(resolve, 300));
    expect(service.registryFor(accountY)?.listAll()).toEqual([]);
    expect(service.engineFor(accountY)?.currentHolder()).toBeNull();
    expect(service.registryFor(accountX)?.getById(nodeY.nodeId)).toBeUndefined();
  });

  it("unregisters a node once its heartbeat has been missed for the configured timeout", async () => {
    const account = randomUUID();
    const nodeA = manifest();
    const scheduler = new FakeScheduler();
    let now = 0;
    const service = await startService([account], scheduler, () => now);
    // Constructor default heartbeatTimeoutMs applies (90s) - only the
    // sweep interval was overridden by startService for faster test
    // iteration; advancing past 90s below still exercises the real
    // default rather than a shortened one.

    await publishRegistration(rawClient, account, nodeA);
    await expect
      .poll(() => service.registryFor(account)?.getById(nodeA.nodeId), { timeout: 2000 })
      .toEqual(nodeA);

    now += 90_001;
    scheduler.fire(5_000);

    expect(service.registryFor(account)?.getById(nodeA.nodeId)).toBeUndefined();
  });

  // #142: the other half of the sweep's contract. Everything above proves
  // a node that goes *silent* is reaped; this proves a node that keeps
  // beating is not. Until #142 no adapter published a heartbeat at all,
  // so in practice every real node hit the reap path ~90s after
  // registering - and, once #130 wired forgetNode into that same sweep,
  // got a RELEASE published to it, dropping the headset mid-call.
  it("keeps a node that is still heartbeating, even well past the timeout (#142)", async () => {
    const account = randomUUID();
    const nodeA = manifest({ supportedEventKinds: ["call"] });
    const scheduler = new FakeScheduler();
    let now = 0;
    const service = await startService([account], scheduler, () => now);

    const commandsA = collectCommands(rawClient, account, nodeA.nodeId);

    await publishRegistration(rawClient, account, nodeA);
    await publishEvent(rawClient, account, nodeA.nodeId, "call");
    await expect.poll(() => commandsA, { timeout: 2000 }).toEqual([{ type: "claim" }]);

    // `trackHeartbeat` subscribes to this node's heartbeat topic
    // fire-and-forget when it sees the registration, so a beat published
    // before that SUBSCRIBE round-trip lands is simply dropped (QoS 0,
    // no retry). Settle first, or the first beats go nowhere.
    await settle();

    // Well past the 90s timeout - five 30s intervals, so `now` reaches
    // 150_000 and the sweep's cutoff (now - 90_000) climbs to 60_000,
    // comfortably past the registration stamp at 0. Without the beats
    // below this node is reaped; the loop count matters, and three
    // intervals is *not* enough (now would land on exactly 90_000, and
    // the sweep's `lastSeenAt < cutoff` is strict, so 0 < 0 is false and
    // nothing is reaped - a version of this test with three iterations
    // passed even with the heartbeat removed, i.e. proved nothing).
    for (let elapsed = 0; elapsed < 5; elapsed++) {
      now += 30_000;
      await publishJson(rawClient, heartbeatTopic(account, nodeA.nodeId), {}, 0);
      // The beat has to be *delivered and processed* before the sweep
      // runs, and nothing public on RelayService changes when one
      // arrives - so there's no poll predicate to wait on, only a
      // settle. Same approach the "unrecognized payload" test above uses.
      await settle();
      scheduler.fire(5_000);
    }

    // Still registered, still the holder, and never told to release.
    expect(service.registryFor(account)?.getById(nodeA.nodeId)).toEqual(nodeA);
    expect(service.engineFor(account)?.currentHolder()).toBe(nodeA.nodeId);
    expect(commandsA).toEqual([{ type: "claim" }]);
  });

  it("forgets a silent node's PriorityEngine signals too (#130), publishing a real RELEASE when it was mid-call", async () => {
    const account = randomUUID();
    const nodeA = manifest({ supportedEventKinds: ["call"] });
    const scheduler = new FakeScheduler();
    let now = 0;
    const service = await startService([account], scheduler, () => now);

    const commandsA = collectCommands(rawClient, account, nodeA.nodeId);

    // A holds the claim via an ordinary call, then goes silent mid-call -
    // never sends event_end. Before #130, PriorityEngine kept reporting A
    // as the winner forever (docs/handoffs/118.md's "Known gaps").
    await publishRegistration(rawClient, account, nodeA);
    await publishEvent(rawClient, account, nodeA.nodeId, "call");
    await expect.poll(() => commandsA, { timeout: 2000 }).toEqual([{ type: "claim" }]);
    expect(service.engineFor(account)?.currentHolder()).toBe(nodeA.nodeId);

    now += 90_001;
    scheduler.fire(5_000);

    // forgetNode's own "no auto-return grace period for a silently-gone
    // node" judgment call means this is immediate - no second sweep or
    // timer fire needed.
    expect(service.engineFor(account)?.currentHolder()).toBeNull();
    await expect.poll(() => commandsA, { timeout: 2000 }).toEqual([{ type: "claim" }, { type: "release" }]);
  });

  it("drops an unrecognized payload shape instead of throwing or registering anything", async () => {
    const account = randomUUID();
    const node = randomUUID();
    const service = await startService([account]);

    await publishJson(rawClient, eventsTopic(account, node), { unrelated: "shape" });
    await new Promise((resolve) => setTimeout(resolve, 300));

    expect(service.registryFor(account)?.listAll()).toEqual([]);
    expect(service.engineFor(account)?.currentHolder()).toBeNull();
  });
  // #173. Both of these reproduce what a Pixel and a Mac actually did
  // against the deployed relay on 2026-09-19: the phone emitted a real
  // media event and the relay published nothing at all, because it still
  // believed the phone held the headset from a session before the app
  // restarted.
  it("re-publishes CLAIM to a node that restarts while it is still the holder", async () => {
    const account = randomUUID();
    const nodeA = manifest({ supportedEventKinds: ["media"] });
    await startService([account]);

    const commandsA = collectCommands(rawClient, account, nodeA.nodeId);

    await publishRegistration(rawClient, account, nodeA);
    await publishEvent(rawClient, account, nodeA.nodeId, "media");
    await expect.poll(() => commandsA, { timeout: 2000 }).toEqual([{ type: "claim" }]);

    // Media stops normally. A is still the holder by rule 5 (last
    // claimed), which is correct and is not the bug.
    await publishEventEnd(rawClient, account, nodeA.nodeId, "media");
    await new Promise((resolve) => setTimeout(resolve, 300));
    expect(commandsA).toEqual([{ type: "claim" }]);

    // A's adapter restarts: a fresh process, holding no Bluetooth
    // connection, that registers again. The relay's holder has not
    // changed, so syncHolder alone says nothing - and A would sit there
    // believing it holds nothing while the relay believes it holds the
    // headset, with no way out. It must be told again.
    await publishRegistration(rawClient, account, nodeA);
    await expect.poll(() => commandsA, { timeout: 2000 }).toEqual([{ type: "claim" }, { type: "claim" }]);
  });

  it("clears a restarted node's stale signals so another node can take the route", async () => {
    const account = randomUUID();
    const nodeA = manifest({ supportedEventKinds: ["call"] });
    const nodeB = manifest({ supportedEventKinds: ["media"] });
    await startService([account]);

    const commandsB = collectCommands(rawClient, account, nodeB.nodeId);

    // A takes a call and its adapter dies mid-call, so no event_end is
    // ever sent for it. `call` outranks everything.
    await publishRegistration(rawClient, account, nodeA);
    await publishEvent(rawClient, account, nodeA.nodeId, "call");

    // A comes back. The call is over - the monitor that would have ended
    // it no longer exists - so the signal must not survive the restart,
    // or it pins the route to A permanently.
    await publishRegistration(rawClient, account, nodeA);

    await publishRegistration(rawClient, account, nodeB);
    await publishEvent(rawClient, account, nodeB.nodeId, "media");

    await expect.poll(() => commandsB, { timeout: 2000 }).toEqual([{ type: "claim" }]);
  });

  // #178. A relay that restarted, or whose MQTT connection dropped and
  // reconnected, knows nothing about nodes that are still running - it
  // learns of a node only from a registration. Adapters therefore
  // re-register periodically, carrying what they currently have active.
  it("learns an already-playing node from a periodic registration alone", async () => {
    const account = randomUUID();
    const nodeA = manifest({ supportedEventKinds: ["media"] });
    const nodeB = manifest({ supportedEventKinds: ["media"] });
    await startService([account]);

    const commandsA = collectCommands(rawClient, account, nodeA.nodeId);

    // B is registered and idle. A has never been seen by this service -
    // it has been playing since before the relay knew anything, and the
    // `media` *event* that started it was published to a relay that no
    // longer exists. Its next periodic registration is the only chance
    // this relay gets to find out.
    await publishRegistration(rawClient, account, nodeB);
    await publishRegistration(rawClient, account, nodeA, ["media"]);

    await expect.poll(() => commandsA, { timeout: 2000 }).toEqual([{ type: "claim" }]);
  });

  it("frees a stale signal when a later registration stops reporting it", async () => {
    const account = randomUUID();
    const nodeA = manifest({ supportedEventKinds: ["call"] });
    const nodeB = manifest({ supportedEventKinds: ["media"] });
    await startService([account]);

    const commandsB = collectCommands(rawClient, account, nodeB.nodeId);

    // A reports a call - which outranks everything - and never ends it
    // (#183 saw exactly this happen for real).
    await publishRegistration(rawClient, account, nodeA, ["call"]);
    await publishRegistration(rawClient, account, nodeB);
    await publishEvent(rawClient, account, nodeB.nodeId, "media");

    // A's next periodic registration simply doesn't mention the call, so
    // it clears - without needing an event_end that is never coming.
    await publishRegistration(rawClient, account, nodeA, []);

    await expect.poll(() => commandsB, { timeout: 2000 }).toEqual([{ type: "claim" }]);
  });
  // #191 / ADR 0018 decision 2. Detection, not correction: the repair for
  // a holder whose route has gone already happens via the re-asserted
  // claim plus the adapter's route-aware skip.
  it("reports drift when the recorded holder says it does not hold the route", async () => {
    const account = randomUUID();
    const nodeA = manifest({ supportedEventKinds: ["media"] });
    const drifts: RouteDrift[] = [];
    await startService([account], undefined, undefined, (d) => drifts.push(d));

    await publishRegistration(rawClient, account, nodeA);
    await publishEvent(rawClient, account, nodeA.nodeId, "media");
    await expect.poll(() => drifts.length === 0, { timeout: 1000 }).toBe(true);

    // A periodic registration from the holder saying the route is gone.
    await publishRegistration(rawClient, account, nodeA, ["media"], { audio: false });

    await expect.poll(() => drifts, { timeout: 2000 }).toEqual([
      { account, node: nodeA.nodeId, nodeHoldsRoute: false, believedHolder: nodeA.nodeId },
    ]);
  });

  it("reports drift when a node that is not the holder says it does hold the route", async () => {
    const account = randomUUID();
    const nodeA = manifest({ supportedEventKinds: ["media"] });
    const nodeB = manifest({ supportedEventKinds: ["media"] });
    const drifts: RouteDrift[] = [];
    await startService([account], undefined, undefined, (d) => drifts.push(d));

    await publishRegistration(rawClient, account, nodeA);
    await publishEvent(rawClient, account, nodeA.nodeId, "media");
    await publishRegistration(rawClient, account, nodeB, [], { audio: true });

    await expect.poll(() => drifts, { timeout: 2000 }).toEqual([
      { account, node: nodeB.nodeId, nodeHoldsRoute: true, believedHolder: nodeA.nodeId },
    ]);
  });

  /**
   * An absent observation is "no information", not "no". A node that
   * cannot read its route, or is mid-transition, must not be reported as
   * disagreeing - that would make every such registration look like a bug.
   */
  it("reports no drift when the node makes no route observation", async () => {
    const account = randomUUID();
    const nodeA = manifest({ supportedEventKinds: ["media"] });
    const drifts: RouteDrift[] = [];
    await startService([account], undefined, undefined, (d) => drifts.push(d));

    await publishRegistration(rawClient, account, nodeA);
    await publishEvent(rawClient, account, nodeA.nodeId, "media");
    await publishRegistration(rawClient, account, nodeA, ["media"]);
    await publishRegistration(rawClient, account, nodeA, ["media"], {});

    await new Promise((resolve) => setTimeout(resolve, 500));
    expect(drifts).toEqual([]);
  });

  it("agreement is not reported as drift", async () => {
    const account = randomUUID();
    const nodeA = manifest({ supportedEventKinds: ["media"] });
    const drifts: RouteDrift[] = [];
    await startService([account], undefined, undefined, (d) => drifts.push(d));

    await publishRegistration(rawClient, account, nodeA);
    await publishEvent(rawClient, account, nodeA.nodeId, "media");
    await publishRegistration(rawClient, account, nodeA, ["media"], { audio: true });

    await new Promise((resolve) => setTimeout(resolve, 500));
    expect(drifts).toEqual([]);
  });
});
