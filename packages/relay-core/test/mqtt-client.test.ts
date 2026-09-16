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
    expect(receivedPayload).toEqual(payload);
    expect(packet.qos).toBe(TopicQos.commands.qos);
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
});
