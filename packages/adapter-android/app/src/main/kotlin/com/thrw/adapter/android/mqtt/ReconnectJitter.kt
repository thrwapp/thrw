package com.thrw.adapter.android.mqtt

import kotlinx.coroutines.delay
import kotlin.random.Random

/**
 * ADR 0020's reconnect jitter: a short random wait before a reconnected
 * node reports itself back to the relay (#277, decision 3).
 *
 * ## What it is for
 *
 * The event most likely to drop every node's connection at the same
 * instant is a relay restart - a deploy, a broker crash, an EMQX
 * rollout. That is also precisely the event that *synchronises* every
 * node's reconnect, so without a spread every node re-registers in the
 * same tick, into a relay that has just come up holding no state at all
 * and is rebuilding its whole picture of the system from those very
 * messages. Spreading them costs nothing and removes the pile-on.
 *
 * ## What it deliberately does not delay
 *
 * Only the re-registration/reconciliation report
 * ([MqttTransport.onReconnected]). Restoring subscriptions is **not**
 * delayed - a node whose SUBSCRIBE has not been re-sent is deaf to
 * claim and release, which is the #182 failure this whole path exists
 * to prevent, and widening that window to save the relay some load
 * would be a bad trade. Neither is publishing: the manual override path
 * (`ManualClaim.toggle` -> `AndroidNode.emitEvent` ->
 * [MqttTransport.publish]) never touches this class, because a user
 * pressing the button must never wait out a random delay.
 *
 * ## Relationship to `adapter-mac`
 *
 * `MQTTNIOTransport.swift`'s `reconnectLoop` is the same behaviour on
 * the other side of the same ADR, with the same 0-2000ms range - change
 * both together. It differs in *where* the wait sits, for a reason that
 * is a property of the two MQTT libraries rather than a design choice:
 * MQTTNIO has no automatic reconnect, so the Mac adapter owns its own
 * reconnect loop and can jitter the backoff before each connect
 * attempt. HiveMQ owns reconnect timing here
 * ([HiveMqttTransport]'s `automaticReconnectWithDefaultConfig`), so the
 * only place this adapter can insert a wait is after the connection is
 * back - immediately before the report. The effect on the relay, which
 * is what the ADR is about, is the same: re-registrations arrive spread
 * over a 2-second window instead of all at once.
 *
 * HiveMQ's own default reconnect is not completely unspread - it adds
 * `+/- 25%` of its exponential backoff (`MqttClientAutoReconnectImpl`),
 * so a first attempt after a 1s initial delay lands somewhere in
 * 750-1250ms. That is a 500ms band on the TCP connect, not a 2000ms
 * band on the message the relay has to process, so it does not make
 * this redundant.
 */
class ReconnectJitter(
    private val maxMillis: Long = DEFAULT_MAX_JITTER_MS,
    private val random: Random = Random.Default,
    private val sleep: suspend (Long) -> Unit = { millis -> delay(millis) },
) {
    init {
        require(maxMillis >= 0) { "maxMillis must not be negative, got: $maxMillis" }
    }

    /**
     * Suspends for a uniformly random 0..[maxMillis] milliseconds,
     * inclusive at both ends (matching the Mac's `0...2000` range).
     *
     * [sleep] is injected rather than calling `delay` inline so a test
     * can assert the wait without spending it.
     */
    suspend fun await() {
        sleep(random.nextLong(maxMillis + 1))
    }

    companion object {
        /**
         * 2 seconds, matching `adapter-mac`'s
         * `Int.random(in: 0...2000)`. Wide enough to spread a
         * two-device system - and any plausible near-term one - across
         * distinct ticks, short enough that a node stays invisible to a
         * just-restarted relay for a fraction of the 90s reap window
         * (#142) and a small fraction of the 120s periodic
         * re-registration (#178) that is the fallback if this report is
         * lost entirely.
         */
        const val DEFAULT_MAX_JITTER_MS = 2_000L
    }
}
