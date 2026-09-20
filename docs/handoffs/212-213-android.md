# 212 + 213 — manual claim and status, Android

The Android halves of #212 and #213. One change because both live in the
same surface: the foreground-service notification, which is already
permanently on screen and until now said nothing useful.

## What the notification says now

The static blurb — *"Watching for calls and VoIP sessions to switch your
headset"* — read identically whether the adapter was working or had
silently lost its connection two hours ago (#182). It is replaced by the
current status:

| state | text |
|---|---|
| transport down | `Disconnected from relay` |
| connected, holds the route | `Holding headset` |
| connected, does not | `Not holding headset` |
| connected, route unreadable | `Connected — headset state unknown` |

Plus a single action that toggles between **Claim headset** and
**Release headset**.

## Mirrors the Mac deliberately

`NodeStatus`, `nodeStatus(isConnected, holdsRoute)`, `ManualClaim` and
the cooldown exemption are the same shapes as `adapter-mac`'s, with the
same reasoning:

- **Disconnected outranks the route.** While the transport is down any
  holder state is a stale belief; reporting a crisp "Not holding" for a
  node that is not talking to the relay is #182 dressed as information.
- **An unreadable route is not "no".** #191's observer returns `null`
  when it genuinely cannot tell.
- **The claim persists and is a toggle**, because ending it immediately
  lets the engine recompute the holder from whatever is still active
  elsewhere and hand the headset straight back.
- **`manual_claim` is exempt from the self-cooldown**, or the control
  does nothing for three seconds after any switch — precisely when it is
  reached for.

Both cooldown directions are mutation-tested on this platform too:
removing the exemption fails the manual-claim tests, exempting everything
fails #167's suppression tests.

## Android-specific decisions

**`isConnected()` is `MqttClientState.CONNECTED` alone.** The
reconnecting states mean publishes are currently failing, which is what
the user needs told rather than smoothed over as "probably fine".

**The action re-enters `onStartCommand`.** A started service has no other
inbound channel, so the notification's `PendingIntent` carries
`ACTION_TOGGLE_CLAIM` and is handled before the provisioning read — so a
tap never restarts the runtime (which would be #182's duplicate-client
bug all over again).

**The notification is refreshed on events, not on a timer.** After a
toggle and when the runtime starts. A periodic refresh would wake a
battery-sensitive foreground service to keep a string current that is
only read when the shade is open.

**The action only exists once a node is running.** An action that
silently does nothing is worse than one that is not there.

## Verification

- `adapter-android` suite green; `adapter-mac` 146 (unchanged by this).
- Mutation-tested on the cooldown exemption, both directions.
- **On the device**, against the live relay:
  - `android.text=String (Not holding headset)` — the status line is real
    and correct (the headset was powered off, so the route genuinely was
    not here).
  - `actions=1` — the claim action is present on the posted
    notification.

### Not verified: tapping the action

The phone was on the keyguard (`isKeyguardShowing=true`), so the action
button was not reachable from the shade, and `adb am start-foreground-service`
is refused — *"Requires permission not exported from uid 10497"* — which
is **correct**: the service is deliberately not exported, and only the
app's own `PendingIntent` may start it. A real tap runs with the app's
identity and is unaffected.

So the wiring from tap to `manual_claim` on the wire is unconfirmed on
both platforms. One tap on an unlocked phone closes it.

## Not done

- The status shows whether *this* node holds the headset, not which other
  device does. That needs the relay's state topic, which no adapter
  subscribes to.
- ADR 0020 decision 2's offline half, for the same reason as the Mac: it
  needs local execution bypassing the relay, and ADR 0020's offline
  behaviour is not implemented at all.
