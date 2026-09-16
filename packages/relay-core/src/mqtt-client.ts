import mqtt, {
  type IClientOptions,
  type ISubscriptionGrant,
  type MqttClient,
} from "mqtt";
import {
  commandsTopic,
  eventsTopic,
  heartbeatTopic,
  stateTopic,
  TopicQos,
  type EventKind,
  type Priority,
} from "@thrw/protocol";

// New design decisions for this issue (#61) - architecture.md and
// packages/protocol define the topics, not the message bodies on them.

export interface EventPayload {
  type: EventKind;
  priority: Priority;
}

export interface CommandPayload {
  type: "claim" | "release";
}

export interface StatePayload {
  holder: string | null;
}

const DEFAULT_BROKER_URL = "mqtt://localhost:1883";

// CI (.github/workflows/ci.yml) starts a real Mosquitto broker and sets this
// for this package's tests (acceptance criterion 5) - fall back to the same
// address for local dev so `pnpm test` works without extra setup.
export function defaultMqttBrokerUrl(): string {
  return process.env.MQTT_BROKER_URL ?? DEFAULT_BROKER_URL;
}

export type HeartbeatListener = (payload: unknown, topic: string) => void;

// Thin wrapper around the `mqtt` npm package (see PR description for why
// this dependency): only exists to guarantee every publish/subscribe call
// goes through packages/protocol's topic builders and TopicQos constants
// rather than a hand-rolled topic string or QoS number. No connection
// state machine, no device registry - both out of scope for this issue.
export class RelayMqttClient {
  private constructor(private readonly client: MqttClient) {}

  static connect(
    url: string = defaultMqttBrokerUrl(),
    options?: IClientOptions,
  ): Promise<RelayMqttClient> {
    return new Promise((resolve, reject) => {
      const client = mqtt.connect(url, options);

      const onConnect = () => {
        client.removeListener("error", onError);
        resolve(new RelayMqttClient(client));
      };
      const onError = (err: Error) => {
        client.removeListener("connect", onConnect);
        client.end(true);
        reject(err);
      };

      client.once("connect", onConnect);
      client.once("error", onError);
    });
  }

  end(): Promise<void> {
    return new Promise((resolve) => {
      this.client.end(false, {}, () => resolve());
    });
  }

  publishEvent(account: string, node: string, payload: EventPayload): Promise<void> {
    return this.publish(eventsTopic(account, node), payload, {
      qos: TopicQos.events.qos,
    });
  }

  publishCommand(account: string, node: string, payload: CommandPayload): Promise<void> {
    return this.publish(commandsTopic(account, node), payload, {
      qos: TopicQos.commands.qos,
    });
  }

  publishState(account: string, payload: StatePayload): Promise<void> {
    return this.publish(stateTopic(account), payload, {
      retain: TopicQos.state.retained,
    });
  }

  // Resolves with the broker's granted subscription (topic + QoS actually
  // acknowledged), so callers - and this package's own tests - can confirm
  // the request went out at TopicQos.heartbeat.qos rather than assuming it.
  subscribeHeartbeat(
    account: string,
    node: string,
    onMessage: HeartbeatListener,
  ): Promise<ISubscriptionGrant[]> {
    const topic = heartbeatTopic(account, node);

    this.client.on("message", (messageTopic, message) => {
      if (messageTopic !== topic) return;
      onMessage(parsePayload(message), messageTopic);
    });

    return new Promise((resolve, reject) => {
      this.client.subscribe(topic, { qos: TopicQos.heartbeat.qos }, (err, granted) => {
        if (err) {
          reject(err);
          return;
        }
        resolve(granted ?? []);
      });
    });
  }

  private publish(
    topic: string,
    payload: unknown,
    opts: { qos?: 0 | 1 | 2; retain?: boolean },
  ): Promise<void> {
    return new Promise((resolve, reject) => {
      this.client.publish(topic, JSON.stringify(payload), opts, (err) => {
        if (err) {
          reject(err);
          return;
        }
        resolve();
      });
    });
  }
}

function parsePayload(message: Buffer): unknown {
  try {
    return JSON.parse(message.toString());
  } catch {
    return message;
  }
}
