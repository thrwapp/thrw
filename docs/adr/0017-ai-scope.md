# ADR 0017: AI scope — local classification for decisions, LLM for explanation only

## Status
Accepted

> **Numbering note.** Drafted as "0015" before 0013/0014 existed. It is
> 0017; cross-references renumbered. The decision is unchanged.

## Context
"Add AI" spans several genuinely different problems with very
different latency, cost, and reliability requirements: combining raw
signals into the focus score (ADR 0016), deciding which early signals
merit a speculative pre-claim (ADR 0011), and generating the
human-readable insights already planned for the in-app stats dashboard
and the proactive misconfiguration recommendations (ADR 0012). These
should not be treated as one undifferentiated "AI layer."

## Decision
AI is scoped into three distinct roles, deliberately using different
techniques:

1. Focus-score calibration: combining an adapter's raw signal vector
   (input activity, screen state, RSSI trend, idle time) into a single
   per-device focus score is a small, per-user classification problem.
   Implement as a lightweight model (logistic regression or a small
   decision tree) trained per-user on that user's own historical
   switch events, run in the AI engine service and periodically
   retrained, not called synchronously on the real-time switching path.
   This explicitly does not use an LLM — the decision must run with
   no network round-trip variance and needs to be evaluable in
   milliseconds; a five-feature classifier is sufficient and far
   cheaper.

2. Pre-claim confidence thresholding: extends ADR 0011's initial
   conservative scope (ringing-call only) by learning, per user,
   whether other early signals (VoIP app launched, calendar event
   imminent, lid wake) reliably precede an actual switch for that
   specific person, without producing visible flicker from false
   positives. Same technique and same locality constraint as #1 — a
   small per-user classifier, not an LLM call.

3. Natural-language explanation and recommendation: the in-app "AI
   insights" (e.g. "you typically switch back to Mac within 90 seconds
   of a call ending") and the proactive misconfiguration
   recommendations (ADR 0012) are where an LLM is the right tool —
   translating detected patterns and rule-table matches into specific,
   readable guidance for the user. This is not latency-sensitive (it
   runs on a schedule or on-demand, not on the switching path) and
   benefits from the model's language quality. Route via Vertex per
   ADR 0008's existing model table — Sonnet-tier is sufficient, this
   does not need Opus.

## Rationale
The real-time switching decision (which device should hold a resource
right now) must be fast, deterministic-enough to debug, and
offline-capable — none of which an LLM call provides, and none of
which a small per-user classifier struggles with. Reserving the LLM
for the explanatory and recommendation surface uses it where its
actual strength (language, synthesis) matters, and is also where users
perceive the product as "intelligent" — the underlying focus-tracking
model should be invisible and simply correct, while the insights
surface is where that intelligence becomes visible and legible.

## Consequences
services/ai-engine gains two responsibilities that must be kept
architecturally separate: a per-user classifier training/serving path
(numerical, small, fast, no LLM involved) and an insight-generation
path (LLM-based, per ADR 0008's routing). The classifier path needs a
retraining schedule (e.g. nightly, per user, on that user's
accumulated focus/switch telemetry) and a fallback default (e.g. a
simple recency-weighted heuristic) for users without enough history
yet to train a meaningful per-user model. This fallback-before-
personalization pattern should be called out explicitly in
services/ai-engine's own README so it isn't lost as a "TODO" that
never gets built.

**Training data does not exist yet.** Per-user classifiers need that
user's historical switch events, which means `services/telemetry` (M8)
must exist and have been collecting for some time before role #1 or #2
can do anything but fall back. The fallback path is therefore the
*first* thing to build, not the last — and will be the only thing
running for every new user indefinitely.
