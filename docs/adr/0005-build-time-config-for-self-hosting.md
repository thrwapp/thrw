# ADR 0005: Relay and licensing endpoints must be build-time configuration

## Status
Accepted

## Context
Because published Mac App Store / Play Store binaries are signed and
built by thrw against thrw's own relay and Keygen instance, a
self-hoster who runs their own relay (permitted and intended, per ADR
0003) cannot use the officially published app binary against their own
backend — that pairing doesn't exist and can't, since the binary is
bound to thrw's infrastructure at build time. This is normal for
open-core products with a client app (Signal works the same way) but
needs to be designed for deliberately rather than left as an accident
of hardcoded strings.

## Decision
Every adapter must read its relay URL and Keygen validation endpoint
from build-time configuration (a config file per adapter — e.g. a
Gradle build-config field for Android, an xcconfig for Swift), never
hardcoded inline in source. Additionally, licensing validation should
support a SELF_HOSTED build flag that skips Keygen validation entirely,
so a self-hoster building their own binary for personal use doesn't
need to also stand up Keygen just to get a working build.

## Rationale
This is the concrete, low-cost thing that makes "self-host if you want"
actually true rather than aspirational. Without it, a self-hoster would
have to hunt through source for hardcoded endpoint strings before they
could build a working personal instance.

## Consequences
CLAUDE.md / AGENTS.md must explicitly forbid hardcoding these endpoints
inline — this is called out as a standing rule, not left to be caught
by code review after the fact. A "running your own instance" wiki page
documenting the full self-host build path is a required deliverable,
not optional documentation.
