# ADR 0007: Single region at launch, with a measured trigger for adding a second

## Status
Accepted

## Context
Single-region hosting (ADR 0006) is the right choice for the primary
near-term use case (one user, two devices, one geography) but is a
guess about the future without some way to know when it stops being
true.

## Decision
Instrument p95 claim-round-trip latency per geography. Alert when it
exceeds 3.5-4 seconds (p95) for any geography holding more than 5% of
active accounts, sustained over a rolling 24-hour window. Treat that
alert as the trigger to add a second Compute Engine instance in the
nearest region to the affected geography — not before.

## Rationale
The target switch time is roughly 2-4 seconds typical, dominated by the
physics-bound cost of Bluetooth connect + audio profile negotiation on
the winning device (see docs/spec/architecture.md's Latency section for
the full breakdown) — not something the relay architecture can reduce
further, so this threshold is calibrated around a realistic floor
rather than an aspirational one. Above 3.5-4 seconds p95 the delay
becomes perceptible enough to undermine the core "it just works" value
proposition. Tying the infrastructure decision to a measured
threshold rather than a subjective sense of "we probably need more
regions now" avoids both under-investing (silently frustrating
overseas users who don't complain, they just churn) and over-investing
(paying for global infrastructure before there are global users).

## Consequences
Requires: a BigQuery telemetry pipeline capturing claim_roundtrip_ms
per switch event, synthetic latency probes per major region run on a
schedule, and a Cloud Monitoring alert policy on the threshold above.
The 3.5-4s / 5% / 24h numbers are explicitly provisional — both revisit
once real usage data exists, and (per docs/spec/architecture.md) still
need validation against real hardware timing (the Day 6-9 AirPods test)
before being treated as more than an estimate.
