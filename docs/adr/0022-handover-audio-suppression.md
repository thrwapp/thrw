# ADR 0022: Pause playback across the handover window, rather than letting it leak to the speakers

## Status
Accepted

## Context
A handover takes roughly five seconds on the reference hardware, and for
part of it **no device holds the headset**. Anything playing during that
window comes out of the built-in speakers.

Measured on v0.1.5 (#254), with both adapters reporting ADR 0019
outcomes:

```
11:10:39  holder_change  MAC -> PIXEL
11:10:41  MAC release    dur: 2197ms    (started ~11:10:39)
11:10:44  PIXEL claim    dur: 4853ms    (started ~11:10:39)
```

The release and the claim run in parallel, both starting at the holder
change. So the Mac has let go at ~2.2s and the Pixel does not have it
until ~4.9s: **~2.7 seconds with the headset attached to nothing.**

ADR 0002 chose sequential handoff over multipoint, so some gap is
unavoidable — the old host must release before the new one can take it.
This ADR is about what happens to audio inside that gap, not about
removing the gap.

**The window cannot usefully be shrunk.** That was the first instinct
when #254 was filed, on the theory that ten seconds of observed gap was
mostly avoidable sequencing. Measurement killed it: relay decision to
command delivery is under a second, the two Bluetooth operations already
overlap, and the long pole is Android's own A2DP connect at ~4.9s. There
is no slack to reclaim.

Two sub-cases, and they are not symmetric:

- **The releasing device** was playing, loses the headset, and keeps
  playing to its own speakers. This is the worse one: the user has
  walked away from that device, and it starts broadcasting.
- **The claiming device** has just started playback — that is the trigger
  — and the headset is not attached yet, so the opening seconds come out
  of its speaker.

## Decision
**Pause playback for the duration of the window, and resume on the
claiming device when the claim resolves.**

1. **On release: pause, and do not resume.** The user has moved to
   another device; continuing to play here is never what they wanted.
   This deliberately mirrors the platform convention users already
   understand — Android's `AUDIO_BECOMING_NOISY`, and the equivalent
   behaviour on iOS and macOS, all pause media when headphones are
   removed. thrw removing the headset is the same event from the
   application's point of view, so behaving the same way is the least
   surprising thing available.

2. **On claim: pause immediately, resume when the command outcome
   resolves.** A brief silence followed by audio in your ears is a
   better experience than five seconds through a phone speaker, and no
   content is lost — playback resumes where it paused rather than having
   played on inaudibly.

3. **Resume on every terminal outcome**, not only success. ADR 0019
   gives exactly three: `succeeded`, `failed`, `timed_out`. All three
   resume. A user left paused because a claim failed would be a worse
   bug than the one this ADR fixes, and the 8s bound guarantees one of
   the three arrives.

## Rationale

**Why pause rather than mute.** Muting the output is less invasive in
principle and is easier to implement on macOS, where no public API
pauses another application's media. It was rejected on failure mode: a
stuck pause is visible and a user fixes it by pressing play, whereas a
stuck mute is mysterious — audio appears to be playing and nothing comes
out — and system output volume affects notifications and every other
app, not just the media thrw is managing. Given the whole of #236, #244,
#247, #251 and #257 were silent failures whose cost was that nobody
could tell what had gone wrong, choosing the option whose failure mode is
self-evident is worth more than the implementation convenience.

Muting also loses content: playback continues silently, so the user
misses the first few seconds. Pausing does not.

**Why not pre-claim (ADR 0021) instead.** Pre-claim removes the window
entirely for the claiming device, by connecting before playback starts —
and this has already been observed happening by accident, when opening
Spotify on the phone moved the connection before play was pressed. But it
is speculative and will not always fire, and it does nothing at all for
the releasing device, which is the worse sub-case. The two are
complementary: pre-claim reduces how often the window is entered with
audio playing, and this ADR governs what happens when it is entered
anyway.

**Why not accept it.** It is the most viscerally bad thing the product
does — a wrong switch is an inconvenience, audio unexpectedly playing
out loud in a shared space is not.

## Consequences
- **Android has a clean mechanism; macOS does not.** The Android adapter
  already holds `MediaController` instances through the notification
  listener it uses for trigger detection, so `transportControls.pause()`
  and `.play()` are directly available with no new permission. macOS
  exposes no public API for pausing another application's media;
  synthesising media-key events through `CGEventPost` is the known
  route and its reliability is unverified. **The macOS half needs a
  spike before it is committed to**, and this ADR should be revisited if
  that spike fails — muting may be the only workable answer there, in
  which case the platforms will differ and that divergence must be
  documented rather than hidden.
- Implementation lands per-adapter and does not touch `packages/protocol`
  or the relay. It is behaviour local to a node executing a command it
  has already been given.
- ADR 0019's confirmed outcomes are a hard dependency: without a
  guaranteed terminal signal there is nothing safe to resume on. That
  work is complete as of #206/#255.
- ADR 0007's latency SLO becomes more directly user-visible: the window
  is now silence rather than noise, so a slower switch means a longer
  gap before audio starts. The measured 4.9s already exceeds the
  3.5-4s p95 the ADR sets, which is worth revisiting on its own terms.
- Deliberately not decided here: whether to pause *all* media on the
  device or only the session that triggered the claim. The reference
  hardware has one media session at a time, so the distinction has not
  been exercised, and guessing at it now would be inventing a
  requirement.
