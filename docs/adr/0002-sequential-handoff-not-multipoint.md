# ADR 0002: Sequential handoff, not dual-connection multipoint, for AirPods

## Status
Accepted

## Context
LibrePods demonstrated that AirPods can hold two simultaneous
connections (true multipoint-like behavior) by spoofing the Bluetooth
VendorID to appear as an Apple device ("act as Apple device" mode).
This is technically impressive and would allow near-instant switching
with no disconnect/reconnect cycle.

## Decision
thrw uses sequential handoff (disconnect the losing device, reconnect
the winning device) rather than dual-connection spoofing.

## Rationale
VendorID spoofing requires root on Android, on every version and OEM,
with no exception — this is different from the general AirPods root
requirement, which Android 16 QPR3 and Android 17 fixed for basic
control (battery, ear detection, ANC) on Pixel and some OEMs. Root is
an explicit deal-breaker for the target user base. Sequential handoff
achieves the core goal — headphones follow you to the device that needs
them — without requiring root anywhere, at the cost of roughly 1-2
seconds of switching latency instead of near-instant.

## Consequences
Switching is not instantaneous; user-facing copy and the 2.5s latency
SLO (ADR 0006) are calibrated around this ~1.5s target, not true
zero-latency multipoint. If Android's root requirements loosen further
across all OEMs (not just Pixel), dual-connection could become viable
as an opt-in "fast mode" in a future version — revisit this ADR if that
happens.
