# ADR 0011: Predictive pre-claim using early trigger signals

## Status
Accepted

## Context
Sequential handoff (ADR 0002) has a real mechanical latency floor of
2-4 seconds, dominated by Bluetooth connection establishment, which no
software architecture change can reduce. Apple's native switching
achieves a faster *perceived* result not because its handshake is
faster, but because the H1/H2 chip gives the OS an early signal (ear
removed) that lets it start reconnecting before the user has
consciously acted. thrw can access equivalent or better early signals
from sources already available to each platform's adapter, without
any special chip access.

## Decision
Introduce a "pre-claim" state to the node interface, distinct from a
confirmed claim. High-confidence early signals trigger a speculative
pre-claim that begins the disconnect/reconnect sequence before the
triggering event is confirmed:

- Incoming call ringing (not yet answered) — the single highest-value
  signal: a phone typically rings 1-3+ seconds before being answered,
  which is a larger lead time than Apple's own ear-detection signal
- VoIP app launched but not yet in an active call
- Calendar event with a video-call link starting within a few minutes
- Laptop waking from sleep / lid opening

If the predicted event doesn't materialize (call declined, meeting
doesn't start, app closed without joining a call), the adapter reverts
the pre-claim and returns the headset to its previous holder. This
revert is not treated as a failure — using dead time between "someone
opened Zoom" and "someone joined the call" to run a disconnect/
reconnect cycle costs nothing the user notices, versus running that
same cycle during a moment they're actively waiting.

Initial implementation should be conservative: only the ringing-call
signal is trusted for pre-claim at launch. Other signals (calendar,
VoIP app launch, lid wake) are logged as informational telemetry but
do not trigger a pre-claim until the AI engine's pattern-learning
(already planned for auto-return timeouts) has enough per-user data to
calibrate which signals are reliable for that specific user without
producing visible flicker from false positives.

## Consequences
The node interface needs a pending/pre-claim state distinct from
claim/release (see architecture.md's connection state machine). The
Android adapter's TelephonyManager integration should fire on
CALL_STATE_RINGING, not just CALL_STATE_OFFHOOK, treating the former
as the pre-claim trigger. This is a stretch goal for the Day 6-9
Android adapter work, not a blocking requirement for v0.1.0 — sequential
handoff without pre-claim is still a complete, shippable product;
pre-claim is what closes the gap with Apple's perceived speed
afterward.
