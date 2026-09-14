# ADR 0003: Single public repo, license varies by top-level directory

## Status
Accepted (supersedes an earlier, rejected two-org/two-repo design)

## Context
thrw is open-core: the protocol and platform adapters should be freely
usable and self-hostable, while the hosted relay, licensing, billing,
and AI/telemetry layers are the commercial product. Two structural
options were considered: (a) split into a public repo (thrwapp/thrw)
and a private repo (in the Barhatch Ltd GitHub org) for the commercial
services, or (b) one public repo with license varying by directory.

## Decision
One repo, thrwapp/thrw, public. packages/** is MIT licensed. services/**
is licensed under the Functional Source License (FSL-1.1-MIT, 2-year
delayed conversion to MIT), with Barhatch Ltd named as copyright holder
in that directory's LICENSE file.

## Rationale
A two-repo split buys very little real protection for this product —
the actual commercial moat is the running hosted relay, the maintained
Keygen/Stripe integration, aggregated user telemetry, and the trained
AI engine state, none of which is replicated by someone reading the
source code for services/. Meanwhile a two-repo split costs real
things: it needs two GitHub Apps, two sets of CI secrets, and forces
a publish-and-version-bump step between a protocol change and its
relay implementation even when they're naturally one PR. It also
weakens the actual pitch to self-hosters — "download everything and
run it yourself" is a stronger, more honest claim than "here are the
open bits, trust us blindly on the rest."

FSL/BSL-family licenses (the same family Keygen itself ships under)
solve the one real risk — someone standing up a directly competing
hosted thrw clone using the billing/licensing code — without hiding
anything from a genuine self-hoster, and without needing a repo split
to express the ownership distinction. CODEOWNERS enforces merge rights
on services/**; the FSL enforces what a fork can be used for; these are
two independent, orthogonal controls and neither requires two repos.

## Consequences
- Barhatch Ltd is the named copyright holder in services/LICENSE, even
  though the code lives in a repo under the thrwapp GitHub org.
- CODEOWNERS on services/** requires human merge regardless of who
  authored the PR (including the agent).
- A self-hoster gets the entire stack including licensing, and can run
  a fully working personal instance — see ADR 0005 for the one genuine
  remaining friction point (published app binaries are bound to thrw's
  own infrastructure at build time) and how it's mitigated.
