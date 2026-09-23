# ADR 0010: Conflict detection and cooldown for BT connection management

## Status
Accepted

## Context
thrw actively disconnects and reconnects a shared Bluetooth device
across multiple hosts. Several other actors can be managing the same
connection concurrently: the OS's own auto-reconnect logic, the user
manually changing Bluetooth settings, other third-party switching apps
(ToothFairy, AirBuddy, etc.), and apps with their own device-audio
routing (Spotify Connect is a documented case where AirPods' own
switching already loops with it). Without explicit handling, thrw's
switching logic can fight any of these, causing flicker, unexpected
disconnects, or infinite reconnect loops.

## Decision
Each adapter maintains an explicit lock state per managed headset:

1. Self-cooldown: after thrw initiates a claim or release, it
   suppresses processing of its own resulting connection-state-changed
   events for a short window (~3 seconds) so it doesn't misread the
   side effects of its own action as a new trigger.
2. Manual override detection: if the local OS reports a BT connection
   state that contradicts the relay's last known "current holder," and
   that change wasn't initiated by thrw's own claim/release, treat it
   as a deliberate user action. Update the relay's state to match
   rather than reverting it. A user manually connecting via system
   settings always wins.
3. Scope limitation: thrw only manages headsets the user has explicitly
   registered with it. It never opportunistically acts on other paired
   Bluetooth devices, even ones with active connections.
4. Known-conflict detection: on startup, each adapter checks for known
   conflicting processes/apps (ToothFairy, AirBuddy on Mac; other
   AirPods managers on Android) and surfaces a warning to the user
   rather than silently coexisting or fighting. This list is
   maintained in adapter config, not hardcoded, so it updates without
   a full release.
5. App-priority allowlist: a configurable per-user list of apps
   (Spotify Connect is the known example) during whose active use thrw
   suppresses its own automatic switching, deferring to that app's own
   device routing. Manual claim still works during this suppression
   window.

## Consequences
Every adapter needs a small local state machine (idle -> claiming ->
cooldown -> idle) rather than reacting to every BT event as an
independent trigger. The relay's "current holder" state must be
treated as advisory from the adapter's perspective when it conflicts
with a fresher local OS signal — the adapter is the source of truth
for what's actually connected locally; the relay is the source of
truth for what should be connected. Reconciling these two is new logic
that must be added to packages/protocol's node interface before
adapters are built. This ADR also introduces the concept extended by
ADR 0012 (proactive conflict resolution): detecting a conflicting app
is necessary but not sufficient — the product should actively help the
user resolve it, not just warn and stop.

## Amendment (2026-09-23): the window is 6 seconds, and `call` is exempt

Decision point 1 above specifies the self-cooldown as "a short window
(~3 seconds)". That number was an estimate of how long thrw's own side
effect takes to play out. **It is too short, and the measurement that
shows so is in a later ADR.**

ADR 0018 records that "a claim takes 3-5s to move the route" on the
reference hardware — measured, not estimated. So the window that exists
to cover our own route change closes *before* that change has finished
happening. Any audio-routing event from the tail of the transition —
between 3s and 5s — arrives outside the cooldown and is read as a fresh
trigger.

Observed on the reference Mac/Pixel pair on 2026-09-23 (#251), with
media playing on both devices: the Mac emitted `media` start/end pairs
1-5 seconds apart while YouTube played continuously, and because the
tie-break is most-recently-started, each restart took the headset back
while each end handed it to the phone. The headset bounced
indefinitely. The relay arbitrated correctly throughout; the trigger
was lying to it.

**The window becomes 6 seconds** — covering ADR 0018's measured 3-5s
upper bound with margin, and staying clear of ADR 0019's 8s command
bound so the two do not interact confusingly.

**`call` joins `manual_claim` as exempt.** Lengthening a window that
suppresses *every* non-exempt trigger would otherwise mean a genuine
incoming call within 6 seconds of a switch is dropped — and a call is
the signal this product can least afford to miss, being first in
`PRIORITY_ORDER`.

The exemption is safe on principle, not merely convenient. The cooldown
exists because *connecting the headset changes audio routing*, which
route-derived triggers misread. Neither platform's call trigger is
route-derived: Android's comes from `TelephonyCallback` (telephony
state), macOS's from running-application detection. A real call cannot
be an echo of our own route change, so there is nothing here for the
cooldown to protect against.

This corrects the number against decision point 1's own stated intent —
"so it doesn't misread the side effects of its own action as a new
trigger" — rather than reversing the decision. The mechanism stands;
the estimate did not survive contact with hardware.

**Still open, deliberately not decided here.** A fixed window is blunt
either way: it suppresses genuine triggers for its whole duration, and
covers echoes only if it happens to be long enough. The sharper design
is to end suppression when the route observation *confirms* the
transition landed, with a time bound only as a backstop —
`RouteTransition` already implements that shape for route *reporting*.
That is a larger change and is not made here. ADR 0020's debouncing and
command coalescing attacks the same symptom from the relay side and is
also still unimplemented. #251 records both as follow-ups.
