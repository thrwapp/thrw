# ADR 0004: Native Swift/Kotlin/Rust per platform, not Electron or Tauri

## Status
Accepted

## Context
thrw's desktop presence (Mac, and later Linux) is a menu bar icon, a
keyboard shortcut, and a background process — there is close to no UI
surface. Electron and Tauri were both considered as ways to share more
code across desktop platforms.

## Decision
Native Swift for Mac/iPad (shared SwiftPM package), native Kotlin for
Android, native Rust for Linux. No Electron, no Tauri.

## Rationale
Electron makes sense when the UI is the product; thrw's Mac app has
almost no UI at all, so Electron's ~150MB footprint and 100-200MB
runtime memory would be pure overhead for an app that's supposed to
feel invisible. Electron also has no CoreBluetooth access from
JavaScript — a native Swift/Obj-C addon would still be required for
the one thing the app actually does, meaning Electron would add a
wrapper without removing any native code. It also complicates Mac App
Store review (extra sandboxing/entitlement scrutiny for Electron apps)
and breaks the shared-SwiftPM-package trick that makes adding iPad
support cheap.

Tauri (Rust-based) was a closer call — it would share code with the
Rust Linux adapter — but still needs native BT bindings per platform
via FFI, trading away Swift's first-class CoreBluetooth API for a
thinner justification than Electron's. For a menu-bar-only utility,
plain native Swift is both the simplest and the smallest option.

## Consequences
No shared UI code between Mac and Android — this is fine, since neither
platform has meaningful UI to share. iPad shares the Swift package with
Mac at the CoreBluetooth/business-logic layer, not the UI layer.
