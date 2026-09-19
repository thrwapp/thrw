# ADR 0015: Typed resources — audio and HID share claim/release, not priority rules

## Status
Accepted

> **Numbering note.** This ADR was drafted as "0013" before 0013
> (connection state machine) and 0014 (`claimMode` capability) existed.
> It is 0015; the cross-references below have been renumbered to match
> the real ADR set. Nothing about the decision changed.

## Context
thrw currently manages one resource type: the audio connection to a
headset. Keyboard and mouse switching (HID peripherals) is a natural
extension, and unlike AirPods, most modern peripherals (Logitech
Bolt/Unifying, Apple Magic Keyboard/Trackpad) already support
multi-host pairing at the hardware/firmware level using a standard,
well-supported Bluetooth HID profile — no reverse engineering
equivalent to LibrePods' AirPods work is needed. HID connection
establishment is also faster than audio (HFP) because there is no
codec negotiation step.

However, audio and HID resources warrant different priority-rule
profiles even though the underlying claim/release mechanism is
identical. A phone call should claim a headset automatically; it has
no reason to claim a keyboard. Peripheral switching is a better fit
for focus-driven and manual-trigger switching (ADR 0016, ADR 0014)
than for the interrupt-driven rules (call/VoIP/media) that govern
audio.

## Decision
Introduce a typed "resource" concept in the node interface. A node can
register capability for one or more resource types (audio, hid) with
its manifest. Claim/release, cooldown, and conflict-detection
machinery (ADR 0010) apply identically across resource types. Priority
rule profiles are resource-type-specific and independently
configurable:

- audio: existing interrupt-driven stack — call > manual claim > VoIP
  > media > last-claimed (ADR 0002, ADR 0011's pre-claim)
- hid: focus-driven stack — ambient focus score (ADR 0016) > manual
  claim (shortcut or explicit trigger; see ADR 0014's `claimMode`). No
  interrupt-layer logic — a phone call has no bearing on which device
  should have the keyboard.

## Rationale
Sharing the claim/release/cooldown/conflict-detection machinery across
resource types avoids duplicating the hardest-won parts of the system
(the state machine, offline tolerance, manual-override detection) for
what is otherwise a similar mechanical problem. Separating priority
rule profiles per resource type avoids forcing an awkward unified
rule set where "a call is ringing" would have no sensible mapping onto
"should the keyboard switch."

## Consequences
The relay's priority engine must key its rule evaluation on
(account, resource_type), not just account. Each adapter's capability
manifest must declare which resource types it supports controlling
(a Linux desktop adapter might support hid but not audio if it has no
Bluetooth audio stack integration yet, for example). MQTT topics gain
a resource-type segment:

    thrw/{account}/nodes/{node}/{resource_type}/events
    thrw/{account}/commands/{node}/{resource_type}
    thrw/{account}/state/{resource_type}

This is a breaking change to the topic structure specified in ADR
0001 and must be applied before any adapter beyond the current
Mac/Pixel audio implementation is built, since retrofitting a resource
type segment into an already-deployed topic structure would require a
migration.

**Migration is not hypothetical.** As of this ADR the Mac and Pixel
adapters are running against the pre-0015 topics, authenticated to the
live relay, and have been verified end-to-end on real hardware. The
migration issue must cover `packages/protocol`'s topic builders,
`packages/relay-core`, `services/relay-hosted`, both adapters, and the
deployed relay — and the deployed `relay-service` and any running
adapter will be incompatible across the change, so it is a coordinated
cutover rather than a rolling one.
