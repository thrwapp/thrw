# ADR 0013: Connection state machine — cooldown is adapter-local, not a node-interface state

## Status
Accepted

## Context
Two governing documents describe the node interface's connection state
machine with different shapes, and neither has been implemented yet:

- `docs/spec/architecture.md`'s "Connection state machine" section (the
  section both ADR 0010 and ADR 0011 point to as canonical) specifies
  exactly four states with explicit transitions:

      idle -> pre-claim (speculative) -> claim (confirmed) -> active

  plus an escape path from `pre-claim` back to release if the predicted
  trigger doesn't materialize (e.g. a ringing call is declined).

- `AGENTS.md`'s "Protocol invariants" section describes this same frozen
  contract as five states: `idle / pre-claim / claim / active /
  cooldown`.

- ADR 0010's "Consequences" section separately describes a *different*,
  smaller local state machine — `idle -> claiming -> cooldown -> idle`
  — for an adapter's self-cooldown suppression window (ADR 0010,
  decision point 1): after thrw initiates a claim or release, it
  suppresses processing of its own resulting connection-state-changed
  events for ~3 seconds so it doesn't misread its own side effects as a
  new trigger.

This ambiguity was caught before either shape was implemented in code,
while scoping the first `packages/protocol` issue to build it — a good
time to resolve it, since getting the node interface's state enum wrong
would mean redoing a supposedly-frozen contract.

## Decision
The node interface's primary state enum has exactly the four states
architecture.md already specifies:

    idle -> pre-claim -> claim -> active

with `pre-claim -> idle` (release) as the escape path when a
speculative trigger doesn't confirm. This four-state shape is what
`packages/protocol` exports and what `packages/relay-core` and every
adapter reason about as "what is the current lifecycle stage of this
claim."

`cooldown`, as described in ADR 0010, is **not** a fifth value in that
enum. It's an adapter-local suppression *window*, not a lifecycle
stage the relay or other nodes need to observe: nothing in the MQTT
state topic payload (`{ holder: string | null }`, per the relay-core
issue) or the priority engine's decision logic needs to know a node is
"in cooldown" — cooldown only governs whether that adapter's own next
local OS event should be treated as a new trigger. It's local
bookkeeping around the transition into or out of `active`/`idle`, not
a state other nodes see or the protocol layer needs to serialize.

Concretely: `packages/protocol`'s `NodeInterface`/state types expose
the four-state enum. An adapter implementation is free (and expected,
per ADR 0010) to layer its own self-cooldown timer around calls to
`onClaim`/`onRelease` — that timer is adapter-internal implementation
detail, not part of the shared contract.

## Consequences
- `AGENTS.md`'s "Protocol invariants" section is corrected to describe
  four states, with a pointer to this ADR for the cooldown
  clarification, since it previously stated the contract imprecisely.
- `docs/spec/architecture.md`'s "Connection state machine" section
  gets a one-line pointer to this ADR, since it was already correct on
  its own but didn't address the apparent conflict with ADR 0010.
- The `packages/protocol` issue implementing this state machine can
  now cite a single, unambiguous source rather than two documents that
  read as inconsistent with each other.
- ADR 0010 itself is unchanged — its self-cooldown *behavior*
  requirement stands; only the modeling question (is it a shared
  protocol state, or adapter-local) is resolved here.
