# ADR 0020: Command debouncing at the relay, and defined offline behaviour

## Status
Accepted

> **Numbering note.** Drafted as "0018" before 0016 (ambient focus
> tracking) and 0017 (AI scope) existed; it is 0020. Its companions are
> ADR 0018 (state reconciliation and idempotency) and ADR 0019
> (switch-outcome confirmation).

## Context
Two related failure modes, neither currently handled:

1. Rapid successive trigger events — a call ending and a new call
   immediately ringing, or a declined call followed quickly by a retry
   — can produce a burst of claim/release commands faster than the
   mechanical switch time (2-4s, per docs/spec/architecture.md) can
   absorb. Even with ADR 0018's idempotency and sequence numbers,
   which make a burst *safe*, the commands can still execute after
   they have stopped being relevant.

2. "Relay unreachable" — network partition or relay outage — has no
   explicitly defined adapter-side behaviour. Whether an adapter
   should fail safe (do nothing, stay on the current device) or fail
   toward a local heuristic (make a best-effort decision without relay
   input) has been left implicit rather than decided.

## Decision

1. **Command debouncing / coalescing.** The relay coalesces
   claim/release commands for the same (account, node, resource_type)
   arriving within the cooldown window of ADR 0010 (~3 seconds) into a
   single effective command reflecting only the final intended state.
   Superseded intermediate commands are dropped, not queued for later
   execution, and are logged as superseded — not as failures — in
   telemetry (ADR 0019's `superseded_by_newer_command`).

2. **Defined offline behaviour: fail safe.** When an adapter cannot
   reach the relay it makes no local switching decisions of its own
   and maintains its last known state until connectivity returns. The
   one exception is a manual claim initiated directly on the device —
   a keyboard shortcut or equivalent local trigger, not a
   relay-mediated one — which is always honoured locally regardless of
   relay reachability, consistent with ADR 0010's principle that
   direct user action always wins, and with ADR 0014's `claimMode`.

3. **Reconnect jitter.** On regaining connectivity after a partition,
   an adapter applies randomised jitter (proposed: 0-2 seconds) before
   sending its reconciliation report (ADR 0018), so that several nodes
   reconnecting after a shared event — a relay restart, say — do not
   all reconcile at once and produce a burst of corrective commands.

## Rationale
Debouncing stops thrw fighting itself under rapid trigger sequences,
extending ADR 0010's per-adapter cooldown into an explicit relay-side
coalescing rule rather than relying solely on each adapter's local
suppression window. The relay is the right place for it: it is the
only component that sees all commands for a resource, and per ADR 0013
cooldown is deliberately adapter-local and invisible to the relay, so
the relay cannot infer the same suppression from node state.

Fail-safe-by-default is the conservative, predictable choice. A system
that tries to be clever without relay input under partition is far
harder to reason about and debug than one that holds its last known
state, and the direct local override is the escape hatch that makes
holding acceptable.

Jitter matters more than it looks: the partition events most likely to
hit multiple nodes at once (a relay restart, a home network blip) are
precisely the ones that would synchronise every node's reconnect.

## Consequences
- The relay's command dispatch gains a coalescing buffer keyed on
  (account, node, resource_type), using the existing cooldown window
  as its coalescing period. The buffer adds up to ~3s of latency to a
  superseded command's replacement only in the burst case — a steady
  single trigger must dispatch immediately, or every ordinary switch
  pays the debounce.
- ADR 0014 (`claimMode` in the node manifest) is still **Proposed**,
  and decision 2's local manual claim is the behaviour it describes
  for platforms without programmatic Bluetooth control. Resolving 0014
  — accepted or rejected — determines whether "manual claim" is one
  contract across adapters or a per-platform capability, so it should
  be settled before the offline override path is implemented.
- Each adapter needs a locally-triggerable manual override path with
  no dependency on relay connectivity at all. This should largely
  exist already as manual claim, but must be explicitly verified with
  the relay *entirely unreachable*, not merely slow — a path that
  blocks on an MQTT publish is not offline-capable, however short its
  timeout.
- Superseded-command telemetry is tracked separately from failure
  telemetry (ADR 0019): a high superseded rate indicates rapid-trigger
  scenarios worth understanding, not necessarily a bug.
- Jitter applies to the reconciliation report only, not to the manual
  override path, which stays immediate.
