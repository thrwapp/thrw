# HANDOFF: #61 packages/relay-core MQTT client wrapper

## What was done

Added an MQTT transport-layer wrapper to `packages/relay-core`, split out
of #40 per this issue. No connection state machine, no device registry —
transport only, as instructed.

- `packages/relay-core/src/mqtt-client.ts`: `RelayMqttClient` class wrapping
  the `mqtt` npm package (v5.16.0). Exposes:
  - `RelayMqttClient.connect(url?, options?)` — static factory, resolves once
    the underlying client emits `connect`.
  - `publishEvent(account, node, payload: EventPayload)` — publishes to
    `eventsTopic(account, node)` at `TopicQos.events.qos` (1).
  - `publishCommand(account, node, payload: CommandPayload)` — publishes to
    `commandsTopic(account, node)` at `TopicQos.commands.qos` (1).
  - `publishState(account, payload: StatePayload)` — publishes to
    `stateTopic(account)` with `retain: TopicQos.state.retained` (true).
  - `subscribeHeartbeat(account, node, onMessage)` — subscribes to
    `heartbeatTopic(account, node)` at `TopicQos.heartbeat.qos` (0), resolves
    with the broker's granted subscription so callers/tests can confirm the
    QoS actually acknowledged.
  - `defaultMqttBrokerUrl()` — reads `MQTT_BROKER_URL`, falls back to
    `mqtt://localhost:1883` (same address CI's Mosquitto container listens
    on) for local dev.
- All topic strings and QoS/retain values come from `@thrw/protocol`
  (`eventsTopic`, `commandsTopic`, `stateTopic`, `heartbeatTopic`,
  `TopicQos`) — none are hardcoded in `relay-core`. `packages/protocol` was
  not modified.
- Payload shapes are defined per the issue's acceptance criteria 3, as new
  design decisions (not frozen contracts): `EventPayload { type: EventKind;
  priority: Priority }`, `CommandPayload { type: "claim" | "release" }`,
  `StatePayload { holder: string | null }`.
- Re-exported from `packages/relay-core/src/index.ts` alongside the
  existing `PriorityEngine`/`ConnectionState`-adjacent exports already in
  that file (untouched).
- Tests: `packages/relay-core/test/mqtt-client.test.ts`, four integration
  tests against a **real broker**, no mock MQTT library. Each test uses a
  raw `mqtt` client as an independent verifier (subscribing/publishing
  outside the wrapper) so the assertions don't just check that
  `RelayMqttClient` calls itself consistently:
  - events published at QoS 1 (asserted via the verifier's received
    `packet.qos`).
  - commands published at QoS 1 (same approach).
  - state published retained — proven by subscribing a *new* client after
    the publish and confirming it still receives the message immediately
    with `packet.retain === true`, not just checking the live packet flag.
  - heartbeat subscribed at QoS 0 — asserted on the `granted` subscription
    array `subscribeHeartbeat` resolves with, then confirms a heartbeat
    payload published by the verifier is delivered to the wrapper's
    callback.
  - Tests read `MQTT_BROKER_URL` (via `defaultMqttBrokerUrl()`), matching
    what CI sets.

## Dependency justification (AGENTS.md: no new dependency without justification)

- `mqtt` (`^5.16.0`, installed via `pnpm add mqtt` in
  `packages/relay-core`): the standard/most widely used Node.js MQTT client,
  explicitly named in the issue's acceptance criteria. It ships its own
  TypeScript type definitions (`build/index.d.ts`, verified in the installed
  package's `package.json`), so no separate `@types/mqtt` package was
  needed or added. No other packages were added — `pnpm-lock.yaml`'s diff
  is `mqtt` plus its own transitive dependency tree only.

## Verification actually performed

- `pnpm turbo test --filter=@thrw/relay-core` (the exact command in the
  issue) — ran and passed: 16 tests (12 pre-existing `PriorityEngine`
  tests, unchanged, + 4 new MQTT integration tests), against a real MQTT
  broker (`aedes-cli`, run locally via `pnpm dlx aedes-cli start --port
  1883`, standing in for the Mosquitto container CI starts — same MQTT
  protocol, same test code path, no mocking library involved either way).
- `pnpm turbo build typecheck --filter=@thrw/relay-core` — both pass with
  no errors, `strict` mode.
- Did **not** run the full monorepo test suite (`pnpm turbo test` with no
  filter) — out of scope for this change and `packages/protocol` (the only
  other package touched indirectly, via its build output) was not
  modified.

## Uncertain / worth a second look

- Local verification used `aedes-cli` (a real, spec-compliant MQTT broker,
  just not Mosquitto) because Docker is unavailable in this sandbox — CI's
  actual Mosquitto container was not exercised by me directly. The code
  only depends on standard MQTT semantics (QoS levels, retain flag,
  SUBACK-granted QoS), which both brokers implement, so I expect CI's
  Mosquitto run to pass identically, but that's an expectation, not a
  claim of having observed it.
- `subscribeHeartbeat`'s `onMessage` callback delivers `unknown` (best-effort
  `JSON.parse`, falling back to the raw `Buffer` if parsing fails) rather
  than a typed heartbeat payload — the issue's acceptance criteria define
  payload shapes for event/command/state but not heartbeat, and
  architecture.md doesn't specify one either, so I didn't invent one.
- `RelayMqttClient`'s `message` listener in `subscribeHeartbeat` is
  currently registered once per call and filters by topic; calling it
  multiple times on the same client attaches multiple listeners. Not an
  issue for this PR's scope (a single heartbeat subscription per client is
  the only case exercised), flagging in case a future caller subscribes to
  multiple heartbeat topics on one client.
