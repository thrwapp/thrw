package com.thrw.adapter.android.audio

/**
 * Silences this device's audio across a handover window (ADR 0022).
 *
 * ## Why this exists
 *
 * A handover takes roughly 4.9s on the reference hardware, and for ~2.7s
 * of it *no device holds the headset* - the old host has released and
 * the new one has not finished connecting (#254, measured). Anything
 * playing during that window comes out of the built-in speakers, which
 * is the most viscerally bad thing the product does: a wrong switch is
 * an inconvenience, audio unexpectedly playing out loud in a shared
 * space is not.
 *
 * ADR 0002's sequential handoff makes the gap unavoidable. This governs
 * what happens to audio inside it.
 *
 * ## The two calls are not symmetric
 *
 * - **On release**: [silence] only. The user has moved to another
 *   device; continuing to play here is never what they wanted. This
 *   mirrors `AUDIO_BECOMING_NOISY`, which is what the platform itself
 *   does when headphones are unplugged - thrw removing the headset is
 *   the same event from an app's point of view.
 * - **On claim**: [silence] then [restore] once the command resolves.
 *   Brief silence followed by audio in your ears beats five seconds
 *   through a phone speaker, and nothing is lost - playback resumes
 *   where it stopped.
 *
 * [restore] must run on **every** terminal outcome, not only success.
 * ADR 0019 gives exactly three - succeeded, failed, timed_out - and a
 * user left silenced because a claim failed would be a worse bug than
 * the one this fixes.
 */
interface HandoverAudioGate {
    /**
     * Silences audio on this device.
     *
     * Implementations must be safe to call when nothing is playing, and
     * safe to call twice - the command loop makes no guarantee about
     * ordering across overlapping commands.
     */
    suspend fun silence()

    /**
     * Undoes [silence].
     *
     * Must be safe to call without a preceding [silence], and must not
     * start audio that was not playing beforehand. Resuming something
     * the user had deliberately paused would be worse than the leak
     * this whole mechanism exists to prevent.
     */
    suspend fun restore()
}

/**
 * The gate used when none is supplied - does nothing.
 *
 * Deliberately a no-op rather than a failure: a node built without a
 * gate should behave exactly as it did before ADR 0022, leaking audio
 * across the window as it always has, rather than refusing to hand over
 * at all.
 */
object NoOpHandoverAudioGate : HandoverAudioGate {
    override suspend fun silence() = Unit
    override suspend fun restore() = Unit
}
