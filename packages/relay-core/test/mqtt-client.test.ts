import { randomUUID } from "node:crypto";
import {
  commandsTopic,
  eventsTopic,
  heartbeatTopic,
  stateTopic,
  TopicQos,
} from "@thrw/protocol";
import mqtt, { type IPublishPacket, type MqttClient } from "mqtt";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  defaultMqttBrokerUrl,
  RelayMqttClient,
  type CommandPayload,
  type EventPayload,
  type StatePayload,
} from "../src/mqtt-client";

type ReceivedNodeEvent = { payload: unknown; node: string };

// Integration tests against a real MQTT broker (acceptance criterion 5) -
// CI's ci.yml starts Mosquitto and sets MQTT_BROKER_URL; defaultMqttBrokerUrl()
// falls back to the same address for local dev.
const BROKER_URL = defaultMqttBrokerUrl();

function waitForMessage(
  client: MqttClient,
  topic: string,
): Promise<{ payload: unknown; packet: IPublishPacket }> {
  return new Promise((resolve) => {
    const handler = (messageTopic: string, message: Buffer, packet: IPublishPacket) => {
      if (messageTopic !== topic) return;
      client.removeListener("message", handler);
      resolve({ payload: JSON.parse(message.toString()) as unknown, packet });
    };
    client.on("message", handler);
  });
}

function connectRawClient(): Promise<MqttClient> {
  return new Promise((resolve, reject) => {
    const client = mqtt.connect(BROKER_URL);
    client.once("connect", () => resolve(client));
    client.once("error", reject);
  });
}

describe("RelayMqttClient (real broker)", () => {
  let relayClient: RelayMqttClient;
  let verifier: MqttClient;

  beforeAll(async () => {
    relayClient = await RelayMqttClient.connect(BROKER_URL);
    verifier = await connectRawClient();
  });

  afterAll(async () => {
    await relayClient.end();
    await new Promise<void>((resolve) => verifier.end(false, {}, () => resolve()));
  });

  it("publishes events at QoS 1 to @thrw/protocol's eventsTopic", async () => {
    const account = randomUUID();
    const node = randomUUID();
    const topic = eventsTopic(account, node);
    const payload: EventPayload = { type: "call", priority: 1 };

    await new Promise<void>((resolve, reject) => {
      verifier.subscribe(topic, { qos: 2 }, (err) => (err ? reject(err) : resolve()));
    });
    const received = waitForMessage(verifier, topic);

    await relayClient.publishEvent(account, node, payload);

    const { payload: receivedPayload, packet } = await received;
    expect(receivedPayload).toEqual(payload);
    expect(packet.qos).toBe(TopicQos.events.qos);
  });

  it("publishes commands at QoS 1 to @thrw/protocol's commandsTopic", async () => {
    const account = randomUUID();
    const node = randomUUID();
    const topic = commandsTopic(account, node);
    const payload: CommandPayload = { type: "claim" };

    await new Promise<void>((resolve, reject) => {
      verifier.subscribe(topic, { qos: 2 }, (err) => (err ? reject(err) : resolve()));
    });
    const received = waitForMessage(verifier, topic);

    await relayClient.publishCommand(account, node, payload);

    const { payload: receivedPayload, packet } = await received;
    // #210: the wire payload is the caller's, stamped with seq/epoch.
    expect(receivedPayload).toMatchObject(payload);
    expect(packet.qos).toBe(TopicQos.commands.qos);
  });

  // #210 / ADR 0018 decision 1. The relay emits these; enforcement is
  // the adapters' half and lands separately.
  it("stamps every command with a sequence number and an epoch", async () => {
    const account = randomUUID();
    const node = randomUUID();
    const topic = commandsTopic(account, node);

    await new Promise<void>((resolve, reject) => {
      verifier.subscribe(topic, { qos: 2 }, (err) => (err ? reject(err) : resolve()));
    });

    const first = waitForMessage(verifier, topic);
    await relayClient.publishCommand(account, node, { type: "claim" });
    const a = (await first).payload as { seq: number; epoch: string };

    const second = waitForMessage(verifier, topic);
    await relayClient.publishCommand(account, node, { type: "release" });
    const b = (await second).payload as { seq: number; epoch: string };

    expect(b.seq).toBeGreaterThan(a.seq);
    expect(a.epoch).toEqual(b.epoch);
    expect(a.epoch).toBeTruthy();
  });

  /**
   * Per (account, node), so one node's traffic cannot advance another's
   * counter. If it could, a quiet node's next command would arrive with
   * a number far above what it last saw - harmless on its own, but it
   * makes the sequence meaningless as evidence of ordering *for that
   * node*, which is the only thing it is for.
   */
  it("sequences each node independently", async () => {
    const account = randomUUID();
    const nodeA = randomUUID();
    const nodeB = randomUUID();
    const topicA = commandsTopic(account, nodeA);
    const topicB = commandsTopic(account, nodeB);

    for (const topic of [topicA, topicB]) {
      await new Promise<void>((resolve, reject) => {
        verifier.subscribe(topic, { qos: 2 }, (err) => (err ? reject(err) : resolve()));
      });
    }

    const firstA = waitForMessage(verifier, topicA);
    await relayClient.publishCommand(account, nodeA, { type: "claim" });
    expect(((await firstA).payload as { seq: number }).seq).toBe(1);

    const secondA = waitForMessage(verifier, topicA);
    await relayClient.publishCommand(account, nodeA, { type: "release" });
    expect(((await secondA).payload as { seq: number }).seq).toBe(2);

    // B has had nothing, so it starts at 1 rather than continuing A's run.
    const firstB = waitForMessage(verifier, topicB);
    await relayClient.publishCommand(account, nodeB, { type: "claim" });
    expect(((await firstB).payload as { seq: number }).seq).toBe(1);
  });

  it("publishes state retained to @thrw/protocol's stateTopic", async () => {
    const account = randomUUID();
    const topic = stateTopic(account);
    const payload: StatePayload = { holder: "node-a" };

    await relayClient.publishState(account, payload);

    // Prove retention, not just the live packet's flag: a client that
    // subscribes *after* the publish must still get it immediately.
    const lateSubscriber = await connectRawClient();
    try {
      const received = waitForMessage(lateSubscriber, topic);
      await new Promise<void>((resolve, reject) => {
        lateSubscriber.subscribe(topic, { qos: 1 }, (err) => (err ? reject(err) : resolve()));
      });

      const { payload: receivedPayload, packet } = await received;
      expect(receivedPayload).toEqual(payload);
      expect(packet.retain).toBe(TopicQos.state.retained);
    } finally {
      await new Promise<void>((resolve) => lateSubscriber.end(false, {}, () => resolve()));
    }
  });

  it("subscribes to heartbeat at QoS 0 and delivers published heartbeat messages", async () => {
    const account = randomUUID();
    const node = randomUUID();
    const topic = heartbeatTopic(account, node);

    const received: unknown[] = [];
    const granted = await relayClient.subscribeHeartbeat(account, node, (payload) => {
      received.push(payload);
    });

    expect(granted).toEqual([{ topic, qos: TopicQos.heartbeat.qos }]);

    const heartbeatPayload = { alive: true };
    await new Promise<void>((resolve, reject) => {
      verifier.publish(topic, JSON.stringify(heartbeatPayload), { qos: 0 }, (err) =>
        err ? reject(err) : resolve(),
      );
    });

    await expect
      .poll(() => received, { timeout: 2000 })
      .toEqual([heartbeatPayload]);
  });

  it("subscribes to every node's events topic for an account at QoS 1, and identifies which node each message came from", async () => {
    const account = randomUUID();
    const nodeA = randomUUID();
    const nodeB = randomUUID();
    const nodeC = randomUUID();

    const received: ReceivedNodeEvent[] = [];
    const granted = await relayClient.subscribeAllEvents(account, (payload, node) => {
      received.push({ payload, node });
    });

    expect(granted).toEqual([
      { topic: eventsTopic(account, "+"), qos: TopicQos.events.qos },
    ]);

    const payloadA: EventPayload = { type: "call", priority: 1 };
    const payloadB: EventPayload = { type: "voip", priority: 3 };
    const payloadC: EventPayload = { type: "media", priority: 4 };

    await Promise.all([
      new Promise<void>((resolve, reject) => {
        verifier.publish(eventsTopic(account, nodeA), JSON.stringify(payloadA), { qos: 1 }, (err) =>
          err ? reject(err) : resolve(),
        );
      }),
      new Promise<void>((resolve, reject) => {
        verifier.publish(eventsTopic(account, nodeB), JSON.stringify(payloadB), { qos: 1 }, (err) =>
          err ? reject(err) : resolve(),
        );
      }),
      new Promise<void>((resolve, reject) => {
        verifier.publish(eventsTopic(account, nodeC), JSON.stringify(payloadC), { qos: 1 }, (err) =>
          err ? reject(err) : resolve(),
        );
      }),
    ]);

    await expect
      .poll(() => received, { timeout: 2000 })
      .toEqual(
        expect.arrayContaining([
          { payload: payloadA, node: nodeA },
          { payload: payloadB, node: nodeB },
          { payload: payloadC, node: nodeC },
        ]),
      );
    expect(received).toHaveLength(3);
  });

  it("does not mistake a different account's events, or an unrelated topic, for this account's node events", async () => {
    const account = randomUUID();
    const otherAccount = randomUUID();
    const node = randomUUID();

    const received: ReceivedNodeEvent[] = [];
    await relayClient.subscribeAllEvents(account, (payload, emittedNode) => {
      received.push({ payload, node: emittedNode });
    });

    // A raw subscribe (not through subscribeAllEvents) so the verifier
    // itself, not relayClient, receives this - proving isolation doesn't
    // depend on nobody else being subscribed to the other account's topic.
    await new Promise<void>((resolve, reject) => {
      verifier.subscribe(eventsTopic(otherAccount, node), { qos: 1 }, (err) =>
        err ? reject(err) : resolve(),
      );
    });

    await relayClient.publishEvent(otherAccount, node, { type: "call", priority: 1 });
    await relayClient.publishState(account, { holder: node });
    const matchingPayload: EventPayload = { type: "call", priority: 1 };
    await relayClient.publishEvent(account, node, matchingPayload);

    await expect
      .poll(() => received, { timeout: 2000 })
      .toEqual([{ payload: matchingPayload, node }]);
  });
});
