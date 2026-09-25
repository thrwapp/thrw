package com.thrw.adapter.android.status

/**
 * What thrw currently thinks is going on, for display (#213).
 *
 * Every failure this system has had so far is **silent and looks
 * identical from outside**: the adapter lost its MQTT connection and
 * never reconnected (#182), it reconnected but never re-registered so
 * the relay could not see it (#178), or the relay believed a restarted
 * node still held the headset and issued no claim (#173). In all three
 * the user-visible symptom is the same - *thrw stopped working and said
 * nothing* - and telling them apart required subscribing to MQTT by
 * hand.
 *
 * This is the smallest thing that distinguishes them. Mirrors
 * `adapter-mac`'s `NodeStatus`.
 */
enum class NodeStatus {
    /**
     * The user has paused arbitration on this device (#290).
     *
     * Outranks everything below, **including [DISCONNECTED]**, and that
     * ordering is the interesting part: while paused, whether the relay
     * is reachable is not why switching has stopped. Telling someone who
     * paused it themselves that they are disconnected would send them to
     * debug a connection that is fine.
     *
     * #290 criterion 6 — a pause the user has forgotten, with nothing on
     * screen saying so, is the silent-failure class #213 exists to
     * prevent, self-inflicted.
     */
    PAUSED,

    /**
     * The transport is down. Deliberately outranks everything below:
     * while it is down any holder state is a stale belief, and a wrong
     * answer presented confidently is worse than saying nothing useful.
     */
    DISCONNECTED,

    /** Connected, and this device currently holds the audio route. */
    HOLDING,

    /** Connected, and it does not. */
    NOT_HOLDING,

    /**
     * Connected, but the route cannot be read. #191's observer returns
     * `null` when it genuinely cannot tell, and that is not the same as
     * "no" - reporting it as [NOT_HOLDING] would invent an answer.
     */
    UNKNOWN,
}

/**
 * Derives the status from the two things that can be observed.
 *
 * A pure function, and tested as one, because the precedence between
 * them is the only decision here and it is easy to get subtly wrong:
 * checking the route first would report a confident "not holding" for a
 * node that is not even talking to the relay.
 */
fun nodeStatus(isConnected: Boolean, holdsRoute: Boolean?, isPaused: Boolean = false): NodeStatus = when {
    isPaused -> NodeStatus.PAUSED
    !isConnected -> NodeStatus.DISCONNECTED
    holdsRoute == true -> NodeStatus.HOLDING
    holdsRoute == false -> NodeStatus.NOT_HOLDING
    else -> NodeStatus.UNKNOWN
}
