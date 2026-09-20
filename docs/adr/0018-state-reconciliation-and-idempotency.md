# ADR 0018: State reconciliation and command idempotency

## Status
Accepted

> **Numbering note.** This ADR was drafted as "0016" before 0016
> (ambient focus tracking) and 0017 (AI scope) existed. It is 0018;
> cross-references below use the real ADR numbers. Nothing about the
> decision changed. The two ADRs drafted alongside it are 0019
> (switch-outcome confirmation) and 0020 (debouncing and offline
> behaviour).

## Context
The relay's record of "which device currently holds this resource" can
diverge from the actual local Bluetooth connection state — through a
missed OS callback, a race between a manual user action and an
in-flight relay command, or a partial failure during a switch. ADR
0010 established that local OS state wins over relay state when the
two conflict (the adapter is the source of truth for what is actually
connected; the relay for what should be), but that rule is currently
enforced reactively — only when a conflict happens to be detected —
rather than continuously and completely.

Additionally, claim/release commands have not been specified as
idempotent, which is a common source of subtle bugs when commands can
arrive out of order, be retried, or arrive more than once.

## Decision

1. **Idempotent commands.** Claim and release commands must be safe to
   receive multiple times, safe to receive when the resource is
   already in the target state, and safe to receive out of order — a
   stale claim arriving after a more recent release must not re-claim.
   Each command carries a monotonically increasing sequence number per
   (account, node, resource_type); an adapter discards any command
   whose sequence number is lower than the last one it has already
   processed for that resource.

2. **Periodic full reconciliation.** Independent of event-driven
   updates, each adapter reports its actual observed local connection
   state for every resource type it manages on a fixed interval
   (proposed: every 2 minutes), regardless of whether anything changed
   since the last report. The relay compares this against its own
   recorded state, corrects any drift, and logs the discrepancy to
   telemetry — a mismatch is a leading indicator of a bug, not routine
   noise (see Consequences).

3. **Local-state-first verification.** Before executing a claim or
   release, an adapter checks the actual current local Bluetooth
   connection state directly — not merely its own last-cached belief
   about that state — and skips execution if the resource is already
   in the target state, rather than blindly issuing a redundant
   disconnect/reconnect cycle.

## Rationale
State desync is the highest-leverage failure class to close, because
every other feature — priority rules, pre-claim (ADR 0011),
focus-tracking (ADR 0016) — is built on the assumption that "who holds
this resource" is accurately known. A system that is eventually
consistent but never fully verifies itself accumulates drift silently,
and that gets worse as more resource types and adapters are added (ADR
0015). Enforcing idempotency and periodic reconciliation now, while
there are two adapters and one resource type, is far cheaper than
retrofitting it once peripheral support and focus-tracking add more
moving parts.

Point 3 is the same principle as ADR 0010's manual-override detection,
applied *before* acting rather than after: the cached belief is
exactly what a missed OS callback corrupts, so a check that consults
the cache proves nothing.

## Relationship to the periodic re-registration work (#178)
Issue #178 independently added a `RegistrationPublisher` to both
adapters that re-announces a node every 2 minutes and carries the
node's currently-active triggers, explicitly as "a statement of
current state, not an event," so a relay that lost its in-memory
picture recovers without restarting each adapter by hand.

That is the same cadence and the same shape as decision 2 here.
Reconciliation should therefore **extend the existing periodic
registration message with observed per-resource connection state**,
not add a third periodic message alongside heartbeat and
registration. The distinction that matters is against the *heartbeat*,
which carries liveness only and runs at a much faster cadence; adding
a second full-state message on the same interval as registration would
be pure duplication.

## Sequencing against the ADR 0015 migration
ADR 0015's resource-type topic migration is accepted but **not yet
executed**: the running Mac/Pixel implementation is still on the
pre-0015 topic structure, and AGENTS.md records that adopting 0015 is
a flag day touching `packages/protocol`'s topic builders,
`packages/relay-core`, `services/relay-hosted` and both adapters
together, since the two structures are mutually incompatible.

The sequence number in decision 1 changes the same command payloads,
in the same packages, with the same all-at-once character. **These two
protocol changes should land as one flag day, not two** — sequencing
them separately means paying the reinstall-both-adapters,
redeploy-the-relay cost twice for changes that touch overlapping code.
If they are separated for review reasons, the 0015 migration goes
first: its topic change determines the shape of the command topic that
the sequence number then rides on, and reversing that order means
writing the sequencing code against a topic structure that is about to
be replaced.

This ADR does not depend on ADR 0014 (`claimMode`), which is still
**Proposed**; ADR 0020's relay-independent manual-override path does,
and is noted there.

## Consequences
- Every command message gains a sequence number field. This is a
  protocol change to `packages/protocol` and, per AGENTS.md's protocol
  invariants, is human-merge — it must land before further adapter
  work builds on the unsequenced shape, and per the sequencing note
  above should travel with the ADR 0015 migration.
- Each adapter needs a small persistent "last processed sequence
  number per resource" store that survives restart, so a command
  replay after an adapter crash doesn't double-execute.
- The registration payload gains observed per-resource connection
  state (see above); the relay gains the comparison and correction
  step on receipt.
- A reconciliation mismatch increments a metric feeding the telemetry
  pipeline of ADR 0019. Because a mismatch means some earlier event
  was lost or misapplied, treat a nonzero steady-state rate as a bug
  to investigate, not as the mechanism working as intended.
- The sequence-number rule and the local-state-first check must be
  implemented identically in both adapters; a per-adapter
  interpretation of "already in the target state" reintroduces exactly
  the divergence this ADR closes.
