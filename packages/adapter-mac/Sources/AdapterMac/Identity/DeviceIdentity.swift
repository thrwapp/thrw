import Foundation

/// This device's stable node identity: the ``NodeManifest`` ``MacNode/register(manifest:)``
/// announces, keyed by ``nodeId`` - which is also the MQTT client id and
/// this node's slot in every per-node topic (architecture.md, "MQTT
/// topic design"). Swift mirror of `adapter-android`'s
/// `identity/DeviceIdentity.kt`.
///
/// ``nodeId`` must be stable across process restarts - the broker's
/// account-scoped ACLs key off the connecting client id
/// (`MQTTNIOTransport.connect`'s kdoc) - so it's generated once and
/// persisted in `UserDefaults`, not derived fresh on every launch.
public enum DeviceIdentity {
    private static let nodeIdKey = "app.thrw.mac.deviceIdentity.nodeId"

    /// A placeholder until this package has a real `.app` bundle version
    /// wired up (`CFBundleShortVersionString`) - see #128's handoff,
    /// "Known gaps". `adapter-android`'s equivalent reads
    /// `BuildConfig.VERSION_NAME`, which Gradle derives automatically;
    /// SwiftPM has no equivalent for a plain package target.
    ///
    /// **Bump this in the same PR as the tag it ships under.** v0.1.0's
    /// tag exists precisely because this literal had read 0.1.0 since #96
    /// while every build was tagged v0.0.1, so the version the relay saw
    /// in `NodeManifest.adapterVersion` was not the version on the release
    /// page. `adapter-android`'s `versionName` is the same literal on the
    /// other side of the same contract - change both together.
    static let adapterVersion = "0.2.1"

    public static func nodeId(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: nodeIdKey) {
            return existing
        }
        let generated = UUID().uuidString
        defaults.set(generated, forKey: nodeIdKey)
        return generated
    }

    /// The manifest this node registers with on connect.
    ///
    /// `supportedEventKinds` lists only `.voip` - the one trigger this
    /// adapter has a monitor for (`VoipTriggerMonitor`, #127). `.call`
    /// is deliberately not claimed: #127's own research found macOS has
    /// no call-detection API at all (AVAudioSession is iOS/tvOS/
    /// watchOS-only), a permanent platform gap, not a missing feature -
    /// see `docs/spec/architecture.md`'s "Mac's trigger-detection gap"
    /// section. `.media` is detected by ``MediaTriggerMonitor`` as of #166;
    /// and `.manual_claim` isn't something this node spontaneously emits
    /// (no UI to trigger it) - mirrors `DeviceIdentity.kt`'s own
    /// reasoning for the same two omissions.
    public static func manifest(defaults: UserDefaults = .standard) -> NodeManifest {
        NodeManifest(
            nodeId: nodeId(defaults: defaults),
            platform: .mac,
            displayName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            adapterVersion: adapterVersion,
            supportedEventKinds: [.voip, .media],
            supportedResourceTypes: [MacNode.resource]
        )
    }
}
