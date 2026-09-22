# Architecture Decision Records

| ADR | Title | Status |
| --- | --- | --- |
| [0001](./0001-mqtt-transport.md) | MQTT over WebSocket/TLS as the relay transport | Accepted |
| [0002](./0002-sequential-handoff-not-multipoint.md) | Sequential handoff, not dual-connection multipoint, for AirPods | Accepted |
| [0003](./0003-single-repo-license-per-directory.md) | Single public repo, license varies by top-level directory | Accepted (supersedes an earlier, rejected two-org/two-repo design) |
| [0004](./0004-no-electron.md) | Native Swift/Kotlin/Rust per platform, not Electron or Tauri | Accepted |
| [0005](./0005-build-time-config-for-self-hosting.md) | Relay and licensing endpoints must be build-time configuration | Accepted |
| [0006](./0006-gcp-hosting-not-flyio.md) | GCP Compute Engine for the relay, not Fly.io or Cloud Run | Accepted (supersedes an earlier Fly.io-based design) |
| [0007](./0007-latency-slo-not-multi-region-by-default.md) | Single region at launch, with a measured trigger for adding a second | Accepted |
| [0008](./0008-model-routing-via-vertex.md) | All LLM calls via Vertex AI, routed by task difficulty | Accepted |
| [0009](./0009-stripe-keygen-decoupled-licensing.md) | Stripe for billing, self-hosted Keygen for device licensing — decoupled | Accepted |
| [0010](./0010-conflict-detection-and-cooldown.md) | Conflict detection and cooldown for BT connection management | Accepted |
| [0011](./0011-predictive-preclaim.md) | Predictive pre-claim using early trigger signals | Accepted |
| [0012](./0012-proactive-conflict-resolution.md) | Proactively detect and help resolve competing connection managers | Accepted |
| [0013](./0013-connection-state-machine-reconciliation.md) | Connection state machine — cooldown is adapter-local, not a node-interface state | Accepted |
| [0014](./0014-manual-claim-node-capability.md) | `claimMode` capability in the node manifest, for platforms with no programmatic Bluetooth control | Proposed |
| [0015](./0015-typed-resources.md) | Typed resources — audio and HID share claim/release, not priority rules | Accepted |
| [0016](./0016-ambient-focus-tracking.md) | Ambient focus tracking as the default-holder layer | Accepted |
| [0017](./0017-ai-scope.md) | AI scope — local classification for decisions, LLM for explanation only | Accepted |
| [0018](./0018-state-reconciliation-and-idempotency.md) | State reconciliation and command idempotency | Accepted |
| [0019](./0019-switch-outcome-confirmation-and-failure-telemetry.md) | Every switch has a confirmed outcome, not fire-and-forget | Accepted |
| [0020](./0020-command-debouncing-and-offline-behavior.md) | Command debouncing at the relay, and defined offline behaviour | Accepted |
| [0021](./0021-preclaim-execution-and-speculative-events.md) | Executing pre-claim — speculative events, and what earns one | Proposed |
