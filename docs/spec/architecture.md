# thrw — architecture

This is the reference architecture. The nightly evaluator agent checks
merged work against this document. Update it via PR when the architecture
genuinely changes; don't let it drift silently out of sync with the code.

## The problem

AirPods (and similar headsets) don't switch cleanly between devices outside
a single vendor's ecosystem. Apple's own iCloud-based switching only works
between Apple devices signed into the same Apple ID, and even then is
frequently reported as unreliable. Someone using a Mac and an Android phone
gets none of the automatic switching, ear detection handoff, or call
awareness that Apple's own devices get. Standard Bluetooth (including
multipoint and LE Audio's Auracast) does not solve this: multipoint handles
mechanical switching between two paired hosts but has no concept of "a call
just started, prioritize this device" — that decision logic doesn't exist
at the protocol level for any headset, and Apple specifically chose not to
implement open multipoint for AirPods at all, using a proprietary scheme
instead.

## What thrw is

A cross-device audio context layer. Each device (phone, laptop, tablet)
runs a lightweight adapter that knows two things: how to control the local
Bluetooth connection to the headset, and how to detect local "priority
events" (an incoming call, a VoIP app starting, media playback beginning).
Adapters talk to a small cloud relay over MQTT. The relay holds the
authoritative priority rules and tells adapters when to claim or release
the headset connection. Switching is sequential (disconnect from the
losing device, reconnect to the winning device) rather than true
simultaneous multipoint, because that's the only approach that works
without root access on Android as of Android 16 QPR3 / Android 17.

## Why sequential handoff, not dual-connection multipoint

LibrePods (open source, reverse-engineered the AirPods AAP protocol)
demonstrated that AirPods CAN hold two simultaneous connections if you
spoof the device's Bluetooth VendorID to appear as an Apple device. That
capability is real and impressive, but it requires root on every Android
version and OEM as of today — including Pixel and Android 17, where the
underlying L2CAP Bluetooth stack bug that historically forced root has
been fixed for basic AirPods control, but VendorID spoofing specifically
still needs root regardless.

Sequential handoff avoids this entirely: no VendorID spoofing, no root,
works on stock Pixel + Android 17 today. The cost is switching takes a
real few seconds rather than being instant, since it's a genuine
disconnect-then-reconnect rather than an instantaneous audio route
change — see Latency below for where that time actually goes. That's an
acceptable tradeoff for the addressable market size increase (everyone,
not just rooted users).

## Latency

Sequential handoff's mechanical cost breaks down roughly as follows:

- Trigger detection: 50-200ms
- MQTT relay round-trip: 100-400ms (worse on 3G)
- OS-level BT disconnect: 200-500ms
- Winning device BT connect + audio profile (HFP) negotiation:
  1-3 seconds — this is the dominant, physics-bound cost, not something
  the relay architecture can improve

Realistic end-to-end: **2-4 seconds typical**, not the earlier ~1.5s
figure.

The latency SLO referenced from ADR 0007 is revised accordingly: the
alert threshold moves from 2.5s to **3.5-4s p95**, and the marketed
target is "under 3s typical" rather than 1.5s. Flag: these revised
numbers still need validation against real hardware timing (the Day 6-9
AirPods test) before being treated as fact anywhere else, including
marketing copy.

## Positioning

thrw should not be marketed as faster than Apple's native switching —
Apple's own switching does a comparable real BT reconnect under the
hood, just masked by tighter OS integration and an animation. thrw's
honest advantage is working reliably across ecosystems where Apple's
doesn't apply, plus the pre-claim mechanism (ADR 0011), which can make
it *feel* faster in the specific case of phone calls even though raw
mechanical latency is similar or worse.

## Why Sony/Nothing headphones are architecturally simpler than AirPods

Sony (WH-1000X series) and Nothing earbuds support standard Bluetooth
Multipoint natively — no reverse engineering needed. Their adapters in
thrw don't need anything like LibrePods' AAP protocol work; the relay
just needs to send a disconnect signal to the losing host and the
headphones reconnect to the winning host using their own built-in
multipoint logic. This makes Sony/Nothing a good "second adapter" to
build after AirPods, since most of the hard protocol work doesn't apply
to them at all.

## System components

- **Adapters** (packages/adapter-android, adapter-mac, adapter-ipad,
  adapter-linux): platform-specific code implementing a shared "node
  interface" — register(manifest), emit_event(type, priority),
  on_claim(), on_release(). Each adapter wraps the local Bluetooth API
  (LibrePods on Android, IOBluetooth on Mac — classic Bluetooth, since
  CoreBluetooth is BLE-only and can't move the audio route, see #101 —
  **no framework can move it on iPad at all**, see "iPad's Bluetooth
  audio-route limitation" below and #115, BlueZ on Linux) and
  the local trigger APIs (TelephonyManager + NotificationListener on
  Android, **process watching only on Mac — `AVAudioSession` is an
  iOS/tvOS/watchOS framework and doesn't exist on macOS at all, see
  "Mac's trigger-detection gap" below and #127**, CallKit on iPad,
  PulseAudio + D-Bus on Linux).

- **Relay** (packages/relay-core, deployed via services/relay-hosted):
  an MQTT broker (EMQX) holding the priority rules engine and device
  registry. Never assumes a platform's capabilities — everything it
  knows about a node comes from that node's capability manifest at
  registration time. This is the extensibility mechanism: adding a new
  platform means writing a new adapter, not changing the relay.

- **Licensing** (services/licensing): self-hosted Keygen CE, handles
  per-device activation limits (Free=1, Pro=3, Teams=pooled), offline
  validation caching so it still works on a spotty mobile connection,
  and per-device revocation.

- **Billing** (services/billing): Stripe for subscriptions, decoupled
  from licensing via a webhook bridge — Stripe subscription lifecycle
  events (created/updated/deleted) trigger Keygen API calls
  (create license / update policy / revoke).

## Mac's trigger-detection gap (#127)

Found while building `packages/adapter-mac`'s trigger detection, the
same class of premise error #101 found at the Bluetooth-framework layer:
this section previously listed `AVAudioSession` as one of Mac's trigger
APIs. **`AVAudioSession` doesn't exist on macOS** — it's an iOS/tvOS/
watchOS-only framework, confirmed against Apple's own documentation and
developer forums. macOS's real audio-route API is Core Audio
(`kAudioHardwarePropertyDefaultOutputDevice`), and even that only
reports *what* the current output device is, not *why* it changed —
there's no "a call/VoIP session started" semantic to key off the way
iOS's route-change-reason enum has, so it isn't used as a trigger signal
in `adapter-mac` at all.

The practical consequence is a real, permanent-for-now product gap, not
a temporary implementation shortfall: **Mac has no way to detect
architecture.md's rule 1 ("incoming/outgoing phone call — always
wins")**. Macs don't take cellular calls, and there is no public API for
a third-party app to observe FaceTime's or any other app's call state.
(CallKit has only just begun shipping on macOS, in beta, as of very
recent Xcode 26.x releases — a single incremental `CXProvider` method as
of this research, nowhere near a documented, stable surface worth
building a production feature on; worth revisiting once/if that
matures.) `packages/adapter-mac` can only detect rule 3 (VoIP session
started), via process watching (`NSWorkspace`'s app-launch/termination
notifications) against a set of known VoIP app bundle identifiers — and
even that is cruder than `adapter-android`'s own notification-property-
based heuristic, since macOS exposes no public API for "is this app
actually in a call right now," only "is it running." Full heuristic and
its known limitations documented in
`packages/adapter-mac/Sources/AdapterMac/Triggers/VoipTriggerMonitor.swift`'s
own kdoc.

## iPad's Bluetooth audio-route limitation (#115)

Researched before any `adapter-ipad` bootstrap work, specifically to
avoid repeating #101's mistake at the platform level instead of the
framework level: #101 corrected Mac's line above from CoreBluetooth to
IOBluetooth because CoreBluetooth is BLE-only and can't move a classic-
profile audio connection. iPadOS has no IOBluetooth equivalent — no
public framework of any kind gives a third-party app classic-Bluetooth
(BR/EDR) connection control. This is a real platform ceiling, not an
implementation gap `adapter-ipad` can code its way around.

**What was checked:**

- `AVAudioSession`'s route APIs (`currentRoute`, `availableInputs`,
  `preferredInput`, `overrideOutputAudioPort`) let an app *observe* the
  active route and choose among *already-connected* inputs, or force a
  fallback to the built-in speaker/mic. None of them initiate a new
  Bluetooth connection to a specific paired-but-not-connected device —
  the OS alone decides which Bluetooth profile is active, and multiple
  Apple Developer Forums threads report `preferredInput`/
  `overrideOutputAudioPort` not reliably even reordering
  *already-connected* routes on recent iOS versions ("AVAudioSession,
  setPrefferedInput and switching between multiple Bluetooth Devices",
  https://developer.apple.com/forums/thread/62954).
- `AVRoutePickerView` (the modern replacement for `MPVolumeView`'s route
  button) only presents the system's own route-picker UI for the *user*
  to tap — there is no programmatic way to drive a selection through it
  without user interaction.
- `CoreBluetooth` is GATT-only. An Apple DTS engineer's answer on the
  Developer Forums is the clearest single citation: "iOS apps can do
  Bluetooth Classic (aka BR/EDR), but there are some limitations. If
  your device can support GATT over Bluetooth Classic, then you can use
  CoreBluetooth. Otherwise, to connect and communicate with a Bluetooth
  Classic device over something like the Serial Port profile, you need
  to join the MFi Program after which you can use the External
  Accessory framework to do the job."
  (https://developer.apple.com/forums/thread/769197). AirPods' audio
  path is a system-managed classic A2DP/HFP connection, not a
  GATT-over-classic service, and AirPods aren't a third-party MFi
  accessory an app can register against — so neither of the DTS
  engineer's two escape hatches applies here. (iOS 13 quietly added an
  undocumented "BR/EDR Transport Bridging Key" that can bridge some
  classic profiles through a CoreBluetooth LE proximity relationship —
  forum thread https://developer.apple.com/forums/thread/122732 — but
  Apple has published no documentation for it, and nothing here should
  be built on an undocumented mechanism.)
- Apple's own AirPods-to-AirPods automatic switching (the behavior thrw
  is trying to approximate cross-ecosystem, per "Positioning" above)
  works via private iCloud/Apple-ID-linked signaling over the H1/H2
  chip, not any public API — it is not a capability third-party apps
  can invoke or replicate.

**Conclusion**: no public iPadOS API lets a third-party app force which
device a classic-profile Bluetooth audio accessory is connected to.
`adapter-ipad` can *observe* the current audio route
(`AVAudioSession.routeChangeNotification`/`currentRoute`) and detect
thrw's own priority-trigger events (call start, VoIP start) exactly like
the other adapters, but it cannot execute the `on_claim`/`on_release`
side of the node interface automatically. The M4 product fallback is
prompting the user to switch manually — e.g. a local notification or UI
state pointing at Control Center's audio route picker when thrw's relay
decides the iPad should hold the claim — rather than the automatic
handoff Android/Mac/Linux achieve. This is a real product-scope
narrowing for the iPad adapter, not just a technical footnote: M4's
acceptance criteria need to be written against "prompt and observe,"
never against "connect and disconnect."

Reference hardware for iPad is still unspecified (see "Reference
hardware" below) — unaffected by this finding, but worth remembering as
a separate, still-open gap.

## Connection state machine

Every adapter's node interface must support the same states for a
managed headset:

    idle -> pre-claim (speculative) -> claim (confirmed) -> active

with a path from pre-claim back to release if the predicted trigger
doesn't materialize (e.g. a ringing call is declined). See ADR 0010
(conflict detection and cooldown) and ADR 0011 (predictive pre-claim)
for the full rationale — this state machine, once implemented, is a
frozen contract in the same way the MQTT topic structure is (AGENTS.md).

This is exactly four states — no fifth "cooldown" state. ADR 0010's
self-cooldown suppression window is adapter-local implementation
detail layered around `onClaim`/`onRelease`, not a value in this enum;
see ADR 0013 for the full reconciliation.

## MQTT topic design

    thrw/{account}/nodes/{node}/{resource}/events   node publishes, QoS 1
    thrw/{account}/commands/{node}/{resource}      relay publishes, QoS 1
    thrw/{account}/state/{resource}                retained — current holder
    thrw/{account}/nodes/{node}/heartbeat          QoS 0, ~30s

`{resource}` is ADR 0015's resource type — `audio` today, `hid` when
peripheral switching exists (#171). Heartbeat deliberately has no such
segment: liveness is a property of the node, not of anything it manages,
and a per-resource heartbeat would multiply traffic for no extra signal.

These strings are pinned in `packages/protocol/fixtures/topics.json`,
which all three topic-builder implementations — TypeScript, Swift and
Kotlin — assert against. They are hand-written mirrors of one another,
and before that fixture existed nothing would have caught them drifting
apart except a node going silent on real hardware.

Account-scoped prefixes give multi-tenant isolation at the broker ACL
level. Claim/release use QoS 1 (duplicates tolerable, missed events are
not). The state topic is retained so a reconnecting node (phone regains
signal, laptop wakes up) immediately knows who currently holds the
connection without waiting for the next event — this is what makes
recovery from a mobile network dropout work smoothly.

Two things about the state topic are worth stating here rather than
leaving to the implementation (#222):

- **It reports the holder rule, not an intuition about it.** When the
  last trigger ends, the holder does *not* become nobody — the last
  claimer keeps the resource until something outranks it or the node is
  forgotten (rule 5 below). `holder: null` means the resource is
  genuinely free, which in practice means the holder went silent and was
  swept. That is different again from the topic being *empty*, which
  means nobody has told you anything yet.
- **A retained message outlives the relay process that wrote it**, and
  the relay holds its state in memory. So the relay republishes the
  holder on the first registration it sees after starting, overwriting
  whatever a previous process left behind, even when the value is
  unchanged. Without that, a relay restarting during a quiet period
  would leave a confident and wrong answer standing indefinitely. Priority rules
live server-side in the relay, never duplicated in adapters, so two
adapters can never disagree about the current rule version after a
partial rollout.

## Resource types

thrw manages **typed resources**, not just audio (ADR 0015). Two exist:

- **`audio`** — the headset connection. Governed by the interrupt-driven
  priority rules below (call > manual claim > VoIP > media >
  last-claimed).
- **`hid`** — keyboard/mouse peripherals. Governed by the focus-driven
  stack instead: ambient focus score (ADR 0016) > manual claim. No
  interrupt-layer logic, because "a call is ringing" has no sensible
  bearing on which device should have the keyboard.

The claim/release, cooldown and conflict-detection machinery (ADR 0010)
is identical across resource types; only the priority-rule *profile*
differs. Each adapter's manifest declares which resource types it can
control — a Linux desktop adapter might support `hid` but not `audio`.

Unlike AirPods, most modern peripherals (Logitech Bolt/Unifying, Apple
Magic Keyboard/Trackpad) already support multi-host pairing in firmware
over a standard Bluetooth HID profile, so `hid` needs no reverse
engineering. HID also connects faster than audio, having no codec
negotiation step.

### ⚠️ Breaking change to the topic structure

ADR 0015 adds a resource-type segment to the topics frozen by ADR 0001:

    thrw/{account}/nodes/{node}/{resource_type}/events
    thrw/{account}/commands/{node}/{resource_type}
    thrw/{account}/state/{resource_type}

**This is not yet implemented, and the running system predates it.** The
Mac and Pixel adapters are deployed against the pre-0015 topics
documented under "MQTT topic design" above. Old and new structures are
mutually incompatible, so `packages/protocol`, `packages/relay-core`,
`services/relay-hosted`, both adapters and the deployed relay change
together.

With **no customers and two devices**, that is a flag day, not a
project: update, redeploy, reinstall. No compatibility window or staged
rollout is needed. It should be done before more adapters exist to
migrate — which is the actual reason to do it early.

## Focus tracking

Beneath the interrupt-driven priority rules sits an **ambient layer**
(ADR 0016). Each adapter computes a local focus score (0.0–1.0, decaying
since the last positive signal) from whatever attention signals its
platform exposes — input activity, foreground app, screen/lid state,
Bluetooth RSSI trend, idle time — and publishes it on:

    thrw/{account}/nodes/{node}/focus

Adapters publish on meaningful transitions (idle↔active) or at most
every 5–10 seconds during sustained activity, never per keystroke.

The relay derives a per-account, per-resource-type **ambient holder**
from the highest current score, and uses it as the default when no
interrupt rule or manual claim applies. This *replaces* "last-claimed
node keeps it" as the fallback with a signal that actually reflects
where the user is. For `hid` it is normally the entire mechanism.

This sits beneath the existing stack rather than replacing it: ADR
0002's interrupt rules and ADR 0011's pre-claim are unchanged for audio.

## AI scope

AI is deliberately split three ways (ADR 0017), because "add AI" spans
problems with very different latency and reliability needs:

1. **Focus-score calibration** — combining each adapter's raw signal
   vector into one score. A small per-user classifier (logistic
   regression / small decision tree), retrained periodically in
   `services/ai-engine`. **Explicitly not an LLM**: it must evaluate in
   milliseconds with no network variance.
2. **Pre-claim confidence** — learning per user which early signals
   reliably precede a real switch, extending ADR 0011 beyond its
   conservative ringing-call-only scope. Same technique, same locality
   constraint.
3. **Explanation and recommendation** — in-app insights and ADR 0012's
   misconfiguration advice. This *is* LLM work: not latency-sensitive,
   and language quality is the point. Routed via Vertex per ADR 0008,
   Sonnet-tier.

The switching decision itself must be fast, debuggable and
offline-capable — none of which an LLM call provides. The classifier
should be invisible and simply correct; the insights surface is where
the intelligence becomes visible.

Both classifier roles depend on per-user history, so
`services/telemetry` (M8) must exist as a collection path first —
though dogfooding can generate real switch events quickly, so this is a
build-it constraint rather than a wait-for-it one. The heuristic
fallback is still the first thing to build: it is what every new user
runs until they have their own history, so it stays on the critical
path permanently.

## Priority rules (current, server-side, editable without redeploying
adapters)

    1. incoming / outgoing phone call     — always wins
    2. manual claim                       — instant, overrides below
    3. VoIP session started on any node   — Zoom/Meet/Teams/WhatsApp
    4. media started on any node
    5. last-claimed node keeps it

    auto-return: call_ended -> return to previous holder after a learned
    timeout (AI engine sets this per-user; default 90s)

## Reference hardware

- **Headset**: AirPods Pro 2, Lightning case (H2 chip).
- **Android phone**: Pixel 10 Pro.
- **Mac**: MacBook Air 13-inch, M4, 2025.
- **iPad**: not yet specified — needed before the iPad adapter issue
  (M4, lower priority than M3) can cite real API versions.

This grounds M3 (Android + Mac adapter pair) fully — issues can now
cite exact device models. Exact OS versions (Android build number,
macOS version) aren't pinned here since they'll drift with each
device's own update cycle; an M3 issue should have its implementer
note the OS version actually running on the reference device at
implementation time rather than hardcoding one here.
