# ADR 0016: Ambient focus tracking as the default-holder layer

## Status
Accepted

> **Numbering note.** Drafted as "0014" before 0013/0014 existed. It is
> 0016; cross-references renumbered. The decision is unchanged.

## Context
The system as built handles event-driven switching: a call rings, media
starts playing, and a resource moves in response. This leaves an
unanswered question for any moment when no such event is firing: which
device should hold a given resource right now, by default? Currently
this falls through to "last-claimed node keeps it," which is a poor
proxy for actual user attention — it only reflects the most recent
explicit trigger, not where the user currently is. This matters
increasingly as resource types expand to peripherals (ADR 0015), where
there is no equivalent of "a call is ringing" to hang switching logic
on at all — peripheral switching needs a genuine attention signal, not
an event to react to.

## Decision
Each adapter computes a continuously-updated local "focus score"
(0.0-1.0, decaying over time since last positive signal) from signals
available on its platform without special hardware access:

- Active input events (keyboard/mouse/touch) — strongest available
  signal, debounced rather than published per-keystroke
- Foreground app / screen-on state
- Lid open/closed or screen lock state (where applicable)
- Bluetooth RSSI trend from the managed resource to this host
  (physical proximity, continuous, requires no app cooperation)
- Idle time since last input (absence signal)

Adapters publish a "focus state changed" event on a meaningful
transition (idle to active, active to idle) or at most every 5-10
seconds during sustained activity — never on every raw input event.
The relay maintains a per-account, per-resource-type "ambient holder"
derived from the highest current focus score across registered nodes,
and this ambient holder is the default when no interrupt-layer rule
(ADR 0002's audio stack) or manual claim is active. For the hid
resource type (ADR 0015), the ambient holder is normally the entire
priority mechanism, with manual claim as the only override.

## Rationale
Focus is a genuinely continuous, ambient property of user attention
that event-driven triggers only sample indirectly and after the fact —
by the time media starts playing on a device, the user has typically
already been using it for some time. Modeling focus explicitly, rather
than inferring it solely from lagging events, is what makes
peripheral switching (which has no equivalent to a ringing call)
possible at all, and improves audio switching by giving the
last-claimed fallback a much better signal to fall back to.

## Consequences
This is an architectural addition beneath the existing priority stack,
not a replacement for it — ADR 0002's interrupt rules and ADR 0011's
pre-claim mechanism are unchanged for audio; they simply now sit above
an ambient layer instead of above a bare "last-claimed" default. The
relay needs a new piece of state (current focus score per node, per
resource type, with a decay function) and a new topic:

    thrw/{account}/nodes/{node}/focus

Each adapter needs local signal-gathering code that is platform-
specific (input event hooks, screen-state APIs, RSSI reads) but
publishes a uniform 0.0-1.0 score regardless of platform, keeping the
relay's aggregation logic platform-agnostic. This is the same
extensibility pattern already used for the node interface generally.
Combining the individual signals into a single score per user is
explicitly the AI engine's job — see ADR 0017 — not a fixed formula
hardcoded per adapter, since the right weighting is genuinely
per-user.

**Permission cost, worth naming before implementation.** Input-event
monitoring is among the most heavily gated capabilities on both current
platforms: on macOS it requires Accessibility or Input Monitoring
permission, and on Android there is no general-purpose input hook for a
normal app at all. The signals list above is therefore a menu, not a
checklist — each adapter should use what it can obtain without asking
for intrusive permissions, and the per-user weighting (ADR 0017) is
what lets adapters with different available signals still produce a
comparable score.
