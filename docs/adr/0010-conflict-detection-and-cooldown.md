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
