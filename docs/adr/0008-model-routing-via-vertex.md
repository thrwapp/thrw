# ADR 0008: All LLM calls via Vertex AI, routed by task difficulty

## Status
Accepted

## Context
The agent development pipeline (issue triage, code generation, PR
evaluation, content generation) needs LLM calls. These could run
directly against the Anthropic API, or through Vertex AI now that the
project is consolidated on GCP and Claude models are available there.
Additionally, not every task in the pipeline needs the same model
capability.

## Decision
All model calls route through Vertex AI in the same GCP project used
for hosting, authenticated via Workload Identity Federation (no stored
API keys). Model selection by task:

  - Issue triage/labeling: Gemini Flash (cheap, output is just a label)
  - Routine code generation (packages/**): Claude Sonnet, via the
    standard claude-code-action harness
  - Hard platform-API code (CoreBluetooth, TelephonyManager edge cases,
    labeled model:opus): Claude Opus, same harness
  - PR evaluation (fresh-context grading): Claude Sonnet, same harness,
    read-only tools
  - Nightly whole-repo drift review: Claude Opus
  - Social post drafting, Reddit digest: Gemini Flash

## Rationale
Vertex gives unified GCP billing without abandoning Claude Code's
harness for the parts of the pipeline where that harness matters —
specifically the builder/evaluator pair, which depends on
claude-code-action's specific tool-use and prompt patterns
(default-FAIL evidence-based grading, agent-maintained handoff notes).
Swapping those two roles to a different vendor's agent framework would
mean rebuilding that scaffolding from scratch for a cost saving that's
likely under $100/month at expected issue volume — not worth it.
Gemini Flash is added only where the output is low-stakes and
classification-shaped (a label, a short summary) — genuinely free
money saved with no harness risk, since a wrong label costs one wasted
builder run, not a bad merge.

## Consequences
Two GCP projects are used, not one: switchr-prod (later: thrw-prod) for
hosting infrastructure, and a separate AI/agent project for Vertex
spend, each with its own budget alert — so a runaway agent loop's
spend is billing-isolated from the production relay and can never
trigger a quota freeze on customer-facing infrastructure. Vertex model
ID strings should be pinned to dated versions once the pipeline is
proven stable, not left on @latest indefinitely, so a model release
can't silently change builder behavior mid-week.
