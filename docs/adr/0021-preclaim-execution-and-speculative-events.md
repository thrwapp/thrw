# ADR 0021: Executing pre-claim — speculative events, and what earns one

## Status
Proposed

## Context
ADR 0011 introduced pre-claim as a concept and ADR 0013 fixed it as one
of the four node-interface states. Neither was ever executed.

What exists today is a type and a transition table:
`ConnectionState = "idle" | "pre-claim" | "claim" | "active"` with
`pre-claim -> claim` and `pre-claim -> idle` legal
(`packages/protocol/src/index.ts:103-113`). What does not exist is any
way to *enter* that state. `NodeInterface` has `onClaim()` and
`onRelease()` and nothing else, no adapter implements a pre-claim, and
no event can request one. `CallTriggerMonitor` deliberately drops the
`RINGING` signal that ADR 0011 names as the one trusted pre-claim
trigger, and says why in its own kdoc: pre-claim is a frozen contract,
so emitting a full `call` event on ringing would do that state
machine's job badly rather than doing it early.

So the state is unreachable, and the highest-value early signal on the
platform is detected, documented, and thrown away.

The immediate prompt is a request for something ADR 0011 did not
authorise: pre-claiming when the user **opens a media app** (Spotify),
to hide the switch latency observed on the reference hardware. That
request is reasonable and the latency is real — ADR 0020's amendment
measured it, and the claim side is the bad one: after a claim the
audio route takes **3-5 seconds to settle**, while after a release it
leaves within 3. But it needs deciding rather than implementing,
because the mechanism it depends on does not exist, and because ADR
0011 explicitly deferred app-launch signals until there was per-user
data to calibrate them against.

Three facts constrain what can honestly be decided here.

**Pre-claim hides latency; it does not reduce it.** ADR 0011 puts the
floor at 2-4 seconds of Bluetooth establishment that "no software
architecture change can reduce." Starting earlier is the entire
mechanism. That is worth doing, but it means the value of a pre-claim
is exactly the lead time of its signal, and nothing else.

**"Opened Spotify" is a much weaker signal than "phone is ringing."** A
ringing call has a 1-3 second lead and confirms most of the time. An
opened media app has an unbounded lead — seconds, minutes, or never —
and no established confirmation rate at all. ADR 0011's concern is
precisely this: a speculative claim that does not confirm produces
"visible flicker," and here the flicker is a real audible switch, away
and back, for a user who was only browsing.

**Media is the second-lowest priority rule.** The stack is
call > manual claim > VoIP > media > last-claimed
(`docs/spec/architecture.md`). A speculative claim at rule 4 is the one
most likely to start a Bluetooth reconnect and then lose the resource
to a confirmed higher-priority trigger mid-flight.

## Decision

### 1. The node interface gains a pre-claim operation

`NodeInterface` gains `onPreClaim()` alongside `onClaim()` and
`onRelease()`. It performs the full mechanical work — disconnect from
the current host, connect here — and is the only operation that does so
speculatively.

`onClaim()` **while already in `pre-claim` for the same resource is a
promotion, not a repeat**: the state advances `pre-claim -> claim` and
no Bluetooth work is re-run. This is the whole point of the state. If
confirmation re-ran the mechanical work, pre-claim would cost latency
rather than save it.

`onRelease()` from `pre-claim` is the escape path (`pre-claim -> idle`),
and returns the resource to the holder the pre-claim displaced. The
relay is therefore responsible for remembering that displaced holder
for the lifetime of the pre-claim, as part of the state it already
reconciles under ADR 0018.

This is a change to the frozen node interface — ADR plus human merge
per AGENTS.md, never a routine agent PR. It composes with, and does not
replace, ADR 0019's confirmed-outcome change to the same interface.

### 2. Speculation is a property of an event, not a new event kind

`EventPayload` gains `speculative: boolean` (default `false`). A
speculative event says "this trigger looks like it is *about* to
happen here", using the same `EventKind` vocabulary as the confirmed
one.

A boolean, not a confidence score: a score is only meaningful once
something calibrates it, which is ADR 0017's local-classification work
and does not exist. A boolean can be widened to a score later without
changing the event vocabulary; a score invented now would be a
fabricated number in a payload other components would start trusting.

A flag rather than new kinds (`media_intent`, `call_ringing`, …)
because every trigger has a speculative form, and a parallel vocabulary
would double the event space and force every consumer to learn which
kinds pair with which.

### 3. Speculative events rank below *every* confirmed event

The priority engine evaluates a speculative event of any kind strictly
below every confirmed event, regardless of the two events' own
priorities. In effect they contend only with rule 5 (last-claimed) and
with each other.

Concretely: speculative `media` can take a resource that is merely
sitting where it was last left. It can never take one from a confirmed
call, manual claim, VoIP session or media playback — and a confirmed
event of *any* priority arriving mid-pre-claim supersedes it
immediately.

This is the rule that makes a rule-4 speculative trigger safe, and it
is deliberately blunter than ranking speculation within the existing
stack. A speculative signal is a guess about the near future; a
confirmed one is a fact about the present, and a fact should not lose
to a guess.

### 4. A pre-claim is bounded, and reverting is not a failure

A pre-claim that is not confirmed within a bounded window is reverted
by the relay. The window is **per signal type, derived from that
signal's measured lead time**, not a single global constant:
`RINGING` needs only seconds, an opened app would need far longer, and
one number cannot serve both.

Reverting is reported through ADR 0019's outcome channel as
`reverted_unconfirmed`, which is **not** a failure — the same treatment
ADR 0020 gives `superseded_by_newer_command`. ADR 0011 is explicit that
an unconfirmed pre-claim is the mechanism working as designed. Counting
reverts as failures would make the switch-success metric ADR 0019
exists to produce meaningless the day pre-claim ships.

Revert rate per signal type is itself a first-class telemetry metric.
It is the number that decides whether a signal deserves to keep its
pre-claim privilege — see decision 6.

### 5. Ringing is enabled. Opening a media app is not, yet

`RINGING` becomes a speculative `call` event, and
`CallTriggerMonitor` stops dropping it. This is the signal ADR 0011
already trusts, the platform already detects it, and the code that
discards it already documents this ADR as the reason it must.

**Opening a media app does not become a pre-claim trigger on adoption
of this ADR.** It is enabled when, and only when, it passes the gate in
decision 6. Two things are true at once and both belong in the record:
the request is sound, and the evidence to grant it does not exist yet.

### 6. The gate an app-open signal must pass

A signal graduates from telemetry-only to pre-claim-eligible when, for
a given user and signal type:

- at least **50 observations** have been logged, and
- the **confirmation rate is at or above 70%** — the predicted trigger
  actually materialised on that node — and
- the **measured lead time** between signal and confirmation has a
  median of at least 2 seconds, since a signal that confirms instantly
  saves nothing and still risks a revert.

These thresholds are a starting proposal, not a derived result; they
exist so the question "has this earned it?" has an answer that is
checked rather than argued. They are per-user by construction, which is
what ADR 0011 asked for — the user who opens Spotify and always presses
play is not the user who leaves it open all day.

Until a signal passes, it is logged as informational telemetry and
changes no state. That is already what ADR 0011 authorises, and needs
no further decision.

### 7. Foreground-app detection is ADR 0016's, not a second copy

An "opened an app" signal is a foreground-app observation, which ADR
0016 already lists as an input to the ambient focus score. It is
sourced from that layer. Pre-claim consumes focus signals; it does not
grow a parallel detector.

This matters on Android, where foreground-app detection means
`UsageStatsManager` and the `PACKAGE_USAGE_STATS` special access — a
restricted permission, on an app that already carries
notification-listener access and is mid-first-submission to Play.
That cost is paid once, for the focus layer, or not at all. It is not
worth paying for a rule-4 speculative trigger alone, and this is the
second reason decision 5 does not enable it today.

`MediaSessionSource` cannot substitute. It exposes `(key, isPlaying)`,
and the obvious proxy — a session that is active but not playing — is
permanently true on the reference device, where Audible holds a session
in `STATE_NONE` indefinitely. `MediaTriggerMonitor` documents exactly
this.

## Rationale
The mechanism and the policy are separated deliberately. Every part of
the mechanism — the interface operation, the speculative flag, the
priority rule, the bounded revert — is needed by the ringing signal
that ADR 0011 already approved, and is worth building for that signal
alone. The policy question of which *other* signals earn a pre-claim
then becomes a threshold check against measured data rather than a
fresh architectural argument each time.

Deciding the gate now, while no signal has passed it, is the point.
Written after the fact it would be a justification of whatever was
already built.

## Consequences
- `packages/protocol` changes twice over: `NodeInterface` gains
  `onPreClaim()`, and `EventPayload` gains `speculative`. Both are
  frozen-contract changes needing human merge.
- `packages/relay-core`'s priority engine gains the
  speculative-ranks-below-confirmed rule, the per-signal revert window,
  and the displaced-holder memory that decision 1 requires.
- Both adapters implement `onPreClaim()` and the promotion semantics of
  `onClaim()`-while-pre-claimed. The Mac and Android Bluetooth gateways
  already perform the mechanical work; what is new is entering it
  speculatively and being able to unwind it.
- `CallTriggerMonitor` stops dropping `RINGING` and emits it as
  `speculative = true`. Its kdoc, which currently explains why it drops
  the signal, becomes wrong and must change with it.
- ADR 0019 gains the `reverted_unconfirmed` outcome. If 0021 is adopted
  before 0019 ships, that outcome should land in 0019's first
  implementation rather than as a follow-up.
- **Sequencing.** This is new feature surface, and AGENTS.md puts
  reliability first. It should not start before:
  (a) **#236** — the holder currently oscillates between the Mac and
      the Pixel roughly every two minutes with nobody using either
      device; 293 `holder_change` and 200 `route_drift` events in 20
      hours. Adding a speculative claim source to a system already
      thrashing would make both harder to read.
  (b) **ADR 0019**, which is what makes a revert rate observable — and
      without which decision 6's gate cannot be evaluated at all.
  (c) **ADR 0020**'s debouncing, whose coalescing window and the
      supersede path interact directly with a pre-claim being
      overtaken mid-flight.
- The latency that prompted this is not addressed by adopting the ADR.
  Until a signal passes decision 6's gate, the only pre-claim in the
  system is the ringing call, and media switches are exactly as fast as
  they are today.
