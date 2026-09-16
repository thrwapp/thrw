# HANDOFF: Protocol topic builders and shared types (#29)

## What was done

- Added MQTT topic-builder functions to `packages/protocol/src/index.ts`:
  `eventsTopic`, `commandsTopic`, `stateTopic`, `heartbeatTopic`, matching
  the literal shapes in `docs/spec/architecture.md`'s "MQTT topic design"
  section exactly (packages/protocol/src/index.ts:5-19).
- Added a `TopicQos` constant object recording each topic's QoS/retained
  behavior per that same section: events/commands QoS 1, state retained,
  heartbeat QoS 0 (packages/protocol/src/index.ts:21-26).
- Added `EventKind` (packages/protocol/src/index.ts:29), `Priority`
  (packages/protocol/src/index.ts:31), and `PRIORITY_ORDER`
  (packages/protocol/src/index.ts:35-40) — the rank order
  `["call", "manual_claim", "voip", "media"]` matches architecture.md's
  "Priority rules" section (call always wins).
- Added `NodeManifest` (packages/protocol/src/index.ts:43-49) with exactly
  the fields specified in the issue.
- Added `NodeInterface` (packages/protocol/src/index.ts:53-58) as
  method-signature-only declarations (`register`, `emitEvent`, `onClaim`,
  `onRelease`), matching the four methods named in architecture.md's
  "System components" section. No implementation, no MQTT client, and no
  connection state machine — those remain out of scope per the issue and
  per ADR 0010/0011's frozen-contract status.
- Added tests in `packages/protocol/test/index.test.ts` covering: each
  topic builder against the literal example strings from architecture.md,
  every `TopicQos` value, and that `PRIORITY_ORDER` has exactly the 4
  `EventKind` values in the documented order.
- Did not touch `packages/relay-core/**` or add any state machine code,
  per the issue's "paths the agent must not touch" section.

## Verification

- `pnpm turbo test --filter=@thrw/protocol` — passes, 1 test file / 10
  tests.
- `pnpm turbo typecheck --filter=@thrw/protocol` — passes with no errors.

## Uncertain / worth a human glance

- `Priority` is exported as a plain `number` type alias, since the issue
  says "a `Priority` numeric type" but doesn't specify an enum or branded
  type. `PRIORITY_ORDER` is an ordered array of `EventKind`, not a
  `Record<EventKind, Priority>` mapping — callers derive a numeric rank by
  indexing into `PRIORITY_ORDER` (lower index = higher priority) rather
  than this package pre-computing one. Both were straightforward readings
  of the issue text but weren't fully pinned down there, so worth
  confirming that's the intended shape before relay-core/adapters start
  consuming it.
