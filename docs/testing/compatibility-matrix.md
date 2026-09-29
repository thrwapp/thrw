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
| AirPods Pro 2 (Lightning case, H2; firmware 9A348 observed) | MacBook Air 13" M4 (2025) | Pixel 10 Pro | pending ADR 0019 telemetry | **2026-09-26** — call trigger and auto-return verified both directions; media-driven switch verified 2026-09-20. **Read the 2026-09-25/26 section before treating the 09-20 notes as current.** | the relay never stops believing a holder both nodes contradict, reachable from the ordinary morning path (#307); the Mac can latch into a phantom `media` event and stop reporting its route (#303); ADR 0022's macOS audio suppression is inert on this headset, so a call ends playback permanently (#304); multipoint makes Bluetooth link state useless as a holder signal (see below); a spurious never-ended `call` was observed once (#183) | manual test, see *Verified scope* below |

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

**The call path, verified 2026-09-20** — the highest-priority rule, and
the least acceptable thing to get wrong.

A real cellular call on the Pixel, with the Mac holding the headset and
playing audio:

```
14:33:24  nodes/…pixel/events   {"type":"call","priority":0}
14:33:24  commands/…mac         {"type":"release", …}
14:33:24  commands/…pixel       {"type":"claim",   …}
          -> phone mActiveDevice = AirPods, HFP connected (the call profile)
          -> Mac default output fell back to MacBook Air Speakers

14:34:02  nodes/…pixel/events   {"kind":"event_end","type":"call"}
14:34:02  commands/…pixel       {"type":"release", …}
14:34:02  commands/…mac         {"type":"claim",   …}
          -> Mac default output = AirPods Pro #2, phone mActiveDevice = null
```

Both directions physically confirmed on the devices, not inferred from
the relay traffic. Auto-return was immediate rather than waiting out the
grace period, which is correct: the Mac still had active `media`, so the
holder recomputed to it directly rather than falling through to the
rule-5 timer.

**Not yet verified** — do not infer these from the above

- ~~Manual claim from either device~~ — **done 2026-09-26/27**, see item 2
  below.
- Walking out of Bluetooth range.
- Any headset thrw is not provisioned for. `ProvisioningState` binds a
  single `headsetIdentifier`, so a second headset is not "untested" — it
  is outside the product. Recorded because it came up in real use
  (2026-09-29, a Sony set on a flight) and the honest answer was to pause
  arbitration, not to expect thrw to cope.
- Provisioning from scratch on a clean install.
- Any headset other than this one, and any Android OEM other than Pixel.

## Pass of 2026-09-25 (#193), adapters 0.2.4

**Read this before the 09-20 section above.** Two things recorded there
as verified have since been observed failing, so that section is a record
of what was true on 09-20 and not a statement about the current build.

The 09-25 half of this pass was cut short: the Pixel dropped off `adb`,
so the physical items were not run, and everything in the "new findings"
list below came from observing the reference pair while idle. **Item 1
was run on 2026-09-26** and is recorded further down; items 2-5 remain
unrun.

**Regressed since 09-20**

- **A call no longer reliably moves the headset.** Both a WhatsApp call
  and a cellular call on the Pixel failed to take it from the Mac
  (reported 2026-09-25). The call path itself is unchanged; what changed
  is that the relay can now reach a state where it believes a node holds
  the route, that node does not, and #289's re-assert bound has stopped
  trying — from which no trigger produces a holder change and so no
  command is sent. #301, fix in #302.

**New findings**

- **The Mac can latch into a phantom `media` event and stop reporting its
  route** (#303). Observed live for 17 minutes: `activeEvents: ["media"]`
  with `kAudioDevicePropertyDeviceIsRunningSomewhere` measured at **0**
  and no media application running, and `observedRoutes: {}` on every
  registration where the same node had reported `{"audio": false}`
  reliably for the preceding 13 minutes. Nothing in the system ends this
  state; restarting the adapter cleared both symptoms in one
  registration, and the relay logged `route_drift` within milliseconds of
  the first honest report. A node that omits its route is invisible to
  ADR 0018 reconciliation, not merely unhelpful.
- **ADR 0022's macOS audio suppression is inert on this headset** (#304).
  `HandoverAudioGate` logs "volume of 74-15-F5-12-2A-21:output is
  unreadable; not muting for handover" on every handover — the AirPods
  expose no readable main-element volume, so the gate correctly refuses
  to mute a device it could not restore, and therefore never mutes. This
  is the same fact that invalidated the ADR's original measurement in
  #282/#283; what was missed is that it removes the mechanism's basis.
- **The Mac never reported `observedRoutes: {"audio": true}` once**, in
  any registration across the whole session, including while it was the
  believed holder. Not yet explained, and not the same claim as #303 —
  recorded here so the next pass looks for it deliberately.
- **A claim can go unresolved past ADR 0019's 8s bound.** The Mac's claim
  at 20:44:23 never produced a `command_outcome` of any kind, for 17
  minutes. Part of #303.

**Confirmed still true**

- Multipoint still makes Bluetooth link state useless as a holder signal;
  the audio route remains the only sound signal. The Android reported
  `observedRoutes: {"audio": true}` while the Mac believed itself holder,
  which is exactly the asymmetry the section below describes.

**Item 1 (call trigger and auto-return) — PASSES, both forms**

Re-run 2026-09-26 against the relay carrying #302. Verified physically on
both devices at each step, not inferred from relay traffic.

| | release | claim | note |
|---|---|---|---|
| Outgoing call, Mac→Pixel | 16ms | 26ms | no-op: the Pixel already held the route, so `connect` took its already-connected skip path |
| Auto-return on call end, Pixel→Mac | 781ms | 897ms | immediate, because the Mac still had active `media` |
| Incoming call, Mac→Pixel | 755ms | **3340ms** | a real claim |
| Auto-return after 90s grace, Pixel→Mac | — | 764ms | the Mac had no trigger, so `DEFAULT_AUTO_RETURN_MS` applied |

The 3340ms claim is the **second** real measurement of claim settle time,
against #254's single ~4.9s sample. Both sit inside
`DEFAULT_CLAIM_WINDOW_MS` (6000), which the coalescer derives from the
first. Two points is still not a distribution.

Both auto-return paths behaved as designed and the distinction between
them is worth recording: with a live trigger on the previous holder the
return is immediate; without one it waits out the 90s grace. On
2026-09-25 the second case was briefly misread here as "the headset does
not come back" — it does, after 90 seconds.

**What does not come back is the playback.** The call stopped YouTube on
the Mac (user confirmed they did not pause it), and nothing resumes it,
so the headset returns silent. That is #304's cost, not a separate fault.

**Not covered by this pass:** #302's own guard never fired. Both calls
landed on a node that was *not* the believed holder, so they produced
genuine holder changes through ordinary arbitration. The shape #302
fixes — an urgent trigger on the node the relay already believes is
holder — remains unverified on hardware.

**The wedge is reachable from the ordinary morning path** (#307). Taking
the AirPods out of the case connected them to the Pixel, with no
involvement from thrw, while the relay's retained belief still pointed at
the Mac. From there: the Mac reported `{"audio": false}`, the Pixel
reported `{"audio": true}`, the relay logged `route_drift` for both and
`reassert_exhausted`, and issued nothing. YouTube played out of the
MacBook speakers until an incoming call happened to reset the tenure.

**Item 2 (manual claim) — the online half PASSES, the offline half fails as ADR 0020 predicted**

Run 2026-09-26/27. The tap-to-wire path had never been exercised on
either platform before this.

| | result |
|---|---|
| Claim from the Pixel, over **live media on the Mac** | pass — `manual_claim` outranked `media`; release 700ms, claim 1167ms |
| Persistence: Mac starts media while the Pixel holds a manual claim | pass — `holderBefore=pixel holderAfter=pixel`, no command issued. Media elsewhere cannot take a manual claim back, which is the whole point of the control |
| Claim from the Mac, contesting the Pixel's claim | pass — most-recently-started won; release 341ms, claim 949ms |
| The losing node **ends its own claim** rather than suspending it | pass — `event_end manual_claim` from the Pixel at 08:23:24.220. First hardware verification of #234 criterion 5 |
| Toggle off, then on | pass |
| **Claim with the relay unreachable** (airplane mode) | **fail** — see below |
| **Feedback when a claim fails** | **fail** — #309 |

The offline failure is ADR 0020 decision 2, until now only a code reading:

```
20:52:37.939  E AdapterForegroundService: Manual claim failed
20:52:43.588  E AdapterForegroundService: Manual claim failed
20:52:44.726  E AdapterForegroundService: Manual claim failed
20:53:51.354  E AdapterForegroundService: Manual claim failed
```

`mActiveDevice` stayed `null` throughout and the Mac kept the route.
`ManualClaim.toggle()` awaits an MQTT publish before changing local state,
so with no relay it fails shut — the ADR's own consequences rule that out
("a path that blocks on an MQTT publish is not offline-capable, however
short its timeout"). Still blocked on ADR 0014.

**Four taps is the finding, not the four failures.** The user was told
nothing, so they tried again three more times. The failure reaches an `E`
log line and the notification re-renders identical state, so a failed
claim looks exactly like never having tapped. Filed separately as #309
because it applies to *every* failure path — Bluetooth timeout, headset in
its case, relay rejection, cooldown — and unlike decision 2 it is not
blocked on anything.

**Also re-verified on 0.2.4:** the media-driven switch (Pixel→Mac at
19:51:02, release 25ms / claim 1089ms), last confirmed 2026-09-20.

**Arbitration pause (#290) — PASSES, both platforms, 2026-09-29, 0.2.5**

First hardware verification. Not a planned item: it was exercised because
Tom was travelling with a **different headset (Sony)**, which thrw does
not manage at all — `ProvisioningState` binds one `headsetIdentifier`, so
another headset is invisible to it. Pausing was the right answer to "stop
thrw doing anything while I use these", and verifying it was free.

- **Mac:** `defaults read app.thrw.mac` →
  `app.thrw.mac.arbitrationPaused = 1`.
- **Pixel:** the notification read *"Paused — not switching on this
  device"* with its action correctly flipped to *"Resume switching"*.

Worth recording that the Pixel's text and its own action **agreed** here.
That is the healthy counterpart to #308, where they contradicted each
other — same notification, same refresh path, and the difference is that
pause state is local and changes only when tapped, so it cannot go stale
the way a route reading can.

**Two things pause does not do**, both found while relying on it:

- It does not reveal or dislodge a **third node** holding the resource
  (#316). Pausing stops *this* node claiming; it says nothing about
  anyone else's claim.
- It makes #318's mute **permanent in practice**: the restore only ever
  happens on a later claim, and a paused node will never be claimed.

**Tooling**

`scripts/qa-capture.sh` was written during this pass and is what made the
correlation possible — one run directory holding the relay's decisions,
both adapters' logs, and timestamped marks for physical actions. Two
captures earlier in the week were lost outright (Swift `print`
block-buffering; an `adb logcat` ring overrun), and a finding you cannot
re-observe is not evidence. `scripts/relay-logs.sh --follow` was added
alongside it, because the relay could previously only be polled.

## Observation: an `event_end` with no matching start

During the call, the Pixel published `{"kind":"event_end","type":"voip"}`
for a `voip` event that had **no corresponding start** on the wire, and
which its own `activeEvents` never listed (both registrations either side
report `activeEvents: []`).

The likely cause is the self-cooldown: `AndroidNode.emitEvent` records
into `activeEvents` only when it actually publishes, so a *start*
suppressed inside the cooldown window can still be followed by an
unsuppressed *end*.

Harmless as observed — the relay's `endEvent` for a signal it never
recorded is a no-op, and `activeEvents` stayed consistent with what the
relay knew, so #178's reconciliation had nothing to correct. Recorded
because the asymmetry is real and could matter if end-handling ever gains
side effects.

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
