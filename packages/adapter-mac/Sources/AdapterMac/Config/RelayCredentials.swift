import Foundation

/// The MQTT username/password this adapter presents to the relay (#147).
///
/// Separate from ``RelayConfig`` on purpose: that type parses a URL and
/// answers "where and how do I connect"; this answers "as whom". The
/// credential is not part of the relay URL and must not be, or it would
/// end up in logs and error messages alongside it.
///
/// ## Why this is build-time config, and what that costs
///
/// Per ADR 0005 every adapter endpoint comes from build-time
/// configuration. The credential now rides the same mechanism - but
/// unlike a URL, a credential must not be committed, so
/// `config/adapter.properties` ships it **empty** and the real value
/// comes from `config/adapter.local.properties`, which is gitignored.
///
/// Stated plainly, because it constrains distribution: the value is
/// still compiled into the binary, so anyone who can read the app can
/// recover it. That is acceptable while the only users are the
/// developer's own devices and there is exactly one shared relay
/// credential (the interim model from #80, with `acl.conf` as
/// `{allow, all, ...}`). **It is not acceptable for public
/// distribution** - before the app ships to anyone else, this needs
/// per-device credentials, which needs `services/accounts` (M7) to mint
/// them. See docs/handoffs/147.md and M10.
///
/// Absent credentials are legitimate, not an error: a local or
/// self-hosted broker running `allow_anonymous = true` needs none, and
/// that is how this package's tests and CI connect.
public struct RelayCredentials: Equatable, Sendable {
    public let username: String
    public let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    /// The build-time-configured credential, or `nil` when either half is
    /// blank - meaning "connect anonymously".
    ///
    /// Both halves are required together: a username with no password (or
    /// vice versa) is a misconfiguration that would otherwise produce a
    /// confusing broker-side rejection, so it's treated as "no
    /// credentials" rather than half-sent.
    public static func fromBuildConfig() -> RelayCredentials? {
        make(username: AdapterBuildConfig.relayUsername, password: AdapterBuildConfig.relayPassword)
    }

    /// Testable seam for ``fromBuildConfig()`` - the generated
    /// `AdapterBuildConfig` is baked in at build time and can't be varied
    /// from a test.
    static func make(username: String, password: String) -> RelayCredentials? {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !pass.isEmpty else { return nil }
        return RelayCredentials(username: user, password: pass)
    }
}
