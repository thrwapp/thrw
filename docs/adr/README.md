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
