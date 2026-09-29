import type { ResourceType } from "@thrw/protocol";
import type {
  CommandPayload,
  HeartbeatListener,
  NodeEventListener,
  StatePayload,
} from "./mqtt-client.js";

/**
 * The relay's whole view of its transport (#320).
 *
 * Exactly the four methods `RelayService` calls on a client — no more, so
 * that a stand-in has a small, honest surface to implement.
 * {@link RelayMqttClient} implements this over a real broker;
 * `@thrw/testkit`'s `InMemoryBus` implements it over a virtual clock with
 * no broker at all, which is what lets a scenario run in milliseconds and
 * deterministically (`docs/spec/testing-framework.md`).
 *
 * `RelayMqttClient`'s other methods (`connect`, `end`, `publishEvent`) are
 * deliberately absent: `connect` and `end` are lifecycle the *caller*
 * owns — `RelayService` explicitly never closes its client — and
 * `publishEvent` is something a **node** does, not the relay. A test that
 * needs to simulate a node publishing uses the bus's own node-facing
 * methods rather than this interface.
 *
 * ## Why the subscribe methods return `Promise<unknown>`
 *
 * `RelayMqttClient` returns `Promise<ISubscriptionGrant[]>` from both, so
 * its own tests can confirm the broker really granted the QoS asked for
 * rather than assuming it. That is an `mqtt`-package type, and neither
 * `RelayService` nor a broker-less bus has any use for it — `RelayService`
 * discards both return values.
 *
 * `Promise<unknown>` is what accommodates that without distorting either
 * side: `Promise<ISubscriptionGrant[]>` and `Promise<void>` both satisfy
 * it, and no `mqtt` type reaches `@thrw/testkit`. `Promise<void>` would
 * **not** work — `Promise<T>` is covariant in `T`, so
 * `Promise<ISubscriptionGrant[]>` is not assignable to it, and adopting it
 * would have forced `RelayMqttClient` to throw away a return value its
 * tests rely on.
 */
export interface RelayTransport {
  /**
   * One wildcard subscription per account, covering every node and every
   * resource type. The listener receives the already-parsed node id and
   * resource, since re-deriving them from a raw topic string is parsing
   * every caller would otherwise duplicate.
   */
  subscribeAllEvents(account: string, onMessage: NodeEventListener): Promise<unknown>;

  subscribeHeartbeat(
    account: string,
    node: string,
    onMessage: HeartbeatListener,
  ): Promise<unknown>;

  /**
   * Takes a **plain** payload and stamps ADR 0018's epoch and sequence
   * number itself, rather than trusting callers to. Both implementations
   * do that through the same {@link CommandSequencer}, so a simulated
   * command is numbered exactly as a real one is.
   */
  publishCommand(
    account: string,
    node: string,
    resource: ResourceType,
    payload: CommandPayload,
  ): Promise<void>;

  /** Retained, per `TopicQos.state` — the relay's authoritative answer to "who holds this resource". */
  publishState(account: string, resource: ResourceType, payload: StatePayload): Promise<void>;
}
