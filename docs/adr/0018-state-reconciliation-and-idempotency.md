# ADR 0018: State reconciliation and command idempotency

## Status
Accepted — decisions 1-3 amended 2026-09-20, see *Revision* below;
decision 2's correction behaviour amended again 2026-09-25 (**bounded
re-assertion**), see the amendment at the end of this file.

> **Revision (2026-09-20).** Decisions 1, 2 and 3 were amended before
> any implementation began, on evidence from running the existing
> adapters against real hardware. Three changes: the reconciled signal
> is the **audio route**, not the Bluetooth link (multipoint headsets
> make the link reading report two simultaneous holders); commands
> carry a **relay epoch** (without it, sequence numbers deadlock the
> system after any relay restart); and reports are suppressed **while a
> transition is in flight** (a claim takes 3-5s to move the route, and
> a snapshot inside that window reads as false drift). A prerequisite
> on #182 was added. The shape of the ADR — periodic reconciliation
> riding the existing registration message, at the 2-minute cadence —
> is unchanged.

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

   **Commands also carry a relay epoch** — an identifier the relay
   generates once per process start. An adapter resets its high-water
   mark to zero whenever it sees an epoch different from the one it
   last recorded, and only then applies the lower-sequence rule.
   Without this the scheme deadlocks the entire system: the relay
   holds all its state in memory (that is the premise of #178), so a
   relay restart resets its counters to zero while adapters still hold
   persisted high-water marks, and *every* subsequent command is
   discarded as stale — permanently, curable only by clearing adapter
   state by hand. That is precisely the "restart every adapter
   manually" failure #178 exists to remove, and the relay restarts
   routinely (three times during one day of work on it). The epoch
   rides the registration message, which already carries node state
   for the same reason.

2. **Periodic full reconciliation.** Independent of event-driven
   updates, each adapter reports its actual observed local state for
   every resource type it manages on a fixed interval (proposed: every
   2 minutes), regardless of whether anything changed since the last
   report.

   **What is reported is the audio route, not the Bluetooth link.**
   This distinction is the whole correctness of the mechanism, so it is
   named here rather than left to the implementer:

   - **macOS** — is the headset the current default output device
     (`kAudioHardwarePropertyDefaultOutputDevice`)?
   - **Android** — is the headset the A2DP **active device**
     (`mActiveDevice`)? Explicitly *not*
     `BluetoothA2dp.getConnectionState() == STATE_CONNECTED`.

   The obvious reading — "am I connected to the headset" — is wrong,
   because multipoint headsets hold links to several hosts at once.
   Measured on the reference devices while the **phone** held the
   route: the Mac reported the AirPods as `Connected`, its default
   output device was `MacBook Air Speakers`, and the phone reported
   `mActiveDevice` for the same headset. Under the link reading both
   adapters report "I hold it", the relay sees two holders, and the
   drift is unresolvable — it would issue corrective commands forever.

   **A report is suppressed, or marked `transitioning`, while a claim
   or release is in flight on that resource.** A claim takes roughly
   3-5 seconds to actually move the audio route on the reference
   hardware; a snapshot taken inside that window reports "I do not hold
   this" while the relay correctly believes the node does, and the
   relay would "correct" a discrepancy that is simply the transition
   still happening. Drift is only actionable when no transition is
   outstanding. The relay compares this against its own
   recorded state, corrects any drift, and logs the discrepancy to
   telemetry — a mismatch is a leading indicator of a bug, not routine
   noise (see Consequences).

3. **Local-state-first verification.** Before executing a claim or
   release, an adapter checks its actual current local state directly —
   not merely its own last-cached belief about that state — and skips
   execution if the resource is already in the target state, rather
   than blindly issuing a redundant disconnect/reconnect cycle.

   "Already in the target state" means the **audio-route** definition
   in decision 2, and getting this wrong here is worse than in decision
   2. Under the Bluetooth-link reading, a Mac that holds a multipoint
   link but is *not* the audio route would consider itself already
   claimed and **silently skip a claim it genuinely needs to execute**
   — nothing logs it, nothing retries it, and the user simply does not
   get their audio.

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

## Prerequisite: adapter reconnection (#182)

Everything here is unreachable until adapters reconnect after losing
their MQTT connection, which today they never do. #182 is therefore a
**prerequisite of this ADR**, not an unrelated bug.

Observed: deploying the relay restarted the broker, which dropped every
client, and **neither adapter ever came back**. Both stayed running
with their foreground notification up, looking healthy, publishing
nothing — the failure is silent, because the crash-survivability work
(#161) faithfully keeps the adapter alive while its transport is dead.
A periodic reconciliation report from a node that cannot reach the
relay is not a weaker guarantee; it is no guarantee at all.

ADR 0020's decision 3 (reconnect jitter) already presumes this path
exists. It does not yet.

Re-registration should also fire **on reconnect**, not only on the
periodic timer: reconnect is precisely the moment the relay's picture
is most likely to be stale, and #178 made registration a safe,
repeatable statement of current state rather than an edge, which is
what makes that safe to do.

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

## Amendment (2026-09-25): reconciliation gives up, rather than repeating

Decision 2 says what to *report* and says nothing about how many times
the relay may act on a disagreement. The implementation re-asserted a
claim to the believed holder on **every** registration — every two
minutes, indefinitely. That is now bounded (#287).

### What happened

A user's headset was connected to a work laptop, which runs no adapter.
The relay's holder was the phone, whose registrations correctly reported
`observedRoutes: {"audio": false}`. The relay read that as drift, told
the phone to re-claim, and the phone took the headset off the laptop —
repeatedly, for half an hour, while the user was on a call.

Every component behaved as specified. The reading was the audio route,
not the Bluetooth link, exactly as this decision requires. The report
was accurate. The correction was the one described. The outcome was that
thrw repeatedly took a headset away from a live call.

### What the ADR assumed

That a holder without the route is a **fault to repair** — a node that
restarted and lost its connection. That is one cause. The other is a
user who moved their headset somewhere thrw cannot see, which for a
locked-down work machine is not an edge case but the normal state of
affairs.

The two are indistinguishable from the relay. Decision 2 did not
consider the second, so it prescribed repair unconditionally.

This ADR already warned about the failure *shape*: under the Bluetooth-
link reading, it says, "the drift is unresolvable — it would issue
corrective commands forever". That hazard was real and the guard against
it was correct; it simply had a second entrance that was not guarded.

### The amendment

**A correction is a bounded attempt, not a standing intention.**

1. A node reporting that it **already holds the route** is not
   corrected. There is nothing to repair, and the command is not free:
   the adapter's handover audio gate (ADR 0022) runs around every
   command, so a claim that changes nothing still interrupts playback
   (#284).

2. At most **two** corrections per holder tenure, where a tenure begins
   at a holder *change*. Two because the fault this repairs — a node
   that restarted holding nothing — is fixed by the first attempt, with
   one spare for a claim that raced a starting adapter.

3. The budget **must not** reset on the node reporting the route as
   held. That is the trap: each correction *succeeds*, so a budget keyed
   on failure never depletes and the loop is unbounded. Only a genuine
   arbitration decision earns a fresh budget.

4. Exhaustion is logged (`reassert_exhausted`), because a relay that has
   given up is a state someone will need to see.

### What this costs

A node that genuinely loses its route more than twice within one holder
tenure stops being repaired until arbitration moves. That is a real
regression in the case decision 2 was written for, accepted because the
alternative — an unbounded loop — is worse in the case decision 2 was
not written for, and the failure it produces is the most user-hostile
this project has shipped.

The narrower fix would be to teach the relay that a device outside thrw
holds the resource. Nothing on the wire carries that today, and
inventing it here would be designing a feature inside an amendment.
Raised as #287, not decided here.
