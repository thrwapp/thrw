# ADR 0014: `claimMode` capability in the node manifest, for platforms with no programmatic Bluetooth control

## Status
Proposed

## Context
`packages/protocol`'s `NodeInterface` (`register`/`emitEvent`/`onClaim`/
`onRelease`) and the connection state machine (ADR 0013: idle ->
pre-claim -> claim -> active) both assume every registered node can
execute a claim — that calling `onClaim()` results in the adapter
actually taking the Bluetooth connection, the way `IOBluetoothDevice`
does on Mac or `BluetoothConnectionManager` does on Android.

#115/#123 found that assumption is false for iPad: no public iPadOS API
lets a third-party app force a classic-profile (BR/EDR) Bluetooth
connection. `AVAudioSession` only reorders already-connected routes or
falls back to the built-in speaker; `AVRoutePickerView` is user-tap-only;
`CoreBluetooth` is GATT-only and neither of its two classic-profile
escape hatches (GATT-over-classic, MFi + External Accessory) applies to
AirPods. `docs/spec/architecture.md`'s "iPad's Bluetooth audio-route
limitation (#115)" section has the full citations. The product fallback
it names — `adapter-ipad` observes the route and detects trigger events
like every other adapter, but can only prompt the user to switch
manually via Control Center — has no home in the current protocol.
Nothing in `NodeManifest` lets a node declare this, and nothing in the
relay or the state topic accounts for a claim that may never actually be
fulfilled by the node it was sent to.

This is a change to the node interface — a frozen contract per
AGENTS.md/ADR 0001/0010/0011 — so it needs an ADR and human review, not
a routine agent PR, even though it doesn't touch the MQTT topic
structure or add a state.

## Decision
1. Add a required `claimMode: "automatic" | "manual"` field to
   `NodeManifest`, alongside the existing `platform`/`supportedEventKinds`
   capability fields. No default — every adapter must declare it
   explicitly at registration.
2. `NodeInterface`'s method signatures are unchanged. `onClaim()`/
   `onRelease()` mean different things depending on `claimMode`:
   - `"automatic"` (Android, Mac, Linux): `onClaim()` opens the local
     Bluetooth connection; `onRelease()` closes it. Current behavior,
     unchanged.
   - `"manual"` (iPad, and any future platform in the same position):
     `onClaim()` surfaces a local prompt pointing the user at the OS's
     own route picker; `onRelease()` clears that prompt. No Bluetooth
     API is called.
3. The relay's priority engine and command publishing do not branch on
   `claimMode`. It always publishes CLAIM/RELEASE to whichever node the
   priority rules pick, exactly as today — decision logic stays
   platform-agnostic and server-side, execution stays adapter-local, per
   architecture.md's existing "priority rules... never duplicated in
   adapters" split. `packages/relay-core`'s `DeviceRegistry`/
   `PriorityEngine` need no logic changes for this ADR.
4. The retained state topic's `holder` continues to mean "who the relay
   decided should hold it," not "who is physically connected right now."
   That gap already exists transiently for automatic nodes during their
   own connect-in-progress window; this ADR just makes it a permanent,
   documented characteristic of manual-claim nodes instead of leaving it
   implicit.
5. No auto-revert or timeout for an ignored manual-claim prompt in v1.
   If the user never acts on it, the claim simply never reaches
   `active`; a subsequent priority event (another call, media starting
   elsewhere) supersedes it the same way it would for any other node.
   Explicitly deferred — a real product question, not one this ADR
   settles.

## Rationale
This extends a mechanism the architecture already commits to rather
than inventing a new one: "the relay... never assumes a platform's
capabilities — everything it knows about a node comes from that node's
capability manifest at registration time" (architecture.md, "System
components"). `claimMode` is exactly that kind of fact.

Keeping the four-state machine untouched matters for the same reason
ADR 0013 kept cooldown out of the state enum: `claimMode` is data other
nodes and the relay can read, not a fifth lifecycle stage, and
`onClaim`/`onRelease` are already documented as adapter-local behavior
hooks — giving them platform-dependent implementations is well within
the interface's existing contract, not a redesign of it.

Not branching relay-core on `claimMode` keeps the "decide vs execute"
split clean: the relay's job is picking a winner, never how that winner
takes possession, and that split shouldn't erode just because one
platform's "how" is a notification instead of a Bluetooth call.

## Consequences
- `NodeManifest` gains a new required field — a breaking type change.
  Acceptable pre-1.0 with no deployed users yet, but
  `packages/adapter-android` and `packages/adapter-mac`'s existing
  registration calls need a one-line update (`claimMode: "automatic"`)
  once this lands, or they fail to compile against the updated type.
- Unblocks a real `adapter-ipad` bootstrap issue for M4: `onClaim`/
  `onRelease` can now be scoped as "post a local notification" instead
  of left unspecified, per #123's own finding.
- Still open, deliberately not decided here: the actual UX of the
  manual-claim prompt on iPad (notification vs persistent banner vs
  widget) — a product-design question for the M4 `adapter-ipad` issue
  itself, not a protocol question this ADR needs to answer.
- Implementation touches `packages/protocol` (frozen contract) and is
  therefore human-merge, never a routine agent PR — same as this ADR.
