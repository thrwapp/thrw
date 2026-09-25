import { randomUUID } from "node:crypto";
import {
  commandsTopic,
  eventsTopic,
  heartbeatTopic,
  stateTopic,
  type EventKind,
  type NodeManifest,
} from "@thrw/protocol";
import {
  type CoalescedCommand,
  defaultMqttBrokerUrl,
  RelayMqttClient,
  type CommandPayload,
  type Scheduler,
  type StatePayload,
} from "@thrw/relay-core";
import mqtt, { type MqttClient } from "mqtt";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import {
  RelayService,
  type CommandOutcomeReported,
  type NodeEventObserved,
  type NodeReaped,
  type RegistrationObserved,
  type RouteDrift,
} from "../src/relay-service";

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
    supportedResourceTypes: ["audio"],
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

function publishJson(
  client: MqttClient,
  topic: string,
  payload: unknown,
  qos: 0 | 1 | 2 = 1,
  retain = false,
): Promise<void> {
  return new Promise((resolve, reject) => {
    client.publish(topic, JSON.stringify(payload), { qos, retain }, (err) => (err ? reject(err) : resolve()));
  });
}

function publishRegistration(
  client: MqttClient,
  account: string,
  nodeManifest: NodeManifest,
  activeEvents?: EventKind[],
  observedRoutes?: Record<string, boolean>,
): Promise<void> {
  return publishJson(client, eventsTopic(account, nodeManifest.nodeId, "audio"), {
    kind: REGISTRATION_KIND,
    manifest: nodeManifest,
    ...(activeEvents ? { activeEvents } : {}),
    ...(observedRoutes ? { observedRoutes } : {}),
  });
}

function publishEventEnd(client: MqttClient, account: string, node: string, type: EventKind): Promise<void> {
  return publishJson(client, eventsTopic(account, node, "audio"), { kind: EVENT_END_KIND, type });
}

function publishEvent(client: MqttClient, account: string, node: string, type: EventKind): Promise<void> {
  return publishJson(client, eventsTopic(account, node, "audio"), { type, priority: 1 });
}

/**
 * Reads the **retained** message on the state topic the way a node that
 * has just connected would - a fresh client, subscribing after the fact.
 *
 * That is the whole point of the test (#222): a subscription made after
 * the publish is the only thing that proves the message was retained
 * rather than merely sent. Polling `service`'s internals would prove
 * nothing about the broker.
 *
 * Resolves `undefined` when nothing is retained, rather than hanging -
 * "the topic is empty" is an assertion several tests here need to make.
 */
async function readRetainedState(account: string): Promise<StatePayload | undefined> {
  const topic = stateTopic(account, "audio");
  const client = await connectRawClient();
  try {
    return await new Promise<StatePayload | undefined>((resolve) => {
      const timer = setTimeout(() => resolve(undefined), 400);
      client.on("message", (messageTopic, message) => {
        if (messageTopic !== topic) return;
        clearTimeout(timer);
        resolve(JSON.parse(message.toString()) as StatePayload);
      });
      client.subscribe(topic, { qos: 1 });
    });
  } finally {
    await new Promise<void>((resolve) => client.end(false, {}, () => resolve()));
  }
}

/**
 * Counts every message that lands on the state topic from now on, so a
 * test can assert the relay is *quiet* rather than republishing the same
 * holder forever.
 *
 * The caller has to settle and clear once before counting: `rawClient`
 * connects as MQTT 3.1.1, where a subscribe always delivers the current
 * retained message and there is no `retainHandling` option to suppress
 * it. Suppressing it here would need a second MQTT 5 client, which is
 * more machinery than one discarded message is worth.
 */
function collectStatePublishes(client: MqttClient, account: string): StatePayload[] {
  const received: StatePayload[] = [];
  const topic = stateTopic(account, "audio");
  client.subscribe(topic, { qos: 1 });
  client.on("message", (messageTopic, message) => {
    if (messageTopic !== topic) return;
    received.push(JSON.parse(message.toString()) as StatePayload);
  });
  return received;
}

/**
 * Clears the retained message on `account`'s state topic - an empty
 * retained publish is MQTT's delete. Tests use random account ids, so
 * this is only needed where a test deliberately leaves one behind for
 * the *next* service to find.
 */
function clearRetainedState(client: MqttClient, account: string): Promise<void> {
  return new Promise((resolve, reject) => {
    client.publish(stateTopic(account, "audio"), "", { qos: 1, retain: true }, (err) =>
      err ? reject(err) : resolve(),
    );
  });
}

/**
 * Lets the real broker deliver in-flight messages and the service process
 * them. Used where there's no observable state change to poll on - a
 * heartbeat arriving updates only private bookkeeping (#142).
 */
function settle(ms = 300): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Collects the commands published to `node`, **stripped down to the
 * decision they carry**.
 *
 * `publishCommand` stamps every command with `seq` and `epoch` (#210).
 * Those are transport concerns: whether the relay issues them correctly
 * is asserted in `relay-core`'s own tests, against the wire. The tests
 * in this file are about *arbitration* - who should hold the resource
 * and when - so they assert on `{ type }` and would otherwise have to be
 * rewritten every time the envelope grows a field.
 */
function collectCommands(client: MqttClient, account: string, node: string): CommandPayload[] {
  const received: CommandPayload[] = [];
  const topic = commandsTopic(account, node, "audio");
  client.subscribe(topic, { qos: 1 });
  client.on("message", (messageTopic, message) => {
    if (messageTopic !== topic) return;
    const { type } = JSON.parse(message.toString()) as CommandPayload;
    received.push({ type });
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
    // #245. Grouped into one optional bag rather than three more
    // positional parameters - this helper already takes four, and a
    // fifth/sixth/seventh would make every existing call site an
    // exercise in counting commas.
    observers: {
      onRegistration?: (registration: RegistrationObserved) => void;
      onNodeEvent?: (event: NodeEventObserved) => void;
      onNodeReaped?: (reaped: NodeReaped) => void;
      onCommandOutcome?: (outcome: CommandOutcomeReported) => void;
      onCommandCoalesced?: (coalesced: CoalescedCommand) => void;
    } = {},
  ): Promise<RelayService> {
    const client = await RelayMqttClient.connect(BROKER_URL);
    clients.push(client);
    const service = new RelayService({
      client,
      accounts,
      scheduler,
      now,
      onRouteDrift,
      ...observers,
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
    // ended) - the holder reverts to A, another real RELEASE(B)+CLAIM(A) pair.
    //
    // A's re-claim is now *held* rather than immediate (#277, ADR 0020
    // decision 1): A was released under a second ago, and a claim arriving
    // inside the release window is the A -> B -> A bounce the coalescing window
    // exists to damp. It still arrives, up to DEFAULT_RELEASE_WINDOW_MS (3s)
    // later, so this poll needs longer than the 2s the rest of the test uses.
    // B's RELEASE is not held - a release never is, or the handoff waiting
    // behind it would stall.
    await publishEventEnd(rawClient, account, nodeB.nodeId, "call");
    await expect.poll(() => commandsB, { timeout: 2000 }).toEqual([{ type: "claim" }, { type: "release" }]);
    await expect
      .poll(() => commandsA, { timeout: 6000 })
      .toEqual([{ type: "claim" }, { type: "release" }, { type: "claim" }]);

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

    // #263: three missed beats used to be enough to do all of that. It
    // is now only the "stale" mark, and deliberately changes nothing a
    // node can feel - a device mid-call that has missed three beats is
    // far more likely to be a dozing phone than a departed one, and in
    // 9h49m of production log every single one of 164 reaps turned out to
    // be a live node that came back.
    now += 90_001;
    scheduler.fire(5_000);
    expect(service.engineFor(account)?.currentHolder()).toBe(nodeA.nodeId);
    await settle();
    expect(commandsA).toEqual([{ type: "claim" }]);

    // #130's guarantee itself is unchanged - a silently-departed node
    // does not keep its claim forever - it just takes the departure
    // threshold to get there instead of the stale one.
    now += 210_001;
    scheduler.fire(5_000);

    // forgetNode's own "no auto-return grace period for a silently-gone
    // node" judgment call means this is immediate - no second sweep or
    // timer fire needed.
    expect(service.engineFor(account)?.currentHolder()).toBeNull();
    await expect.poll(() => commandsA, { timeout: 2000 }).toEqual([{ type: "claim" }, { type: "release" }]);
  });

  // #263 criterion 3, and the reason the two thresholds exist: the node
  // this describes is the one the old single rule handled worst.
  it("keeps a quiet node's signals and its route until it is really gone (#263)", async () => {
    const account = randomUUID();
    const nodeA = manifest({ supportedEventKinds: ["call"] });
    const scheduler = new FakeScheduler();
    let now = 0;
    const reaped: NodeReaped[] = [];
    const service = await startService([account], scheduler, () => now, undefined, {
      onNodeReaped: (r) => reaped.push(r),
    });

    const commandsA = collectCommands(rawClient, account, nodeA.nodeId);

    await publishRegistration(rawClient, account, nodeA);
    await publishEvent(rawClient, account, nodeA.nodeId, "call");
    await expect.poll(() => commandsA, { timeout: 2000 }).toEqual([{ type: "claim" }]);

    // Silent for well over three missed beats, and repeatedly swept -
    // a dozing phone's whole day. The holder must not move, and nothing
    // may be published at it: this is the "asleep while holding the route"
    // case that would take the headset off a device still using it.
    for (let elapsed = 0; elapsed < 3; elapsed++) {
      now += 60_000;
      scheduler.fire(5_000);
    }
    expect(now).toBeGreaterThan(90_000);
    expect(now).toBeLessThan(300_000);

    expect(service.engineFor(account)?.currentHolder()).toBe(nodeA.nodeId);
    await settle();
    expect(commandsA).toEqual([{ type: "claim" }]);
    expect(reaped).toEqual([]);
  });

  // #236. The production relay logged the headset alternating Mac <->
  // Pixel every ~90-120s for nine and a half hours overnight with nobody
  // touching either device. This is that, reproduced deterministically.
  //
  // The trigger is an adapter whose heartbeat publisher has died while
  // its MQTT connection is still up - `HeartbeatPublisher.run()` is a
  // `while true` loop that exits on the first throw from
  // `publishHeartbeat()`, and `NodeRuntime` logs that and never restarts
  // it (`heartbeatPublisher failed: noConnection` was observed on the
  // deployed Mac adapter, process still alive and still connected).
  //
  // Such a node still registers every 120s. That is enough on its own,
  // because `trackHeartbeat` treats a registration as liveness evidence.
  it("oscillates the holder when a registering node never heartbeats (#236)", async () => {
    const account = randomUUID();
    const nodeA = manifest();
    const nodeB = manifest();
    const scheduler = new FakeScheduler();
    let now = 0;
    const service = await startService([account], scheduler, () => now);

    const holders: (string | null)[] = [];
    const record = () => holders.push(service.engineFor(account)?.currentHolder() ?? null);

    // Both nodes are genuinely playing media the whole time. Neither ever
    // publishes to its heartbeat topic - the only thing either sends is
    // its periodic registration, carrying the trigger it still has active.
    await publishRegistration(rawClient, account, nodeA, ["media"]);
    await expect.poll(() => service.engineFor(account)?.currentHolder(), { timeout: 2000 }).toBe(nodeA.nodeId);
    await publishRegistration(rawClient, account, nodeB, ["media"]);
    await expect.poll(() => service.engineFor(account)?.currentHolder(), { timeout: 2000 }).toBe(nodeB.nodeId);

    // Registration cycles, offset so the reap falls between them. Driven
    // past the *departure* threshold rather than the stale one (#263):
    // this mechanism is unchanged, it just takes 300s to come round
    // instead of 90s. Deliberately still asserted - #263 slowed this down
    // and did not fix it, and a future reader should not mistake the
    // slower cadence for the relay-side half of #236 being closed.
    for (const node of [nodeA, nodeB, nodeA, nodeB, nodeA, nodeB]) {
      now += 300_001;
      scheduler.fire(5_000); // the sweep reaps whoever last registered
      record();

      await publishRegistration(rawClient, account, node, ["media"]);
      await expect.poll(() => service.engineFor(account)?.currentHolder(), { timeout: 2000 }).toBe(node.nodeId);
      record();
    }

    // Every re-registration takes the headset back, because forgetNode
    // dropped the signal entirely and reconcileSignals re-adds it with a
    // fresh orderCounter - so it looks like the most recently started
    // trigger. Nothing about either device changed.
    const handoffs = holders.filter((h, i) => i > 0 && h !== holders[i - 1]).length;
    expect(handoffs).toBeGreaterThanOrEqual(6);
    expect(holders.filter((h) => h === nodeA.nodeId).length).toBeGreaterThan(0);
    expect(holders.filter((h) => h === nodeB.nodeId).length).toBeGreaterThan(0);
  });

  it("does not oscillate when the same nodes keep heartbeating (#236 control)", async () => {
    // The control the test above needs to mean anything: identical
    // registrations, identical timings, the one difference being that
    // both nodes actually beat. The holder must not move.
    const account = randomUUID();
    const nodeA = manifest();
    const nodeB = manifest();
    const scheduler = new FakeScheduler();
    let now = 0;
    const service = await startService([account], scheduler, () => now);

    await publishRegistration(rawClient, account, nodeA, ["media"]);
    await expect.poll(() => service.engineFor(account)?.currentHolder(), { timeout: 2000 }).toBe(nodeA.nodeId);
    await publishRegistration(rawClient, account, nodeB, ["media"]);
    await expect.poll(() => service.engineFor(account)?.currentHolder(), { timeout: 2000 }).toBe(nodeB.nodeId);

    const holders: (string | null)[] = [];
    for (const node of [nodeA, nodeB, nodeA, nodeB, nodeA, nodeB]) {
      // A beat from both, well inside the 90s budget, exactly as a
      // healthy adapter's 30s loop would send.
      await publishJson(rawClient, heartbeatTopic(account, nodeA.nodeId), {});
      await publishJson(rawClient, heartbeatTopic(account, nodeB.nodeId), {});
      await new Promise((resolve) => setTimeout(resolve, 50));

      now += 60_000;
      scheduler.fire(5_000);
      await publishRegistration(rawClient, account, node, ["media"]);
      await new Promise((resolve) => setTimeout(resolve, 100));
      holders.push(service.engineFor(account)?.currentHolder() ?? null);
    }

    expect(new Set(holders)).toEqual(new Set([nodeB.nodeId]));
  });

  // #245. The relay's original four log events are all outputs. These
  // cover the inputs - what it was actually told - which is what four
  // separate live diagnoses needed and could not get.
  describe("input observability (#245)", () => {
    it("reports what a node claimed on registration, and the holder either side", async () => {
      const account = randomUUID();
      const nodeA = manifest({ platform: "android", adapterVersion: "0.1.1" });
      const seen: RegistrationObserved[] = [];
      await startService([account], undefined, undefined, undefined, {
        onRegistration: (r) => seen.push(r),
      });

      await publishRegistration(rawClient, account, nodeA, ["media"], { audio: true });
      await expect.poll(() => seen.length, { timeout: 2000 }).toBe(1);

      // The whole point: which node, on what version, claiming what.
      expect(seen[0]).toMatchObject({
        account,
        node: nodeA.nodeId,
        resource: "audio",
        platform: "android",
        adapterVersion: "0.1.1",
        activeEvents: ["media"],
        observedRoutes: { audio: true },
        holderBefore: null,
        holderAfter: nodeA.nodeId,
      });
    });

    it("reports a node that reports nothing active, which is the case that reads as a bug", async () => {
      // A node reporting `[]` is indistinguishable in the old logs from a
      // node that never registered at all - and "media played but the
      // holder never moved" was exactly the question that could not be
      // answered.
      const account = randomUUID();
      const nodeA = manifest();
      const seen: RegistrationObserved[] = [];
      await startService([account], undefined, undefined, undefined, {
        onRegistration: (r) => seen.push(r),
      });

      await publishRegistration(rawClient, account, nodeA);
      await expect.poll(() => seen.length, { timeout: 2000 }).toBe(1);

      expect(seen[0]).toMatchObject({
        node: nodeA.nodeId,
        activeEvents: [],
        observedRoutes: {},
        holderAfter: null,
      });
    });

    it("reports each trigger start and end with the holder either side", async () => {
      const account = randomUUID();
      const nodeA = manifest();
      const seen: NodeEventObserved[] = [];
      await startService([account], undefined, undefined, undefined, {
        onNodeEvent: (e) => seen.push(e),
      });

      await publishRegistration(rawClient, account, nodeA);
      await publishEvent(rawClient, account, nodeA.nodeId, "media");
      await expect.poll(() => seen.length, { timeout: 2000 }).toBe(1);
      expect(seen[0]).toMatchObject({
        node: nodeA.nodeId,
        kind: "event",
        type: "media",
        holderBefore: null,
        holderAfter: nodeA.nodeId,
      });

      await publishEventEnd(rawClient, account, nodeA.nodeId, "media");
      await expect.poll(() => seen.length, { timeout: 2000 }).toBe(2);
      expect(seen[1]).toMatchObject({
        kind: "event_end",
        type: "media",
        holderBefore: nodeA.nodeId,
        // Rule 5: the last claimer keeps it once the signal ends.
        holderAfter: nodeA.nodeId,
      });
    });

    it("reports a reaped node and how long it had been silent", async () => {
      // The line whose absence made #236 invisible: before this, a reap
      // produced only a bare holder_change with no recorded cause.
      const account = randomUUID();
      const nodeA = manifest();
      const scheduler = new FakeScheduler();
      let now = 0;
      const seen: NodeReaped[] = [];
      const service = await startService([account], scheduler, () => now, undefined, {
        onNodeReaped: (r) => seen.push(r),
      });

      await publishRegistration(rawClient, account, nodeA, ["media"]);
      await expect
        .poll(() => service.engineFor(account)?.currentHolder(), { timeout: 2000 })
        .toBe(nodeA.nodeId);

      // Nothing at the stale mark - the line means "a node lost its
      // signals", and at 90s it has not (#263 criterion 4: 164 of these
      // in ten hours was burying the signal the event was added to find).
      now += 90_001;
      scheduler.fire(5_000);
      expect(seen).toEqual([]);

      now += 210_001;
      scheduler.fire(5_000);

      expect(seen).toHaveLength(1);
      expect(seen[0]).toMatchObject({ account, node: nodeA.nodeId });
      expect(seen[0]?.silentForMs).toBeGreaterThanOrEqual(300_000);
    });
  });

  // ADR 0020 decision 1 (#277). The unit-level behaviour lives in
  // packages/relay-core's command-coalescer tests; this is the wiring - that
  // RelayService actually routes its dispatch through the coalescer and reports
  // what it dropped.
  describe("command coalescing (#277)", () => {
    it("reports a coalesced claim as superseded rather than as a failure", async () => {
      const account = randomUUID();
      const nodeA = manifest();
      const nodeB = manifest();
      const scheduler = new FakeScheduler();
      let now = 0;
      const coalesced: CoalescedCommand[] = [];
      const outcomes: CommandOutcomeReported[] = [];
      const service = await startService([account], scheduler, () => now, undefined, {
        onCommandCoalesced: (c) => coalesced.push(c),
        onCommandOutcome: (o) => outcomes.push(o),
      });

      // A takes it, then B, then A again - all inside A's release window, which
      // is the bounce ADR 0020 damps.
      await publishRegistration(rawClient, account, nodeA, ["media"]);
      await expect.poll(() => service.engineFor(account)?.currentHolder(), { timeout: 2000 }).toBe(nodeA.nodeId);
      await publishRegistration(rawClient, account, nodeB, ["media"]);
      await expect.poll(() => service.engineFor(account)?.currentHolder(), { timeout: 2000 }).toBe(nodeB.nodeId);
      now += 200;
      await publishEvent(rawClient, account, nodeA.nodeId, "media");
      await expect.poll(() => service.engineFor(account)?.currentHolder(), { timeout: 2000 }).toBe(nodeA.nodeId);
      now += 200;
      await publishEventEnd(rawClient, account, nodeA.nodeId, "media");
      await settle();

      // Something was withheld, and it is reported as superseded - never as a
      // failure, which is what would skew ADR 0019's switch success rate.
      expect(coalesced.length).toBeGreaterThan(0);
      for (const entry of coalesced) {
        expect(entry.account).toBe(account);
        expect(["superseded_by_newer_command", "already_in_target_state"]).toContain(entry.reason);
      }
      // Coalescing is the relay declining to send. No node can report an
      // outcome for a command it never received, so nothing lands in the
      // ADR 0019 stream from this.
      expect(outcomes).toEqual([]);
    });

    it("still re-asserts a claim to a node that restarts inside the window", async () => {
      // The hazard that makes the re-assert bypass coalescing: a restarted node
      // has lost its own state, so a claim it is re-sent must not be dropped as
      // "already in target state".
      const account = randomUUID();
      const nodeA = manifest();
      const scheduler = new FakeScheduler();
      let now = 0;
      const service = await startService([account], scheduler, () => now);
      const commandsA = collectCommands(rawClient, account, nodeA.nodeId);

      await publishRegistration(rawClient, account, nodeA, ["media"]);
      await expect.poll(() => commandsA, { timeout: 2000 }).toEqual([{ type: "claim" }]);

      // Re-registers 200ms later, still the holder: the relay re-asserts, and
      // the window must not swallow it.
      now += 200;
      await publishRegistration(rawClient, account, nodeA, ["media"]);
      await expect.poll(() => commandsA, { timeout: 2000 }).toEqual([{ type: "claim" }, { type: "claim" }]);
      expect(service.engineFor(account)?.currentHolder()).toBe(nodeA.nodeId);
    });

    // #284. A node already holding the route needs no repair, and the
    // command is not free: the adapter runs its audio gate around every
    // one, so a claim that changes nothing still pauses and resumes the
    // user's media.
    it("does not re-assert to a holder that reports it already holds the route", async () => {
      const account = randomUUID();
      const nodeA = manifest();
      const scheduler = new FakeScheduler();
      let now = 0;
      await startService([account], scheduler, () => now);
      const commandsA = collectCommands(rawClient, account, nodeA.nodeId);

      await publishRegistration(rawClient, account, nodeA, ["media"]);
      await expect.poll(() => commandsA, { timeout: 2000 }).toEqual([{ type: "claim" }]);

      now += 120_000;
      await publishRegistration(rawClient, account, nodeA, ["media"], { audio: true });
      now += 120_000;
      await publishRegistration(rawClient, account, nodeA, ["media"], { audio: true });

      // Deliberately a settle rather than a poll: the assertion is that
      // nothing *more* arrives, which a poll cannot express.
      await new Promise((resolve) => setTimeout(resolve, 500));
      expect(commandsA).toEqual([{ type: "claim" }]);
    });

    // #287. The loop that fought a user on a call: the headset was moved
    // to a laptop running no adapter, so the holder kept reporting no
    // route, and the relay kept taking it back - every two minutes, for
    // half an hour.
    it("gives up re-asserting after a bounded number of attempts", async () => {
      const account = randomUUID();
      const nodeA = manifest();
      const scheduler = new FakeScheduler();
      let now = 0;
      await startService([account], scheduler, () => now);
      const commandsA = collectCommands(rawClient, account, nodeA.nodeId);

      await publishRegistration(rawClient, account, nodeA, ["media"]);
      await expect.poll(() => commandsA, { timeout: 2000 }).toEqual([{ type: "claim" }]);

      // Five periodic registrations, each saying "I am the holder and I
      // do not have the route" - the exact shape #287 recorded.
      for (let i = 0; i < 5; i += 1) {
        now += 120_000;
        await publishRegistration(rawClient, account, nodeA, ["media"], { audio: false });
      }
      await new Promise((resolve) => setTimeout(resolve, 500));

      // The initial claim, plus MAX_HOLDER_REASSERTS re-assertions, and
      // then silence - not one per registration for as long as it runs.
      expect(commandsA).toEqual([{ type: "claim" }, { type: "claim" }, { type: "claim" }]);
    });

    // #301, reported from real use: "I just tried a call (whatsapp and
    // mobile) neither moved the call from mac to pixel."
    //
    // Arbitration acts on holder *changes*, so once the bound above has
    // given up on a holder that cannot take the route, nothing moves the
    // headset: every recomputation finds the holder unchanged and sends
    // nothing. A call must always be able to break that.
    it("lets a call break a wedge the re-assert bound has given up on", async () => {
      const account = randomUUID();
      const nodeA = manifest();
      const scheduler = new FakeScheduler();
      let now = 0;
      await startService([account], scheduler, () => now);
      const commandsA = collectCommands(rawClient, account, nodeA.nodeId);

      await publishRegistration(rawClient, account, nodeA, ["media"]);
      // Exhaust the budget: the holder keeps saying it has no route.
      for (let i = 0; i < 5; i += 1) {
        now += 120_000;
        await publishRegistration(rawClient, account, nodeA, ["media"], { audio: false });
      }
      await expect.poll(() => commandsA.length, { timeout: 2000 }).toBe(3);

      // The call. The holder does not change - this node already is the
      // holder - so without #301 nothing at all is sent.
      await publishEvent(rawClient, account, nodeA.nodeId, "call");

      await expect.poll(() => commandsA.length, { timeout: 2000 }).toBe(4);
      expect(commandsA[3]).toEqual({ type: "claim" });
    });

    // Ambient triggers must not do this. They fire constantly, and
    // dispatching on every one is how #287's fighting started.
    it("does not let media break the wedge", async () => {
      const account = randomUUID();
      const nodeA = manifest();
      const scheduler = new FakeScheduler();
      let now = 0;
      await startService([account], scheduler, () => now);
      const commandsA = collectCommands(rawClient, account, nodeA.nodeId);

      await publishRegistration(rawClient, account, nodeA, ["media"]);
      for (let i = 0; i < 5; i += 1) {
        now += 120_000;
        await publishRegistration(rawClient, account, nodeA, ["media"], { audio: false });
      }
      await expect.poll(() => commandsA.length, { timeout: 2000 }).toBe(3);

      await publishEvent(rawClient, account, nodeA.nodeId, "media");

      await new Promise((resolve) => setTimeout(resolve, 500));
      expect(commandsA.length).toBe(3);
    });
  });

  // ADR 0019 / #206. Before this a command was fire-and-forget: the relay
  // published it and never learned whether the switch happened.
  describe("command outcomes (#206)", () => {
    function publishOutcome(
      client: MqttClient,
      account: string,
      node: string,
      body: Record<string, unknown>,
    ): Promise<void> {
      return publishJson(client, eventsTopic(account, node, "audio"), {
        kind: "command_outcome",
        ...body,
      });
    }

    it("records a succeeded outcome, which is what gives a success rate its denominator", async () => {
      const account = randomUUID();
      const nodeA = manifest();
      const seen: CommandOutcomeReported[] = [];
      await startService([account], undefined, undefined, undefined, {
        onCommandOutcome: (o) => seen.push(o),
      });

      await publishRegistration(rawClient, account, nodeA);
      await publishOutcome(rawClient, account, nodeA.nodeId, {
        epoch: "epoch-1",
        seq: 7,
        resourceType: "audio",
        outcome: "succeeded",
        durationMs: 3_120,
      });

      await expect.poll(() => seen.length, { timeout: 2000 }).toBe(1);
      expect(seen[0]).toMatchObject({
        account,
        node: nodeA.nodeId,
        resource: "audio",
        epoch: "epoch-1",
        seq: 7,
        outcome: "succeeded",
        durationMs: 3_120,
      });
    });

    it("records a failure with its reason code", async () => {
      const account = randomUUID();
      const nodeA = manifest();
      const seen: CommandOutcomeReported[] = [];
      await startService([account], undefined, undefined, undefined, {
        onCommandOutcome: (o) => seen.push(o),
      });

      await publishRegistration(rawClient, account, nodeA);
      await publishOutcome(rawClient, account, nodeA.nodeId, {
        epoch: "epoch-1",
        seq: 8,
        resourceType: "audio",
        outcome: "failed",
        reason: "target_device_unreachable",
        durationMs: 1_400,
      });

      await expect.poll(() => seen.length, { timeout: 2000 }).toBe(1);
      expect(seen[0]).toMatchObject({
        outcome: "failed",
        reason: "target_device_unreachable",
      });
    });

    it("does not let an outcome touch arbitration", async () => {
      // An outcome is a report *about* a command, not a trigger. If it
      // moved the holder, a late outcome from a superseded command could
      // yank the headset back - so this asserts the absence of an effect,
      // which is the whole safety property.
      const account = randomUUID();
      const nodeA = manifest();
      const nodeB = manifest();
      const service = await startService([account]);

      await publishRegistration(rawClient, account, nodeA);
      await publishRegistration(rawClient, account, nodeB);
      await publishEvent(rawClient, account, nodeB.nodeId, "media");
      await expect
        .poll(() => service.engineFor(account)?.currentHolder(), { timeout: 2000 })
        .toBe(nodeB.nodeId);

      await publishOutcome(rawClient, account, nodeA.nodeId, {
        epoch: "epoch-1",
        seq: 1,
        resourceType: "audio",
        outcome: "failed",
        reason: "bluetooth_unavailable",
        durationMs: 200,
      });
      await new Promise((resolve) => setTimeout(resolve, 300));

      expect(service.engineFor(account)?.currentHolder()).toBe(nodeB.nodeId);
    });

    it("accepts an outcome for an unsequenced command", async () => {
      // Both adapters still act on a command carrying neither epoch nor
      // seq (ADR 0018 point 1 shipped relay-first, so builds exist that
      // ran against a relay stamping nothing). Rejecting the outcome for
      // one would make acting on it an unmeasurable switch - the exact
      // gap this mechanism exists to close. The first version of this
      // guard required both fields and would have failed here.
      const account = randomUUID();
      const nodeA = manifest();
      const seen: CommandOutcomeReported[] = [];
      await startService([account], undefined, undefined, undefined, {
        onCommandOutcome: (o) => seen.push(o),
      });

      await publishRegistration(rawClient, account, nodeA);
      await publishOutcome(rawClient, account, nodeA.nodeId, {
        resourceType: "audio",
        outcome: "succeeded",
        durationMs: 2_400,
      });

      await expect.poll(() => seen.length, { timeout: 2000 }).toBe(1);
      expect(seen[0]).toMatchObject({ outcome: "succeeded", durationMs: 2_400 });
      expect(seen[0]?.epoch).toBeUndefined();
      expect(seen[0]?.seq).toBeUndefined();
    });

    it("drops a malformed outcome rather than skewing the data with it", async () => {
      // This is the one payload treated as evidence about reliability, so
      // a `failed` with no reason - unaggregatable - is dropped rather
      // than recorded as a failure of unknown cause.
      const account = randomUUID();
      const nodeA = manifest();
      const seen: CommandOutcomeReported[] = [];
      await startService([account], undefined, undefined, undefined, {
        onCommandOutcome: (o) => seen.push(o),
      });

      await publishRegistration(rawClient, account, nodeA);
      await publishOutcome(rawClient, account, nodeA.nodeId, {
        epoch: "epoch-1",
        seq: 9,
        resourceType: "audio",
        outcome: "failed",
        durationMs: 500,
      });
      await publishOutcome(rawClient, account, nodeA.nodeId, {
        epoch: "epoch-1",
        seq: 10,
        resourceType: "audio",
        outcome: "not_a_real_outcome",
        durationMs: 500,
      });
      await new Promise((resolve) => setTimeout(resolve, 400));

      expect(seen).toEqual([]);
    });
  });

  it("drops an unrecognized payload shape instead of throwing or registering anything", async () => {
    const account = randomUUID();
    const node = randomUUID();
    const service = await startService([account]);

    await publishJson(rawClient, eventsTopic(account, node, "audio"), { unrelated: "shape" });
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

  // #222. `architecture.md` and ADR 0001 have always specified this
  // topic; nothing published it, so nothing could observe who holds a
  // resource. Every test below reads it the way a node would - a fresh
  // client subscribing after the fact - because a subscription made
  // *after* the publish is the only thing that proves retention.
  describe("the retained state topic (#222)", () => {
    it("announces the holder, and a late subscriber still gets it", async () => {
      const account = randomUUID();
      const nodeA = manifest({ supportedEventKinds: ["call"] });
      await startService([account]);

      await publishRegistration(rawClient, account, nodeA);
      await publishEvent(rawClient, account, nodeA.nodeId, "call");

      await expect.poll(() => readRetainedState(account), { timeout: 2000 }).toEqual({
        holder: nodeA.nodeId,
      });
    });

    it("follows a real handoff", async () => {
      const account = randomUUID();
      const nodeA = manifest({ supportedEventKinds: ["call"] });
      const nodeB = manifest({ supportedEventKinds: ["call"] });
      await startService([account]);
      await publishRegistration(rawClient, account, nodeA);
      await publishRegistration(rawClient, account, nodeB);

      await publishEvent(rawClient, account, nodeA.nodeId, "call");
      await expect.poll(() => readRetainedState(account), { timeout: 2000 }).toEqual({
        holder: nodeA.nodeId,
      });

      await publishEvent(rawClient, account, nodeB.nodeId, "call");
      await expect.poll(() => readRetainedState(account), { timeout: 2000 }).toEqual({
        holder: nodeB.nodeId,
      });
    });

    /**
     * The state topic reports the relay's *actual* holder rule, not an
     * intuition about one. `PriorityEngine.currentHolder()` is
     * `computeActiveHolder() ?? lastClaimed`, so when the last signal
     * ends the holder does **not** become nobody - the last claimer
     * keeps it until something outranks it or it is forgotten. That is
     * rule 5, and it is why a call ending does not fling the headset
     * back to a device nobody is using.
     *
     * Written the other way round first, asserting `holder: null`, and
     * it failed. Worth keeping as an assertion rather than a comment:
     * the state topic is the surface a reader will form their mental
     * model from, so if it ever *did* report null here, the readout and
     * the arbitration would disagree.
     */
    it("keeps reporting the last claimer after the signal ends (rule 5)", async () => {
      const account = randomUUID();
      const nodeA = manifest({ supportedEventKinds: ["call"] });
      await startService([account]);
      await publishRegistration(rawClient, account, nodeA);
      await publishEvent(rawClient, account, nodeA.nodeId, "call");
      await expect.poll(() => readRetainedState(account), { timeout: 2000 }).toEqual({
        holder: nodeA.nodeId,
      });

      await publishEventEnd(rawClient, account, nodeA.nodeId, "call");
      await settle();

      expect(await readRetainedState(account)).toEqual({ holder: nodeA.nodeId });
    });

    /**
     * Where `holder: null` does come from: the node goes silent, the
     * heartbeat sweep forgets it (#130/#142), and the resource really is
     * free. `null` is a real answer - "nobody holds this" - and
     * deliberately distinct from the topic being empty, which means
     * "nobody has told you anything".
     */
    it("reports nobody once a silent node is swept", async () => {
      const account = randomUUID();
      const nodeA = manifest({ supportedEventKinds: ["call"] });
      const scheduler = new FakeScheduler();
      let now = 0;
      await startService([account], scheduler, () => now);
      await publishRegistration(rawClient, account, nodeA);
      await publishEvent(rawClient, account, nodeA.nodeId, "call");
      await expect.poll(() => readRetainedState(account), { timeout: 2000 }).toEqual({
        holder: nodeA.nodeId,
      });

      // Past the departure threshold with no beats at all (#263 - 120s
      // is now merely stale, and stale deliberately publishes nothing).
      now += 300_001;
      scheduler.fire(5_000);

      await expect.poll(() => readRetainedState(account), { timeout: 2000 }).toEqual({ holder: null });
    });

    /**
     * The case that makes this more than a few lines.
     *
     * A retained message outlives the process that wrote it, and this
     * relay holds all its state in memory (the premise of #178). So a
     * restart leaves the broker serving the *previous* process's answer
     * while the new one believes nothing - and `syncHolder` returns
     * early when the holder has not changed, so it would never correct
     * it. Registration is the only thing that runs in that window.
     *
     * Without the `publishedHolder === undefined` case, a relay that
     * restarted during a quiet period would leave a confident, wrong,
     * retained answer standing indefinitely.
     */
    it("overwrites a stale retained message left by a previous relay process", async () => {
      const account = randomUUID();
      const nodeA = manifest({ supportedEventKinds: ["call"] });
      const ghost = randomUUID();

      // Exactly what a previous process would have left behind: a
      // retained claim about a node this new relay has never heard of.
      await publishJson(rawClient, stateTopic(account, "audio"), { holder: ghost }, 1, true);
      expect(await readRetainedState(account)).toEqual({ holder: ghost });

      await startService([account]);
      await publishRegistration(rawClient, account, nodeA);

      await expect.poll(() => readRetainedState(account), { timeout: 2000 }).toEqual({ holder: null });
    });

    it("is quiet once it has published the current holder", async () => {
      const account = randomUUID();
      const nodeA = manifest({ supportedEventKinds: ["call"] });
      await startService([account]);
      await publishRegistration(rawClient, account, nodeA);
      await publishEvent(rawClient, account, nodeA.nodeId, "call");
      await expect.poll(() => readRetainedState(account), { timeout: 2000 }).toEqual({
        holder: nodeA.nodeId,
      });

      // #178 re-registers every 2 minutes per node, forever. Publishing
      // an unchanged holder each time would be pure noise on a topic
      // whose whole value is being a stable, readable answer.
      const publishes = collectStatePublishes(rawClient, account);
      // The broker delivers the *existing* retained message on
      // subscribe, and this client speaks MQTT 3.1.1 where `rh` does not
      // exist to suppress that - so let it arrive and discard it, rather
      // than counting someone else's old publish as a new one. (The
      // first version of this test did exactly that and failed.)
      await settle();
      publishes.length = 0;

      await publishRegistration(rawClient, account, nodeA);
      await publishRegistration(rawClient, account, nodeA);
      await settle();

      expect(publishes).toEqual([]);
    });

    it("keeps accounts separate", async () => {
      const accountA = randomUUID();
      const accountB = randomUUID();
      const nodeA = manifest({ supportedEventKinds: ["call"] });
      await startService([accountA, accountB]);
      await publishRegistration(rawClient, accountA, nodeA);

      await publishEvent(rawClient, accountA, nodeA.nodeId, "call");
      await expect.poll(() => readRetainedState(accountA), { timeout: 2000 }).toEqual({
        holder: nodeA.nodeId,
      });

      expect(await readRetainedState(accountB)).toBeUndefined();
    });
  });
});
