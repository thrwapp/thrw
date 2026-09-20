package com.thrw.adapter.android.status

import kotlin.test.Test
import kotlin.test.assertEquals

class NodeStatusTest {
    @Test
    fun `connected and holding the route`() {
        assertEquals(NodeStatus.HOLDING, nodeStatus(isConnected = true, holdsRoute = true))
    }

    @Test
    fun `connected and not holding`() {
        assertEquals(NodeStatus.NOT_HOLDING, nodeStatus(isConnected = true, holdsRoute = false))
    }

    /**
     * #191's observer returns null when it genuinely cannot read the
     * route. Reporting that as "not holding" would invent an answer.
     */
    @Test
    fun `connected but the route cannot be read`() {
        assertEquals(NodeStatus.UNKNOWN, nodeStatus(isConnected = true, holdsRoute = null))
    }

    /**
     * Disconnected outranks the route entirely. While the transport is
     * down any holder state is a stale belief - and this is exactly the
     * case (#182) where the adapter looked perfectly healthy while
     * publishing nothing, so it must not display a confident answer.
     */
    @Test
    fun `disconnected outranks every route state`() {
        for (route in listOf(true, false, null)) {
            assertEquals(
                NodeStatus.DISCONNECTED,
                nodeStatus(isConnected = false, holdsRoute = route),
                "a disconnected node must not report holder state (route=$route)",
            )
        }
    }
}
