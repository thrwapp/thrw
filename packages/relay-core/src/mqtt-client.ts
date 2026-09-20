import { randomUUID } from "node:crypto";
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

/**
 * What actually goes on the wire (#210, ADR 0018 decision 1).
 *
 * Callers pass a plain ``CommandPayload``; ``publishCommand`` stamps
 * these. That is deliberate - there are three call sites and counting,
 * and a sequence number that any of them can forget to set is worse than
 * none, because the adapter would discard as stale whatever arrived
 * without one.
 */
export interface SequencedCommandPayload extends CommandPayload {
  /**
   * Monotonic per (account, node). Lets an adapter discard a command
   * that arrives after a newer one - a stale claim overtaking a release
   * must not re-claim.
   *
   * ADR 0018 specifies this per (account, node, resource_type). There is
   * exactly one resource type today, so the two are identical; it gains
   * the resource segment with #171.
   */
  seq: number;
  /**
   * Identifies this relay *process*. Changes on every restart.
   *
   * Without it the scheme deadlocks the system. The relay holds all its
   * state in memory (the premise of #178), so a restart resets these
   * counters to zero while adapters still hold persisted high-water
   * marks - and every subsequent command is then discarded as stale,
   * permanently, until adapter state is cleared by hand. That is exactly
   * the "restart every adapter manually" failure #178 removed. An
   * adapter resets its high-water mark whenever the epoch changes.
   */
  epoch: string;
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

// Improves on HeartbeatListener's (payload, topic) shape rather than
// repeating it (#97 acceptance criterion 2 explicitly invites either):
// subscribeHeartbeat's topic is already known to the caller (fixed per
// account/node at subscribe time), so handing it back is mostly a
// formality. Here the node is exactly the one piece of information the
// wildcard subscription *doesn't* statically know - every listener needs
// it, and re-deriving it from a raw topic string is the same parsing
// logic every caller would otherwise have to duplicate. So this hands
// back the already-parsed node directly instead of the topic.
export type NodeEventListener = (payload: unknown, node: string) => void;

// Thin wrapper around the `mqtt` npm package (see PR description for why
// this dependency): only exists to guarantee every publish/subscribe call
// goes through packages/protocol's topic builders and TopicQos constants
// rather than a hand-rolled topic string or QoS number. No connection
// state machine, no device registry - both out of scope for this issue.
export class RelayMqttClient {
  /**
   * This relay process's epoch (#210). Generated once, here, because
   * "once per process" is exactly what it has to mean: it is the signal
   * that the in-memory sequence counters below have restarted.
   *
   * A reconnect does not change it, and must not - the counters survive
   * a reconnect, so telling adapters to reset would be a lie. Only a new
   * process is a new epoch.
   */
  private readonly epoch = randomUUID();

  /** (account, node) -> last issued sequence number. */
  private readonly sequences = new Map<string, number>();

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
    const sequenced: SequencedCommandPayload = {
      ...payload,
      seq: this.nextSequence(account, node),
      epoch: this.epoch,
    };
    return this.publish(commandsTopic(account, node), sequenced, {
      qos: TopicQos.commands.qos,
    });
  }

  /**
   * Next sequence number for this node (#210).
   *
   * In-memory, and correct that way: durability is what the epoch
   * provides instead. Persisting these would mean giving the relay
   * durable state it has nowhere to put, to solve a problem a single
   * random string already solves.
   */
  private nextSequence(account: string, node: string): number {
    // "\u0000" rather than "/" or ":" - account ids and node ids are
    // user- and platform-supplied, and a separator either could contain
    // would let two different pairs collide on one counter.
    const key = `${account}\u0000${node}`;
    const next = (this.sequences.get(key) ?? 0) + 1;
    this.sequences.set(key, next);
    return next;
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

  // Subscribes to *every* registered node's events topic for an account,
  // via MQTT's `+` single-level wildcard on @thrw/protocol's own
  // eventsTopic builder (never a hand-rolled topic string - same
  // discipline every other method here follows). Transport only: no
  // PriorityEngine/DeviceRegistry wiring, no connection state machine -
  // out of scope for this issue (#97).
  subscribeAllEvents(
    account: string,
    onMessage: NodeEventListener,
  ): Promise<ISubscriptionGrant[]> {
    const topic = eventsTopic(account, "+");

    this.client.on("message", (messageTopic, message) => {
      const node = nodeFromEventsTopic(account, messageTopic);
      if (node === null) return;
      onMessage(parsePayload(message), node);
    });

    return new Promise((resolve, reject) => {
      this.client.subscribe(topic, { qos: TopicQos.events.qos }, (err, granted) => {
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

// Reverses @thrw/protocol's eventsTopic(account, node) - splitting on "/"
// rather than a regex (no escaping to get wrong for special characters in
// `account`). Returns null for anything that isn't shaped exactly like
// this account's own events topic, so a message on some other topic this
// same MQTT connection happens to also be subscribed to (e.g. via a
// separate subscribeHeartbeat call sharing the same underlying "message"
// event) is silently ignored rather than misreported as a node id.
function nodeFromEventsTopic(account: string, topic: string): string | null {
  const segments = topic.split("/");
  const [prefix, topicAccount, nodesSegment, node, eventsSegment] = segments;
  if (
    segments.length === 5 &&
    prefix === "thrw" &&
    topicAccount === account &&
    nodesSegment === "nodes" &&
    eventsSegment === "events"
  ) {
    return node;
  }
  return null;
}
