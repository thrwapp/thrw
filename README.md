# thrw

thrw is a cross-device audio switching tool: it keeps a Bluetooth headset
(starting with AirPods, later Sony/Nothing and others) following you between
your phone, laptop, and tablet, prioritizing whichever device needs it most
— an incoming call over background media, a VoIP session over silence — the
kind of context-aware handoff that only exists today within a single
vendor's own ecosystem, and even then unreliably.

## License

This repository is open-core, with license varying by top-level directory:

- **`packages/`** — [MIT](./LICENSE). The wire protocol, the relay engine,
  the test kit, and every platform adapter are freely usable, forkable, and
  self-hostable.
- **`services/`** — [FSL-1.1-MIT](./services/LICENSE) (Functional Source
  License), copyright Barhatch Ltd. The hosted relay, licensing, billing,
  AI engine, telemetry, and accounts services. Each release converts to MIT
  two years after it's made available. Until then, the FSL permits reading,
  modifying, and running this code for your own use — it only restricts
  standing up a directly competing hosted service with it.

See `docs/adr/0003-single-repo-license-per-directory.md` for the reasoning
behind this split.

## Self-hosting

_TODO: full self-hosting guide. `services/` is source-available under the
FSL specifically so a self-hoster can run the entire stack — relay,
licensing, billing bridge — as their own instance, not just the open
`packages/` half. Every adapter reads its relay and licensing endpoints from
build-time configuration rather than a hardcoded default, and a
`SELF_HOSTED` build flag will let a personal build skip Keygen license
validation entirely. This section will cover: standing up the relay and
Keygen containers, building each adapter against your own endpoints, and the
one real limitation (published App Store / Play Store binaries are bound to
thrw's own infrastructure at build time, so self-hosters build their own)._
