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
works on stock Pixel + Android 17 today. The cost is switching takes
roughly 1-2 seconds rather than being instant, since it's a real
disconnect-then-reconnect rather than an instantaneous audio route change.
That's an acceptable tradeoff for the addressable market size increase
(everyone, not just rooted users).

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
  (LibrePods on Android, CoreBluetooth on Mac/iPad, BlueZ on Linux) and
  the local trigger APIs (TelephonyManager + NotificationListener on
  Android, AVAudioSession + process watching on Mac, CallKit on iPad,
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

## MQTT topic design

    thrw/{account}/nodes/{node}/events      node publishes, QoS 1
    thrw/{account}/commands/{node}          relay publishes, QoS 1
    thrw/{account}/state                    retained — current holder
    thrw/{account}/nodes/{node}/heartbeat   QoS 0, ~30s

Account-scoped prefixes give multi-tenant isolation at the broker ACL
level. Claim/release use QoS 1 (duplicates tolerable, missed events are
not). The state topic is retained so a reconnecting node (phone regains
signal, laptop wakes up) immediately knows who currently holds the
connection without waiting for the next event — this is what makes
recovery from a mobile network dropout work smoothly. Priority rules
live server-side in the relay, never duplicated in adapters, so two
adapters can never disagree about the current rule version after a
partial rollout.

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

[Cowork: leave this section for Tom to fill in with his exact AirPods
generation, Pixel model, and Android version once confirmed — this
grounds hardware-specific issues written later.]
