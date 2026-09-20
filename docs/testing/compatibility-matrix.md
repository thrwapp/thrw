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
| AirPods Pro 2 (Lightning case, H2) | MacBook Air 13" M4 (2025) | Pixel 10 Pro | pending ADR 0019 telemetry | not yet verified end-to-end against the live relay | adapters have only ever been run against local/anonymous brokers; #147 (no MQTT credentials) blocks production connection | — |

Hardware models are the reference devices from
docs/spec/architecture.md. The "not yet verified" status is per
docs/roadmap.md's 2026-09-18 snapshot — **fill in a real date and
outcome after the first live-relay switch on this pairing**, rather
than back-filling it from the fact that the code exists.

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
