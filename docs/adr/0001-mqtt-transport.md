# ADR 0001: MQTT over WebSocket/TLS as the relay transport

## Status
Accepted

## Context
Devices need to exchange small, latency-sensitive state changes (claim,
release, heartbeat) with a cloud relay, reliably over both wifi and
mobile data connections including 3G-class networks with intermittent
connectivity.

## Decision
Use MQTT over WebSocket/TLS. Claim/release events use QoS 1. The current
holder state is published as a retained message.

## Rationale
MQTT was designed specifically for constrained, high-latency, unreliable
network conditions — it has native reconnect and keep-alive semantics
that a raw WebSocket or REST-polling approach would have to reimplement
badly. Message payloads for this use case are tiny (a claim event is
essentially "who, what triggered it, when" — well under 200 bytes),
so MQTT's low overhead matters. QoS 1 rather than QoS 2 is a deliberate
choice: a duplicate claim event is tolerable and easy to make idempotent,
but a missed claim during a live call is not, so "at least once" is the
right guarantee without paying for the more expensive "exactly once"
handshake.

## Consequences
Every adapter needs an MQTT client library for its platform. The relay
is an MQTT broker (EMQX chosen for its WebSocket support and
multi-tenant ACL capability), not a generic HTTP service.
