# Device compatibility matrix

Tracks which hardware combinations have been verified to work
correctly, versus assumed to generalise from limited testing. Update
this file whenever a new device combination is tested, and treat an
untested combination as unverified regardless of how similar it looks
to a tested one — Android OEM Bluetooth stack variance in particular
is a known source of behaviour that does not generalise from Pixel
testing (see ADR 0002 and docs/spec/architecture.md on the per-OEM
root requirements).

This is a live document, not a one-time artifact. Update it as part of
the Day 6-9 / Day 10-13 hardware testing work already scoped in the
setup sequence, and again whenever ADR 0019's telemetry surfaces a
device combination with a meaningfully different success rate.

## Format

One row per combination:

headset model | host A | host B | switch success rate (from ADR 0019
telemetry, once available) | last verified date | known issues |
verified by (manual test or telemetry-derived)

## Current status

| Headset | Host A | Host B | Success rate | Last verified | Known issues | Verified by |
|---|---|---|---|---|---|---|
| AirPods Pro 2 (Lightning case, H2; firmware 9A348 observed) | MacBook Air 13" M4 (2025) | Pixel 10 Pro | pending ADR 0019 telemetry | **2026-09-20** — media-driven switch verified in both directions against `relay.thrw.app` | multipoint makes Bluetooth link state useless as a holder signal (see below); a spurious never-ended `call` was observed once (#183) | manual test, see *Verified scope* below |

Hardware models are the reference devices from
docs/spec/architecture.md.

## Verified scope (2026-09-19 / 2026-09-20)

Recorded at the granularity this file asks for: what was actually
observed, not what the code implies. Everything below was run with both
adapters installed as apps, against the deployed `relay.thrw.app`.

**Verified**

- **Media-driven switch, both directions.** Playing on the Mac claimed
  the headset (Mac default output became the AirPods); playing on the
  phone took it (Mac fell back to `MacBook Air Speakers`, phone's A2DP
  `mActiveDevice` became the AirPods).
- **No oscillation when the loser keeps playing.** With the Mac's audio
  still running after it lost the route, it did not reclaim over 25s.
  The self-cooldown (#167) is what prevents this — its first confirmed
  exercise in a real handoff.
- **Reconnect after connectivity loss**, both platforms (#182): phone via
  airplane mode, Mac via cycling Wi-Fi. Both reconnected, restored
  subscriptions and re-registered.
- **A claim is genuinely delivered on a restored subscription** — after a
  reconnect, a claim reached the phone and it acted on it
  (`BluetoothA2dp.connect`, AirPods became the active device). Worth
  separating from the above: a client that returns but is deaf looks
  identical to a healthy one until a claim is missed.

**Measured timings** (the source of the numbers ADR 0018/0020 now cite)

- Claim → audio route actually moves: **3-5s**.
- Release → route leaves: within **3s**.
- The claiming device's own media monitor re-fires at **+4s/+5s** after
  its own claim, i.e. outside ADR 0010's 3s window.

**Not yet verified** — do not infer these from the above

- Call trigger claiming from the Mac, and auto-return after the call.
- Manual claim from either device.
- Walking out of Bluetooth range.
- Provisioning from scratch on a clean install.
- Any headset other than this one, and any Android OEM other than Pixel.

## Multipoint: Bluetooth link state is not a holder signal

The single most important finding for anyone implementing
reconciliation (#191, ADR 0018 decisions 2 and 3). With the **phone**
holding the route:

| | reports |
|---|---|
| Mac, `system_profiler SPBluetoothDataType` | AirPods Pro → **Connected** |
| Mac, default output device | **MacBook Air Speakers** |
| Phone, `dumpsys bluetooth_manager` | `mActiveDevice: …:2A:21` |

Both hosts held a link simultaneously. Anything that treats "am I
connected to the headset" as "do I hold it" will see two holders and
never resolve the drift. The holder signal is the **audio route**:
`kAudioHardwarePropertyDefaultOutputDevice` on macOS, A2DP
`mActiveDevice` on Android.

## Priority order for expanding coverage

1. **Additional Android OEMs beyond Pixel — Samsung first.** Pixel is
   the only Android device thrw has ever run on, and the OEM stack is
   the most likely place for behaviour to diverge. Note that the root
   requirement picture is only documented for Pixel: ADR 0002 and
   architecture.md record that Android 16 QPR3 / Android 17 fixed the
   L2CAP bug forcing root for basic AirPods control "on Pixel and some
   OEMs" — whether Samsung is among them is **unverified**, and should
   be checked before this tier is scheduled rather than assumed either
   way.
2. **Additional AirPods generations** — AirPods Pro 2/3, AirPods 4,
   AirPods Max. The AAP protocol details LibrePods relies on have been
   reported to vary by generation.
3. **Sony / Nothing headphones, once their adapters exist.** Per
   docs/spec/architecture.md ("Why Sony/Nothing headphones are
   architecturally simpler than AirPods") these use standard
   Bluetooth multipoint — a structurally different and likely more
   consistent code path, worth verifying separately rather than
   assuming parity with AirPods.

## Sourcing note

Every row must say how it was verified. A telemetry-derived success
rate (ADR 0019) and a manual test are both acceptable evidence; an
inference from "the code path is the same" is not, and is exactly what
this file exists to prevent.
