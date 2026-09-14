# ADR 0009: Stripe for billing, self-hosted Keygen for device licensing — decoupled

## Status
Accepted

## Context
Users need to install thrw on multiple devices under one subscription,
with a per-tier device limit (Free=1, Pro=3, Teams=pooled), offline
validation tolerance (per the 3G/no-wifi requirement), and the ability
to see and revoke individual device activations. Stripe alone has no
concept of device-bound licenses. Payments-first tools with bundled
license keys (Polar.sh, Lemon Squeezy) were evaluated as alternatives.

## Decision
Stripe handles subscription billing exclusively. A self-hosted Keygen
Community Edition instance (co-located on the relay's Compute Engine
VM) handles device licensing exclusively. A small webhook bridge
(services/billing) translates Stripe subscription lifecycle events
into Keygen API calls (create license / update policy / revoke).

## Rationale
Polar's and Lemon Squeezy's license-key features are described
consistently (including by their own comparison pages) as thin
validation counters bundled with their checkout — no device
fingerprinting, no offline validation caching, and switching to either
for licensing would mean migrating payments to their checkout too.
Keygen is purpose-built for exactly the device-activation problem this
product has, is free to self-host (Community Edition, same codebase as
their managed Cloud offering), and integrates with Stripe via a
standard webhook pattern rather than requiring a payments migration.
Self-hosting avoids Keygen Cloud's paid tiers (which start at $99/mo)
while keeping license validation data under thrw's own infrastructure.

## Consequences
Keygen CE and the relay share a VM and therefore share fate (see ADR
0006's consequences) — mitigated by Keygen's offline-cache design
meaning already-activated devices keep working through a brief outage.
Each platform adapter needs a Licensing module (Licensing.kt,
Licensing.swift, licensing.rs) implementing activate/validate/
deactivate against Keygen's REST API with a locally cached fallback
result for offline operation — this mirrors the same
offline-tolerance pattern used for MQTT relay reconnection (ADR 0001),
which is a deliberate consistency, not a coincidence.
