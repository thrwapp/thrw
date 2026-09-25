import Foundation

/// What thrw currently thinks is going on, for display (#213).
///
/// Every failure this system has had so far is **silent and looks
/// identical from outside**: the adapter lost its MQTT connection and
/// never reconnected (#182), it reconnected but never re-registered so
/// the relay could not see it (#178), or the relay believed a restarted
/// node still held the headset and issued no claim (#173). In all three
/// the user-visible symptom is the same — *thrw stopped working and said
/// nothing* — and telling them apart required subscribing to MQTT by
/// hand.
///
/// This is the smallest thing that distinguishes them.
public enum NodeStatus: Equatable, Sendable {
    /// The user has paused arbitration on this device (#290).
    ///
    /// Outranks everything below, **including ``disconnected``**, and
    /// that ordering is the interesting part: while paused, whether the
    /// relay is reachable is not why switching has stopped. Telling
    /// someone who paused it themselves that they are "Disconnected from
    /// relay" would send them to debug a connection that is fine.
    ///
    /// #290 criterion 6 — a pause the user has forgotten, with nothing
    /// on screen saying so, is the silent-failure class #213 exists to
    /// prevent, self-inflicted.
    case paused
    /// The transport is down. Deliberately outranks everything below:
    /// while it is down, any holder state is a stale belief, and a wrong
    /// answer presented confidently is worse than saying nothing useful.
    case disconnected
    /// Connected, and this device currently holds the audio route.
    case holding
    /// Connected, and it does not.
    case notHolding
    /// Connected, but the route cannot be read - #191's observer returns
    /// `nil` when it genuinely cannot tell, and that is not the same as
    /// "no". Reporting it as `notHolding` would be inventing an answer.
    case unknown

    /// Text for a menu item. Present tense and plain: this is read at a
    /// glance, usually while something is going wrong.
    public var displayText: String {
        switch self {
        case .paused: return "Paused \u{2014} not switching on this device"
        case .disconnected: return "Disconnected from relay"
        case .holding: return "Holding headset"
        case .notHolding: return "Not holding headset"
        case .unknown: return "Connected \u{2014} headset state unknown"
        }
    }
}

/// Derives the status from the two things that can be observed.
///
/// A pure function, and tested as one, because the precedence between
/// them is the only decision here and it is easy to get subtly wrong:
/// checking the route first would report a confident "Not holding" for a
/// node that is not even talking to the relay.
/// `isPaused` defaults to `false` so every existing caller and test is
/// unaffected; it is checked first for the reason ``NodeStatus/paused``
/// documents.
public func nodeStatus(isConnected: Bool, holdsRoute: Bool?, isPaused: Bool = false) -> NodeStatus {
    if isPaused { return .paused }
    return connectedStatus(isConnected: isConnected, holdsRoute: holdsRoute)
}

private func connectedStatus(isConnected: Bool, holdsRoute: Bool?) -> NodeStatus {
    guard isConnected else { return .disconnected }
    switch holdsRoute {
    case .some(true): return .holding
    case .some(false): return .notHolding
    case .none: return .unknown
    }
}
