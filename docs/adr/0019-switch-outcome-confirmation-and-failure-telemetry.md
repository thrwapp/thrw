# ADR 0019: Every switch has a confirmed outcome, not fire-and-forget

## Status
Accepted

> **Numbering note.** Drafted as "0017" before 0016 (ambient focus
> tracking) and 0017 (AI scope) existed; it is 0019. Its companions are
> ADR 0018 (state reconciliation and idempotency) and ADR 0020
> (debouncing and offline behaviour).

## Context
A switch that silently fails is worse than one that fails loudly,
because the user's and the system's mental model of "which device has
the resource" diverges from reality without anyone — the user, or
thrw's own telemetry — knowing it happened. The current implementation
issues claim/release commands with no defined mechanism for the
initiating side to learn, within a bounded time, whether the switch
actually completed.

## Decision
Every claim or release command resolves to exactly one of three
outcomes within a bounded timeout (proposed: 8 seconds — generous
against the 2-4s realistic switch time in docs/spec/architecture.md's
Latency section and the 3.5-4s p95 SLO of ADR 0007):

- **succeeded**
- **failed**, with a reason code — e.g. `bluetooth_unavailable`,
  `target_device_unreachable`, `superseded_by_newer_command`
- **timed_out**

The node executing the command reports the outcome back to the relay,
which makes it available to:

(a) **telemetry, unconditionally** — for every switch, not only
    failures, so success rate is a directly measured number rather
    than inferred from the absence of complaints; and

(b) **an in-app surface**, when a failure is user-visible and not
    silently recoverable — a switch that was immediately retried and
    succeeded is not worth surfacing; one that is genuinely stuck is.

Aggregate switch success rate, broken down by resource type (ADR
0015), platform pairing, and where available device model, becomes a
first-class metric in the telemetry pipeline — extending the
telemetry→wiki content pipeline of ADR 0012 and the latency-SLO
pipeline of ADR 0007, rather than being bolted onto the existing
latency metrics as an afterthought.

## Rationale
Without this, reliability is unmeasurable: there is no way to know
whether "rock solid" has been achieved, or regressed after a change,
except by guessing from the volume of complaints — which lags real
problems by however long users tolerate silent failure before
reporting it.

It is also the direct precondition for the compatibility matrix in
`docs/testing/compatibility-matrix.md`. Without per-outcome telemetry
broken down by device model and platform pairing, hardware-specific
failure patterns stay invisible until someone manually reproduces
them, and the matrix has nothing but manual test dates to record.

The 8-second bound is deliberately well above the expected 2-4s
mechanical cost. The timeout exists to guarantee *termination*, not to
police latency — latency already has its own SLO and alert threshold
in ADR 0007, and conflating the two would turn every slow-but-working
switch into a reported failure.

## Consequences
- The node interface's `claim()`/`release()` change from
  fire-and-forget to a confirmed-outcome pattern (callback, promise,
  or the platform's equivalent idiom: `async` throws on Swift,
  `suspend` on Kotlin). This is a change to the frozen node interface
  in `packages/protocol` — ADR + human merge, per AGENTS.md, not a
  routine agent PR.
- The timeout is enforced consistently across every adapter rather
  than left to per-adapter discretion, so outcome telemetry means the
  same thing in every row.
- `superseded_by_newer_command` is the reason code that ADR 0020's
  coalescing produces; per that ADR it is tracked separately from real
  failures, since a superseded command is the debouncer working
  correctly.
- A rising failure rate for a specific device-model combination is an
  actionable telemetry signal in the same way as ADR 0012's
  misconfiguration detection, and feeds the same troubleshooting-wiki
  auto-generation pipeline.
- `services/telemetry` is still a placeholder (see docs/roadmap.md), so
  the adapter- and relay-side outcome reporting can land first and
  emit into the existing logging path; the aggregation is only as real
  as that service is.
