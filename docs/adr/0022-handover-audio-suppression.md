# ADR 0022: Pause playback across the handover window, rather than letting it leak to the speakers

## Status
Accepted — amended 2026-09-23 (macOS mutes for now), and amended again
2026-09-24 (**that divergence is closed: macOS pauses**). The second
amendment supersedes the first; read them in order, because the first
records reasoning that turned out to rest on a mismeasurement.

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

## Amendment (2026-09-23): the macOS spike ran, and macOS mutes for now

The spike this ADR's Consequences called for has been done, on the
reference Mac. Three findings, and they change the macOS half.

**1. Pausing on macOS works — with Accessibility.** Synthesising
`NX_KEYTYPE_PLAY` through `CGEvent` had no effect from an untrusted
process (YouTube kept playing). With Terminal granted Accessibility,
`AXIsProcessTrusted()` returned true and the same post paused playback
immediately. The mechanism is real; its cost is the permission that lets
an application control the whole computer.

**2. Media keys are a toggle, not a pause.** There is no distinct pause
keycode — `NX_KEYTYPE_PLAY` flips whatever the current state is. On
release, where this ADR wants "pause", toggling a device whose media is
*already* paused would start it playing, on a device thrw has just taken
the headset from. Exactly backwards. Any media-key implementation must
gate on a separate read of whether audio is actually flowing.

**3. The Accessibility grant would not survive an update.** The macOS
app is ad-hoc signed today (`Signature=adhoc`, `TeamIdentifier=not
set`). macOS TCC keys a grant to the code signature, falling back to the
cdhash for an ad-hoc binary — and that changes on every build. "Grant
Accessibility once" would in practice be "re-grant after every update",
which is worse than the problem this ADR exists to fix. Proper Developer
ID signing (#132, in progress) is the unblock.

### Revised decision for macOS

**macOS mutes and restores; Android pauses and resumes.** The behaviour
this ADR specifies — suppress audio across the window, resume on the
claiming side when the outcome resolves — is unchanged. Only the
mechanism differs per platform:

- **Android**: `MediaController.transportControls.pause()` / `.play()`,
  through controllers the adapter already holds for trigger detection.
  No new permission, explicit rather than a toggle.
- **macOS**: set the default output device's volume to zero and restore
  it. Public CoreAudio, no TCC grant of any kind, no toggle ambiguity.

**This is explicitly temporary.** Pausing remains the target on macOS
too, for the reasons the original decision gives — no content is lost,
and a stuck pause is visible where a stuck mute is mysterious. It is
blocked on #132 and should be revisited the moment the app is Developer
ID signed.

The original Rationale argued against muting on failure mode, and that
argument still stands rather than having been abandoned. It is mitigated,
not answered: the pre-mute volume is persisted, restored in a `defer`,
**and** restored again at adapter startup, so a crash inside the window
self-heals on next launch instead of leaving someone silently muted with
no explanation. That mitigation is a requirement of this amendment, not
an optional extra — without it, muting is the wrong trade.

### What this costs, stated plainly

For as long as macOS mutes, a handover loses roughly 2.7 seconds of
content on that device rather than pausing over it, and the two platforms
behave differently in a way a user could notice. Both are accepted
deliberately, in exchange for shipping the fix now and asking for no new
permissions, and both end when #132 does.

## Amendment (2026-09-24): macOS pauses; the divergence is closed

The amendment above lasted one day. v0.2.0 reached the reference
hardware, and muting failed on two of its three paths — not on
aesthetics, on measurement.

**1. The reference headset has no volume to set.** Probing CoreAudio
directly (#282):

```
Tom's AirPods Pro #2: volume=UNREADABLE(main element) settable=false  <-- DEFAULT
MacBook Air Speakers: volume=0.250 settable=true
```

On the **release** path the headset is still the default output, so
there was never anything for the muting gate to write to. That path has
not worked since it shipped.

This also corrects the record: the spike's `0.25 / settable: true`
reading, offered in the amendment above as evidence the mechanism
worked, was **the built-in speakers**, measured while the headset was
connected elsewhere, and attributed to the headset. The prior amendment's
"macOS: set the default output device's volume to zero" rests on that
mistake.

**2. The claim path leaks before it can start.** Audio begins when the
user presses play; the claim command arrives roughly a second later, and
suppression only begins then. Reported from real use: *"when I play
YouTube it still plays out loud temporarily."*

**3. Muting one device and restoring another.** Resolving "the default
output device" separately at mute and restore time meant a claim muted
the speakers and then restored the *headset*, leaving the speakers at
zero with the record consumed — the exact failure the prior amendment
made a requirement to prevent. Fixed in #283 by keying the record on a
stable device UID, but it is evidence about the mechanism: muting has a
device-identity problem that pausing does not have at all.

### Revised decision

**Both platforms pause.** The original decision stands as written, with
no per-platform mechanism split:

- **Android**: `MediaController.transportControls.pause()` / `.play()`.
- **macOS**: `NX_KEYTYPE_PLAY` via `CGEvent`, gated on a separate read of
  `kAudioDevicePropertyDeviceIsRunningSomewhere` — finding 2 of the
  previous amendment, honoured. The key is never fired blind: it is
  pressed only when audio is actually flowing, and only un-pressed by
  the gate that pressed it.

**The Accessibility cost is accepted rather than avoided.** Finding 3 of
the previous amendment is still true — the app is ad-hoc signed, so the
grant dies on every build and must be re-given after each update until
#132 lands. That was judged worse than the problem; it is not, now that
the alternative is known to fail on two paths. A Mac without the grant
falls back to muting, so it is never worse than v0.2.0.

**The mitigation the previous amendment demanded is no longer needed.**
Persisting the pre-mute volume, restoring in a `defer`, and restoring
again at startup existed because a mute that is never undone is
invisible and unrecoverable. A pause is self-evident: the user sees a
paused player and presses play. That the entire recovery apparatus
becomes unnecessary is the clearest evidence pausing was the right
mechanism throughout. It is retained only for the muting fallback, and
for healing records left behind by v0.2.0.

### What this costs, stated plainly

An Accessibility grant that must be re-given after every update until
#132. In exchange the two platforms behave identically, no content is
lost on either, and a suppression that fails leaves something the user
can see and fix rather than silence with no cause.

Implemented in #267/#285. The original Rationale's argument against
muting is no longer merely "still standing" — it has been confirmed by
the failure modes above.
