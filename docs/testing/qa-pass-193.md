# Running the hardware QA pass (#193)

The procedure for a cross-device pass on the reference pair. Written
during the 2026-09-25 pass, which found two bugs and could not run the
physical half — so this exists to make the next one repeatable rather
than improvised.

Results go in `compatibility-matrix.md`, not here. This is the method.

## Before you start

**Both adapters running, on the version you mean to test.**

```
pgrep -lf AdapterMacApp
adb shell dumpsys package app.thrw.android | grep versionName
```

`/Applications/AdapterMac.app` is the installed Mac app. A dev build run
from a worktree is a different thing and should not be mixed into a pass.

**gcloud authenticated**, or the relay capture starts and dies:

```
gcloud auth login
```

The token expires and the failure is not obvious — `qa-capture.sh start`
reports `relay DEAD` and the reason is in `relay.err`.

**Optional, and worth it before a multi-day run.** `.info`-level os_log
records are memory-backed and do not survive for a later `log show`, so
anything not captured live is gone:

```
sudo log config --subsystem app.thrw.mac --mode "level:info,persist:info"
```

**Know where the headset is before you begin.** Neither adapter reports
this honestly in every state (#303), so read the hardware:

```
adb shell dumpsys bluetooth_manager | grep -m1 mActiveDevice
system_profiler SPAudioDataType -json | grep -B2 default_audio_output
```

## The loop

```
./scripts/qa-capture.sh start <name>
./scripts/qa-capture.sh mark "about to <do the thing>"
   … do the thing …
./scripts/qa-capture.sh mark "observed: <what happened>"
./scripts/qa-capture.sh stop
./scripts/qa-capture.sh merge
```

**Mark every physical action, before doing it.** A log says what thrw
did; only a mark says what a human did, and a handover with no recorded
cause is exactly what this pass exists to stop producing. Mark the
observation too — "the Mac kept playing out loud" is evidence, and it is
not in any log.

Check `status` occasionally during a long run. A capture that dies is
only noticed at `stop` otherwise, by which point the run is lost.

## Items, and what counts as passing

Ordered by value, not by the issue's numbering. Each needs **evidence on
both devices**, not relay traffic alone — the relay reports what it
believes, and #303 is the case where that was wrong for seventeen
minutes.

### 1. Call trigger and auto-return

The highest-priority rule in the stack, and asymmetric: the Mac cannot
detect phone calls at all (`architecture.md`, "Mac's trigger-detection
gap"), so this is phone-claims-from-Mac, never the reverse.

1. Play media on the Mac; confirm the Mac holds the route.
2. Call the Pixel. Expect: `call` event, RELEASE to Mac, CLAIM to Pixel,
   and the audio physically on the phone including HFP for the mic.
3. End the call. Expect the route to return to the Mac **if** the Mac
   still has active media — immediately, not after the rule-5 timer.

Passing needs the Mac's default output and the phone's `mActiveDevice`
read at each step, plus the relay's `holder_change` lines.

### 2. Manual claim, including with the relay unreachable

Never exercised on either platform. The offline half is ADR 0020
decision 2, which is **known not to work today** — `ManualClaim.toggle()`
awaits an MQTT publish before changing any state, so with no relay it
fails shut rather than safe. Run it anyway and record the actual
behaviour; that decision is blocked on ADR 0014 and deserves a hardware
observation rather than a code reading.

Airplane-mode the phone, or point the adapter at an unreachable host.

### 3. Out of range, and sleep

Walk out of Bluetooth range with each device holding. Sleep the phone
past the 60s keepalive. #182 fixed the broker-restart case specifically;
these are different triggers into the same reconnect path.

### 4. Clean-install provisioning

From the packaged artifact, on both platforms, from scratch. Never done
— every install so far has been an upgrade over existing state.

### 5. Days of ordinary use

The one that cannot be faked by a deliberate session, and the one that
found #303. Leave the capture running and use the devices normally.
`merge` afterwards, and look for: holder changes with no mark near them,
`reassert_exhausted`, `route_drift` that does not resolve, and any node
reporting `observedRoutes: {}` on more than two consecutive
registrations.

## Reading a run

`merge` interleaves marks with relay decisions. What to look for:

| Pattern | Means |
| --- | --- |
| `holder_change` with no mark nearby | thrw switched for a reason the user did not create |
| `observedRoutes: {}` repeating | that node has gone un-reconcilable (#303) |
| `reassert_exhausted` | the relay has given up on a holder it still believes in (#301) |
| `route_drift` that never resolves | belief and hardware disagree and nothing is fixing it |
| a command with no `command_outcome` | ADR 0019's 8s bound violated |

The per-device logs stay in the run directory for when one of those
needs explaining. They are deliberately not in the merged view: the
Bluetooth chatter is voluminous and nobody reads it by choice.

## A warning about inference

The Mac's `Triggers/` and `Route/` contain **no logging at all**, so an
empty `mac.ndjson` means "this code does not log", not "nothing
happened". The 2026-09-25 pass nearly concluded that triggers were being
suppressed on that basis, which the code does not support. Check whether
a path logs before reading its silence as a result.
