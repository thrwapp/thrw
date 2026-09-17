package com.thrw.adapter.android.triggers

import com.thrw.adapter.android.protocol.EventKind
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.asFlow
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Fakes the [NotificationSource] boundary rather than mocking
 * `NotificationListenerService`: no Android SDK on this module's classpath
 * (see the source's kdoc), and the Gradle test runner can't post a real
 * notification.
 */
private class FakeNotificationSource(private val events: List<NotificationEvent>) : NotificationSource {
    override fun notifications(): Flow<NotificationEvent> = events.asFlow()
}

private const val ZOOM = "us.zoom.videomeetings"
private const val WHATSAPP = "com.whatsapp"

/** An ongoing `CallStyle` in-call notification, the common case. */
private fun ongoingCall(
    key: String,
    packageName: String = ZOOM,
    flags: Int = NotificationFlags.FOREGROUND_SERVICE or NotificationFlags.ONGOING_EVENT,
    category: String? = CATEGORY_CALL,
    template: String? = CALL_STYLE_TEMPLATE,
    callType: Int? = CallType.ONGOING,
) = PostedNotification(
    key = key,
    packageName = packageName,
    category = category,
    flags = flags,
    template = template,
    callType = callType,
)

private fun posted(notification: PostedNotification) = NotificationEvent.Posted(notification)

class VoipTriggerMonitorTest {
    @Test
    fun `an ongoing call notification emits a voip event`() = runTest {
        val node = RecordingEventLifecycle()
        val monitor = VoipTriggerMonitor(
            FakeNotificationSource(listOf(posted(ongoingCall("zoom|1")))),
            node,
        )

        monitor.run()

        assertEquals(listOf<TriggerCall>(TriggerCall.Started(EventKind.VOIP, UNRANKED_PRIORITY)), node.calls)
    }

    @Test
    fun `removing the notification ends the voip event`() = runTest {
        val node = RecordingEventLifecycle()
        val monitor = VoipTriggerMonitor(
            FakeNotificationSource(
                listOf(posted(ongoingCall("zoom|1")), NotificationEvent.Removed("zoom|1")),
            ),
            node,
        )

        monitor.run()

        assertEquals(
            listOf(
                TriggerCall.Started(EventKind.VOIP, UNRANKED_PRIORITY),
                TriggerCall.Ended(EventKind.VOIP),
            ),
            node.calls,
        )
    }

    @Test
    fun `an in-place update that stops qualifying ends the voip event`() = runTest {
        val node = RecordingEventLifecycle()
        val monitor = VoipTriggerMonitor(
            FakeNotificationSource(
                listOf(
                    posted(ongoingCall("zoom|1")),
                    // "Call ended" - same key, no longer ongoing.
                    posted(ongoingCall("zoom|1", flags = 0, callType = null)),
                ),
            ),
            node,
        )

        monitor.run()

        assertEquals(
            listOf(
                TriggerCall.Started(EventKind.VOIP, UNRANKED_PRIORITY),
                TriggerCall.Ended(EventKind.VOIP),
            ),
            node.calls,
        )
    }

    @Test
    fun `repeated updates to the same call notification emit once`() = runTest {
        val node = RecordingEventLifecycle()
        val monitor = VoipTriggerMonitor(
            FakeNotificationSource(
                List(5) { posted(ongoingCall("zoom|1")) } + NotificationEvent.Removed("zoom|1"),
            ),
            node,
        )

        monitor.run()

        assertEquals(
            listOf(
                TriggerCall.Started(EventKind.VOIP, UNRANKED_PRIORITY),
                TriggerCall.Ended(EventKind.VOIP),
            ),
            node.calls,
        )
    }

    @Test
    fun `overlapping sessions emit one start and end only when the last one goes`() = runTest {
        val node = RecordingEventLifecycle()
        val monitor = VoipTriggerMonitor(
            FakeNotificationSource(
                listOf(
                    posted(ongoingCall("zoom|1")),
                    posted(ongoingCall("wa|1", packageName = WHATSAPP)),
                    NotificationEvent.Removed("zoom|1"),
                    NotificationEvent.Removed("wa|1"),
                ),
            ),
            node,
        )

        monitor.run()

        assertEquals(
            listOf(
                TriggerCall.Started(EventKind.VOIP, UNRANKED_PRIORITY),
                TriggerCall.Ended(EventKind.VOIP),
            ),
            node.calls,
        )
    }

    @Test
    fun `a second call after the first ended is a second start-end pair`() = runTest {
        val node = RecordingEventLifecycle()
        val monitor = VoipTriggerMonitor(
            FakeNotificationSource(
                listOf(
                    posted(ongoingCall("zoom|1")),
                    NotificationEvent.Removed("zoom|1"),
                    posted(ongoingCall("wa|1", packageName = WHATSAPP)),
                    NotificationEvent.Removed("wa|1"),
                ),
            ),
            node,
        )

        monitor.run()

        assertEquals(
            listOf(
                TriggerCall.Started(EventKind.VOIP, UNRANKED_PRIORITY),
                TriggerCall.Ended(EventKind.VOIP),
                TriggerCall.Started(EventKind.VOIP, UNRANKED_PRIORITY),
                TriggerCall.Ended(EventKind.VOIP),
            ),
            node.calls,
        )
    }

    @Test
    fun `removing a notification that never qualified reports nothing`() = runTest {
        val node = RecordingEventLifecycle()
        val monitor = VoipTriggerMonitor(
            FakeNotificationSource(
                listOf(
                    posted(
                        PostedNotification(
                            key = "mail|1",
                            packageName = "com.google.android.gm",
                            category = "email",
                        ),
                    ),
                    NotificationEvent.Removed("mail|1"),
                ),
            ),
            node,
        )

        monitor.run()

        assertTrue(node.calls.isEmpty())
    }

    @Test
    fun `a missed-call notification does not qualify - call-shaped but not ongoing`() = runTest {
        val monitor = VoipTriggerMonitor(FakeNotificationSource(emptyList()), RecordingEventLifecycle())

        assertFalse(
            monitor.isActiveVoipCall(
                ongoingCall("wa|missed", packageName = WHATSAPP, flags = 0, callType = null),
            ),
        )
    }

    @Test
    fun `an incoming ringing CallStyle notification does not qualify`() = runTest {
        val monitor = VoipTriggerMonitor(FakeNotificationSource(emptyList()), RecordingEventLifecycle())

        assertFalse(monitor.isActiveVoipCall(ongoingCall("zoom|ring", callType = CallType.INCOMING)))
        assertFalse(monitor.isActiveVoipCall(ongoingCall("zoom|scr", callType = CallType.SCREENING)))
        assertTrue(monitor.isActiveVoipCall(ongoingCall("zoom|live", callType = CallType.ONGOING)))
    }

    @Test
    fun `a group summary does not qualify - its children already counted`() = runTest {
        val monitor = VoipTriggerMonitor(FakeNotificationSource(emptyList()), RecordingEventLifecycle())

        assertFalse(
            monitor.isActiveVoipCall(
                ongoingCall(
                    "zoom|summary",
                    flags = NotificationFlags.ONGOING_EVENT or NotificationFlags.GROUP_SUMMARY,
                ),
            ),
        )
    }

    @Test
    fun `the system dialer's ongoing call notification does not qualify - TelephonyManager has it`() = runTest {
        val node = RecordingEventLifecycle()
        val monitor = VoipTriggerMonitor(
            FakeNotificationSource(
                VoipTriggerMonitor.DEFAULT_TELEPHONY_PACKAGES.mapIndexed { index, pkg ->
                    posted(ongoingCall("dialer|$index", packageName = pkg))
                },
            ),
            node,
        )

        monitor.run()

        assertTrue(node.calls.isEmpty())
    }

    @Test
    fun `the telephony exclusion set is configurable for OEM dialers`() = runTest {
        val node = RecordingEventLifecycle()
        val monitor = VoipTriggerMonitor(
            FakeNotificationSource(listOf(posted(ongoingCall("oem|1", packageName = "com.oem.dialer")))),
            node,
            telephonyPackages = setOf("com.oem.dialer"),
        )

        monitor.run()

        assertTrue(node.calls.isEmpty())
    }

    @Test
    fun `a plain ongoing CATEGORY_CALL notification without CallStyle still qualifies`() = runTest {
        val monitor = VoipTriggerMonitor(FakeNotificationSource(emptyList()), RecordingEventLifecycle())

        assertTrue(
            monitor.isActiveVoipCall(
                ongoingCall("legacy|1", template = null, callType = null),
            ),
        )
    }

    @Test
    fun `a CallStyle notification without a category still qualifies`() = runTest {
        val monitor = VoipTriggerMonitor(FakeNotificationSource(emptyList()), RecordingEventLifecycle())

        assertTrue(monitor.isActiveVoipCall(ongoingCall("meet|1", category = null)))
    }

    @Test
    fun `an ongoing notification that is not call-shaped does not qualify`() = runTest {
        val monitor = VoipTriggerMonitor(FakeNotificationSource(emptyList()), RecordingEventLifecycle())

        // A music player's ongoing media notification: media triggers are
        // out of scope for #68, and must not be misread as a VoIP call.
        assertFalse(
            monitor.isActiveVoipCall(
                PostedNotification(
                    key = "music|1",
                    packageName = "com.spotify.music",
                    category = "transport",
                    flags = NotificationFlags.ONGOING_EVENT or NotificationFlags.FOREGROUND_SERVICE,
                    template = "android.app.Notification\$MediaStyle",
                ),
            ),
        )
    }

    @Test
    fun `either ongoing flag alone is enough`() = runTest {
        val monitor = VoipTriggerMonitor(FakeNotificationSource(emptyList()), RecordingEventLifecycle())

        assertTrue(
            monitor.isActiveVoipCall(ongoingCall("a", flags = NotificationFlags.ONGOING_EVENT)),
        )
        assertTrue(
            monitor.isActiveVoipCall(ongoingCall("b", flags = NotificationFlags.FOREGROUND_SERVICE)),
        )
    }

    @Test
    fun `never reports call or media - only voip`() = runTest {
        val node = RecordingEventLifecycle()
        val monitor = VoipTriggerMonitor(
            FakeNotificationSource(
                listOf(posted(ongoingCall("zoom|1")), NotificationEvent.Removed("zoom|1")),
            ),
            node,
        )

        monitor.run()

        assertTrue(node.calls.all { it.kind == EventKind.VOIP })
    }

    @Test
    fun `a callback-driven caller can drive the monitor without a flow`() = runTest {
        val node = RecordingEventLifecycle()
        val monitor = VoipTriggerMonitor(FakeNotificationSource(emptyList()), node)

        monitor.onNotificationEvent(posted(ongoingCall("zoom|1")))
        monitor.onNotificationEvent(NotificationEvent.Removed("zoom|1"))

        assertEquals(
            listOf(
                TriggerCall.Started(EventKind.VOIP, UNRANKED_PRIORITY),
                TriggerCall.Ended(EventKind.VOIP),
            ),
            node.calls,
        )
    }
}
