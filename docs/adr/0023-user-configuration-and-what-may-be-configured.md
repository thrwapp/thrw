# ADR 0023: User configuration, and the line around what may be configured

## Status
Proposed

## Context

#287 produced a question worth taking seriously: *how many times should
thrw re-assert a claim that keeps coming undone before concluding the
user meant it?*

There is no correct answer. The right number depends on facts thrw
cannot see — whether the user has a work laptop it does not manage, how
often they move the headset by hand, how much they would rather it gave
up early than fought them. #289 picked **two** and justified it against
the failure it repairs, which is the best a fixed constant can do. It is
still a guess about someone else's working day.

Several other constants have the same shape:

- The self-cooldown window (ADR 0010, lengthened to 6s by #251).
- #264's `UNREACHABLE_AFTER_MS`, explicitly "a reasoned margin, not a
  measurement".
- Which applications count as VoIP (`VoipTriggerMonitor`'s bundle list).
- Whether `media` should trigger a switch at all — reasonable people
  differ, and #288's flapping trigger would matter far less to someone
  who had turned it off.

So: a user-facing configuration file. ADR 0005 already requires
*build-time* config for the relay URL and licensing endpoint; this is a
different thing, read at runtime and edited by the person using the
product.

The interesting part is not the file format. It is **which settings may
exist at all**, because this project has several constants that look
like knobs and are not.

## Decision

Adopt a user-facing runtime configuration file per adapter, and admit
settings to it only by the following test.

### 1. Configurable: statements of user intent

Things where the user knows something thrw cannot, and where two users
would reasonably want different answers.

- How many times a claim is re-asserted before thrw backs off (#289).
- Whether `media` is a trigger at all, and whether `voip` is.
- Which applications count as VoIP.
- Whether thrw may pause itself after repeated override (#290's
  mechanism, the auto version).

### 2. Not configurable: anything the frozen contract requires to be identical

Refusing these is the substance of this ADR.

- **ADR 0019's command-outcome bound.** Its own source comment says why:
  "an adapter choosing its own bound makes the aggregate switch success
  rate meaningless, because an outcome would not mean the same thing in
  every row of the resulting data." A per-install bound destroys the only
  number that says whether thrw is reliable.
- **Topic structure, resource segments, sequence numbers and epochs**
  (ADR 0001, 0015, 0018). Frozen contracts; a config file is not an ADR.
- **Priority order.** architecture.md puts it server-side, "never
  duplicated in adapters". A per-device priority setting would duplicate
  it in the worst possible place.

### 3. Deliberately not configurable, though tempting: measured timing

The self-cooldown window and `UNREACHABLE_AFTER_MS` are **not** exposed,
despite being exactly the kind of number a user might want to tune.

Both are compensations for hardware behaviour, derived from measurement
against the reference devices. Exposing them converts a bug into a
support knob: the next report of chatter or a mislabelled outcome gets
answered with "try raising it" instead of being diagnosed, and the
project loses the ability to reason about telemetry across installs
because no two are running the same numbers.

If the reference values turn out to be wrong for real hardware, that is
evidence to change the constant — and to record why — not evidence to
hand the decision to the user.

### 4. Relay-side policy stays fixed, for now

This is the part with no clean answer, and it needs stating rather than
discovering during implementation.

**The re-assert bound lives in the relay, not the adapter.** A file on
the user's Mac cannot change `MAX_HOLDER_REASSERTS`, because the code
reading it runs on a VM. Three ways out, none free:

1. **Carry policy in the registration payload.** Changes the wire
   format, so it is a frozen-contract change needing its own ADR — and
   it makes each node able to assert policy for a resource several nodes
   share. Two nodes could disagree.
2. **Per-account config stored relay-side.** The relay holds its state
   in memory by design and has nowhere durable to put this.
3. **Leave it fixed.**

**Decision: (3), for now.** Adapter-local settings ship first, because
they are the ones a local file can actually deliver. The re-assert bound
is the motivating example of a setting users might want, and it is the
one this cannot give them — which is worth being honest about rather
than quietly shipping a file that omits it.

If evidence says the bound is wrong for real users, the first move is to
change the constant, not to build (1) or (2).

## Rationale

The temptation with configuration is to expose whatever is easy, which
over time turns every uncertain decision into the user's problem. This
project has already spent real effort deriving constants from
measurement — #254's 4.9s, #251's 6s, #264's 3s — and each of those
numbers is written down with its reasoning. Making them editable would
discard that work and, worse, make the telemetry that produced them
incomparable between installs.

The line drawn here is: **thrw configures what the user knows better
than thrw does, and hard-codes what thrw has measured.**

## Consequences

- A config file per adapter, read at runtime, with a documented schema.
  Format and location are implementation detail and deliberately not
  decided here.
- Every new setting needs an argument that it belongs in category 1.
  Adding one to categories 2 or 3 requires amending this ADR.
- An unreadable or malformed config must fall back to defaults and say
  so visibly — the failure mode of a silently ignored config file is a
  user convinced they have changed something they have not, and this
  project has enough silent failures in its history.
- The settings most likely to be asked for first — the re-assert bound —
  cannot be delivered by this mechanism. See decision 4.
- ADR 0005's build-time config is unaffected and stays separate: relay
  URL and licensing are properties of a *build*, not preferences of a
  user.
