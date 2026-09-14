# ADR 0006: GCP Compute Engine for the relay, not Fly.io or Cloud Run

## Status
Accepted (supersedes an earlier Fly.io-based design)

## Context
The relay needs an always-on host for its MQTT broker. Fly.io was the
original choice (edge-distributed "Machines," simple deploy story).
Given an existing GCP account and billing relationship, consolidating
onto GCP was evaluated as an alternative. Within GCP, Cloud Run
(serverless containers) and Compute Engine (persistent VMs) were both
considered.

## Decision
Compute Engine, an e2-micro instance in an Always Free eligible region,
running the relay (EMQX) and self-hosted Keygen CE as containers on the
same VM. Not Cloud Run. Not Fly.io.

## Rationale
Cloud Run force-closes every connection, including MQTT-over-WebSocket,
at a 60-minute cap — this would mean every device reconnecting at least
hourly forever, adding needless churn and a periodic latency blip
directly in the switching path this product is trying to keep fast.
Compute Engine has no such cap and is the correct like-for-like
replacement for what Fly Machines were providing (persistent,
always-on compute), not a downgrade. Consolidating onto GCP also means
one billing account, one IAM setup, and native Workload Identity
Federation for CI auth (no long-lived secrets stored in GitHub at all),
replacing what would otherwise be three separate accounts (Fly.io,
Vercel, Doppler).

The realistic monthly cost is $0 (Always Free tier) to ~$20, versus a
comparable multi-service spread across three separate platforms
previously.

## Consequences
Single-region only at launch — Fly.io's edge-distributed model is
given up in exchange for the above. See ADR 0007 for how regional
latency is monitored so this remains a measured tradeoff rather than
an unexamined one. Keygen CE shares fate with the relay VM (both go
down together); acceptable because Keygen's offline validation caching
means already-activated devices keep working even if Keygen itself is
briefly unreachable.
