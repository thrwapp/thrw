# Prompt 5 — GCP WIF setup + branch protection (not a Cowork prompt in the
# usual sense — a runbook for a session with real `gcloud` and `gh` admin
# access to run against thrwapp/thrw)

Run this in a Claude Code / Cowork session with `gcloud` authenticated
against Tom's GCP account and `gh` authenticated as an admin on
thrwapp/thrw. Confirm both with `gcloud auth list` and `gh auth status`
before doing anything else.

---

## Step 0 — ask before assuming

Do not create GCP projects, service accounts, or IAM bindings until Tom
has answered these. Guessing here is exactly the kind of thing AGENTS.md's
honesty/no-guessing rule is for:

1. Do the two GCP projects already exist? ADR 0008 names them
   `switchr-prod` (later renamed `thrw-prod`) for hosting and an
   unspecified separate project for AI/Vertex spend. Get the exact
   current project IDs, or confirm you're creating new ones — if new,
   confirm the exact IDs to use (this runbook uses the placeholders
   `thrw-prod` and `thrw-ai` below; replace both throughout).
2. Which GCP region for: Vertex AI calls, the Artifact Registry, and the
   relay's Compute Engine VM (ADR 0006 says "an Always Free eligible
   region" for the VM specifically — confirm which one is actually in
   use).
3. Does the relay VM already exist (per ADR 0006), or is this the first
   time it's being created? This runbook assumes it already exists and
   only grants deploy permissions against it — VM creation itself isn't
   covered here.
4. What's the actual health-check URL for the relay, once deployed?

Set these as shell variables once you have real answers, then use them
verbatim in every command below:

```bash
export GCP_PROJECT_AI="thrw-ai"       # replace with the real project ID
export GCP_PROJECT_PROD="thrw-prod"   # replace with the real project ID
export GCP_REGION="us-central1"       # replace with the real region
export GH_REPO="thrwapp/thrw"
```

---

## Part A — GCP Workload Identity Federation

This wires up exactly what `agent-triage.yml`, `agent-code.yml`,
`agent-eval.yml`, `release.yml`'s announce job, and `deploy.yml` already
assume: a `WIF_PROVIDER` secret, an `agent-pipeline` service account in
the AI project, and a `deploy` service account in the prod project. If
you use different service account names, update those five workflow
files to match instead of renaming things here.

### A1. Enable required APIs

```bash
gcloud services enable \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  aiplatform.googleapis.com \
  --project="$GCP_PROJECT_AI"

gcloud services enable \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  artifactregistry.googleapis.com \
  compute.googleapis.com \
  --project="$GCP_PROJECT_PROD"
```

### A2. Create one Workload Identity Pool + Provider (in the AI project;
it can grant access to service accounts in *either* project)

```bash
gcloud iam workload-identity-pools create "github-actions-pool" \
  --project="$GCP_PROJECT_AI" \
  --location="global" \
  --display-name="GitHub Actions"

gcloud iam workload-identity-pools providers create-oidc "github-actions-provider" \
  --project="$GCP_PROJECT_AI" \
  --location="global" \
  --workload-identity-pool="github-actions-pool" \
  --display-name="GitHub Actions" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner" \
  --attribute-condition="assertion.repository_owner == 'thrwapp'"
```

### A3. Get the values you'll need for bindings and secrets

```bash
export AI_PROJECT_NUMBER=$(gcloud projects describe "$GCP_PROJECT_AI" --format='value(projectNumber)')

export WIF_PROVIDER=$(gcloud iam workload-identity-pools providers describe "github-actions-provider" \
  --project="$GCP_PROJECT_AI" \
  --location="global" \
  --workload-identity-pool="github-actions-pool" \
  --format="value(name)")

echo "$WIF_PROVIDER"
```

### A4. Create the two service accounts

```bash
gcloud iam service-accounts create agent-pipeline \
  --project="$GCP_PROJECT_AI" \
  --display-name="thrw agent pipeline (Vertex AI)"

gcloud iam service-accounts create deploy \
  --project="$GCP_PROJECT_PROD" \
  --display-name="thrw relay deploy"
```

### A5. Let the WIF pool impersonate both service accounts, scoped to
this one repo

```bash
gcloud iam service-accounts add-iam-policy-binding \
  "agent-pipeline@${GCP_PROJECT_AI}.iam.gserviceaccount.com" \
  --project="$GCP_PROJECT_AI" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${AI_PROJECT_NUMBER}/locations/global/workloadIdentityPools/github-actions-pool/attribute.repository/thrwapp/thrw"

gcloud iam service-accounts add-iam-policy-binding \
  "deploy@${GCP_PROJECT_PROD}.iam.gserviceaccount.com" \
  --project="$GCP_PROJECT_PROD" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${AI_PROJECT_NUMBER}/locations/global/workloadIdentityPools/github-actions-pool/attribute.repository/thrwapp/thrw"
```

### A6. Grant each service account the roles it actually needs

```bash
# agent-pipeline: Vertex AI calls only
gcloud projects add-iam-policy-binding "$GCP_PROJECT_AI" \
  --member="serviceAccount:agent-pipeline@${GCP_PROJECT_AI}.iam.gserviceaccount.com" \
  --role="roles/aiplatform.user"

# deploy: push images + roll the relay VM
gcloud projects add-iam-policy-binding "$GCP_PROJECT_PROD" \
  --member="serviceAccount:deploy@${GCP_PROJECT_PROD}.iam.gserviceaccount.com" \
  --role="roles/artifactregistry.writer"

gcloud projects add-iam-policy-binding "$GCP_PROJECT_PROD" \
  --member="serviceAccount:deploy@${GCP_PROJECT_PROD}.iam.gserviceaccount.com" \
  --role="roles/compute.instanceAdmin.v1"

gcloud projects add-iam-policy-binding "$GCP_PROJECT_PROD" \
  --member="serviceAccount:deploy@${GCP_PROJECT_PROD}.iam.gserviceaccount.com" \
  --role="roles/iam.serviceAccountUser"
```

### A7. Set the GitHub secrets and variables the workflows already
reference

```bash
gh secret set WIF_PROVIDER --repo "$GH_REPO" --body "$WIF_PROVIDER"
gh secret set GCP_PROJECT_AI --repo "$GH_REPO" --body "$GCP_PROJECT_AI"
gh secret set GCP_PROJECT_PROD --repo "$GH_REPO" --body "$GCP_PROJECT_PROD"

# GCP_VERTEX_REGION is NOT the same as GCP_REGION above - see the
# "Claude on Vertex AI has its own region list" note below. Every other
# variable here can safely share $GCP_REGION.
gh variable set GCP_VERTEX_REGION --repo "$GH_REPO" --body "us-east5"
gh variable set GCP_ARTIFACT_REGISTRY_REGION --repo "$GH_REPO" --body "$GCP_REGION"
gh variable set GCP_RELAY_ZONE --repo "$GH_REPO" --body "${GCP_REGION}-a"
gh variable set GCP_RELAY_VM_NAME --repo "$GH_REPO" --body "thrw-relay"   # confirm this matches the real VM name
gh variable set RELAY_HEALTH_URL --repo "$GH_REPO" --body "REPLACE_ME"   # real health endpoint, once known
```

**Claude on Vertex AI has its own region list - confirmed live, don't
reuse `$GCP_REGION` for it.** The original draft of this runbook set
`GCP_VERTEX_REGION` to the same value as every other region variable
(`us-central1`), an unverified placeholder assumption. The day-2 smoke
test hit this directly: `agent-code.yml` failed every real run with
`api_error_status 404` / `"The model claude-sonnet-5@latest is not
available on your vertex deployment"` - and switching to the
model the error itself suggested (`claude-sonnet-4-6`) failed
identically. Enabling the model in Model Garden changed nothing,
because the actual problem wasn't the model at all: Anthropic's
Claude models on Vertex AI are only deployed to a specific region
list - confirmed as `us-east5`, `europe-west1`, `asia-southeast1`,
plus an EU multi-region via `europe-west3` - and `us-central1` isn't
on it. A `publishers/anthropic/models/<id>:rawPredict` call against
any model name in an unsupported region 404s identically regardless
of what's enabled, which is what made this look like a model-access
problem instead of a region problem. Use `us-east5` (or another region
from that list) for `GCP_VERTEX_REGION` specifically; leave
`GCP_ARTIFACT_REGISTRY_REGION` and `GCP_RELAY_ZONE` on whatever region
actually hosts those unrelated resources.

### A8. Also confirm before moving on

- Also confirm `AGENT_APP_ID` and `AGENT_APP_KEY` secrets exist (the
  original doc listed these as a "done" prerequisite from before this
  runbook existed — verify rather than assume).
- `deploy.yml` assumes a `Dockerfile` at `services/relay-hosted/` — it
  doesn't exist yet. This runbook doesn't create one; that's separate
  work.
- `release.yml`'s mac/android jobs are inline placeholders standing in
  for a real Fastlane project (no `Gemfile`/`Fastfile` exists yet) -
  also separate work.

---

## Part A2 — create the relay VM (EMQX only; Keygen CE deferred)

ADR 0006 reads as if this VM already exists ("Accepted," past tense) but
it may not — check with `gcloud compute instances list
--project="$GCP_PROJECT_PROD"` before running this. This section is
scoped deliberately narrow: it stands up the VM and EMQX (the actual
MQTT relay), not Keygen CE. Keygen's self-host setup needs its own
Postgres + Redis + generated signing keys + bootstrap - a meaningfully
bigger task than a docker run, and not required before EMQX exists for
protocol/adapter development to start against. Do that as separate,
later work once billing/licensing is actually being built - don't
block on it now.

**Region constraint:** the Always Free e2-micro tier only applies in
`us-west1`, `us-central1`, or `us-east1`. Outside those three, this VM
is a real, billed resource. `$GCP_REGION` from Part A should already be
one of these three - confirm before proceeding.

```bash
export RELAY_VM_NAME="thrw-relay"   # must match GCP_RELAY_VM_NAME pushed in A7
export RELAY_ZONE="${GCP_REGION}-a"

cat > /tmp/relay-startup.sh <<'STARTUP'
#!/bin/bash
set -euo pipefail
apt-get update
apt-get install -y docker.io
systemctl enable --now docker
docker run -d --name emqx --restart unless-stopped \
  -p 8083:8083 \
  -p 18083:18083 \
  emqx/emqx:5
STARTUP

gcloud compute instances create "$RELAY_VM_NAME" \
  --project="$GCP_PROJECT_PROD" \
  --zone="$RELAY_ZONE" \
  --machine-type=e2-micro \
  --image-family=debian-12 \
  --image-project=debian-cloud \
  --tags=thrw-relay \
  --metadata-from-file=startup-script=/tmp/relay-startup.sh

# Open only what ADR 0001 actually calls for: MQTT-over-WebSocket (8083,
# unencrypted for now - TLS/8084 needs a domain + cert, separate work)
# and EMQX's dashboard/status API (18083, used for the health check).
# Deliberately NOT opening 1883 (raw MQTT) - ADR 0001 chose WebSocket
# transport specifically, not raw TCP MQTT.
gcloud compute firewall-rules create thrw-relay-emqx \
  --project="$GCP_PROJECT_PROD" \
  --network=default \
  --direction=INGRESS \
  --action=ALLOW \
  --rules=tcp:8083,tcp:18083 \
  --target-tags=thrw-relay \
  --source-ranges=0.0.0.0/0
```

Get the external IP and verify EMQX is actually up (the startup script
needs a minute or two to run docker.io install + pull the image on
first boot):

```bash
export RELAY_IP=$(gcloud compute instances describe "$RELAY_VM_NAME" \
  --project="$GCP_PROJECT_PROD" \
  --zone="$RELAY_ZONE" \
  --format='value(networkInterfaces[0].accessConfigs[0].natIP)')

echo "$RELAY_IP"
curl -i "http://${RELAY_IP}:18083/api/v5/status"
```

A healthy response is `HTTP 200` with a body like `Node 'emqx@...' is
started`. Once confirmed, set the real health-check URL:

```bash
gh variable set RELAY_HEALTH_URL --repo "$GH_REPO" --body "http://${RELAY_IP}:18083/api/v5/status"
```

**Security note, do this immediately:** EMQX 5's dashboard ships with a
default `admin` / `public` login, reachable at
`http://${RELAY_IP}:18083` over the open internet the moment this VM is
up. Log in and change it right away - don't leave the default sitting
on a public IP even for a few minutes.

**Still deferred, not covered here:**
- TLS (`wss://`, port 8084) - needs a domain name pointed at
  `$RELAY_IP` and a cert (e.g. via Caddy or certbot in front of EMQX).
  ADR 0001's actual decision is WebSocket **over TLS**; the setup above
  is a plaintext bring-up step, not the final state.
- Keygen CE (ADR 0009) - separate task once licensing work starts.
- `services/relay-hosted`'s own application code and Dockerfile
  (referenced by `deploy.yml`) - still doesn't exist.

---

## Part A3 — billing budgets, and a scoped kill switch on GCP_PROJECT_AI

ADR 0008 called for "each [project] with its own budget alert" so a
runaway agent loop's spend is billing-isolated - this was never actually
implemented until now. Two different postures for the two projects:

- **GCP_PROJECT_AI** (Vertex AI spend, driven by `agent-triage`,
  `agent-code`, `agent-eval`, and `release.yml`'s announce job): alert
  *and* an automated hard stop. A runaway agent loop is the realistic
  failure mode here, and it's automatable.
- **GCP_PROJECT_PROD** (the relay VM, ADR 0006 estimates $0-$20/month):
  alert only. An automated hard stop here risks taking down the live
  relay - worse than the overspend it would prevent. A human should
  always be in the loop for this project.

**On the hard stop's design**: the common reference pattern for this
(Google's own documented example) works by fully detaching the billing
account from the project - its own README warns this "will shut down
all existing resources and it's unlikely you will be able to recover
them." That's real risk to the WIF pool and service accounts from Part
A. Since the actual cost driver here is specifically Vertex AI API
calls, `docs/ops/budget-killswitch/main.py` instead disables just
`aiplatform.googleapis.com` on threshold - it stops the spend, leaves
everything else in the project alone, and is trivially reversible
(`gcloud services enable aiplatform.googleapis.com`).

### A3.1 Look up the billing account and its currency

```bash
gcloud billing accounts list
export BILLING_ACCOUNT_ID="XXXXXX-XXXXXX-XXXXXX"   # from the list above

# Check existing budgets to confirm the account's currency before
# picking an amount below - `gcloud billing budgets create` rejects a
# specifiedAmount in a currency that doesn't match the billing
# account's own currency, with a generic INVALID_ARGUMENT that names
# no field. Confirmed against thrwapp's real account: GBP, not USD -
# the commands below use GBP accordingly; adjust for yours.
gcloud billing budgets list --billing-account="$BILLING_ACCOUNT_ID" --billing-project="$GCP_PROJECT_AI"
```

Also note **`--billing-project`**: every `gcloud billing budgets ...`
command below needs it, set to a project where `billingbudgets.googleapis.com`
is actually enabled (A3.2 enables it on `$GCP_PROJECT_AI`). Without it,
gcloud checks API enablement against your ambient default `gcloud
config` project instead - not `$GCP_PROJECT_AI` - which fails with the
same generic error and no indication that project selection is the
actual problem.

### A3.2 Budget + kill switch on GCP_PROJECT_AI

```bash
# APIs needed to build and run the Cloud Function
gcloud services enable \
  cloudfunctions.googleapis.com \
  run.googleapis.com \
  eventarc.googleapis.com \
  pubsub.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  billingbudgets.googleapis.com \
  --project="$GCP_PROJECT_AI"

# Service account for the function, scoped to exactly one permission
gcloud iam service-accounts create budget-killswitch \
  --project="$GCP_PROJECT_AI" \
  --display-name="Budget kill switch (disables Vertex AI on overspend)"

gcloud projects add-iam-policy-binding "$GCP_PROJECT_AI" \
  --member="serviceAccount:budget-killswitch@${GCP_PROJECT_AI}.iam.gserviceaccount.com" \
  --role="roles/serviceusage.serviceUsageAdmin"

# Topic the budget will publish to
gcloud pubsub topics create budget-alerts-ai --project="$GCP_PROJECT_AI"

# Deploy the function - use an ABSOLUTE path for --source. A relative
# path only resolves if this command runs from the exact directory
# docs/ops/budget-killswitch was created under; "$(pwd)/..." avoids
# depending on that.
gcloud functions deploy stop-vertex-spend \
  --gen2 \
  --project="$GCP_PROJECT_AI" \
  --region="$GCP_REGION" \
  --runtime=python312 \
  --source="$(pwd)/docs/ops/budget-killswitch" \
  --entry-point=stop_vertex_spend \
  --trigger-topic=budget-alerts-ai \
  --service-account="budget-killswitch@${GCP_PROJECT_AI}.iam.gserviceaccount.com" \
  --set-env-vars="PROJECT_ID=${GCP_PROJECT_AI},PROJECT_NUMBER=${AI_PROJECT_NUMBER}" \
  --no-allow-unauthenticated

# The budget itself: alerts at 50/90/100%, and the 100% one also fires the function.
# Currency must match the billing account's own currency (A3.1) - GBP
# for thrwapp's real account, not USD as originally drafted.
gcloud billing budgets create \
  --billing-project="$GCP_PROJECT_AI" \
  --billing-account="$BILLING_ACCOUNT_ID" \
  --display-name="thrw-ai-monthly" \
  --budget-amount=50GBP \
  --filter-projects="projects/${AI_PROJECT_NUMBER}" \
  --threshold-rule=percent=0.5 \
  --threshold-rule=percent=0.9 \
  --threshold-rule=percent=1.0 \
  --notifications-rule-pubsub-topic="projects/${GCP_PROJECT_AI}/topics/budget-alerts-ai"
```

### A3.3 Budget on GCP_PROJECT_PROD (alert only, no kill switch)

```bash
export PROD_PROJECT_NUMBER=$(gcloud projects describe "$GCP_PROJECT_PROD" --format='value(projectNumber)')

gcloud billing budgets create \
  --billing-project="$GCP_PROJECT_PROD" \
  --billing-account="$BILLING_ACCOUNT_ID" \
  --display-name="thrw-prod-monthly" \
  --budget-amount=30GBP \
  --filter-projects="projects/${PROD_PROJECT_NUMBER}" \
  --threshold-rule=percent=0.5 \
  --threshold-rule=percent=0.9 \
  --threshold-rule=percent=1.0
```

No `--notifications-rule-pubsub-topic` here - default behavior is an
email to billing account admins at each threshold, nothing automated.

### A3.4 Verify, and recover if it ever fires

```bash
gcloud billing budgets list --billing-account="$BILLING_ACCOUNT_ID"

# If the AI project's Vertex API ever does get disabled by the kill switch:
gcloud services enable aiplatform.googleapis.com --project="$GCP_PROJECT_AI"
```

**Honesty check on this section, same as everywhere else in this
runbook:** the `gcloud billing budgets create` flags and the Service
Usage API disable call were verified against current documentation and
a real reference implementation before being written here, but the
Cloud Function itself has not been deployed and triggered end-to-end -
there's no way to safely generate real Vertex spend just to test it.
Consider triggering it manually once with a synthetic Pub/Sub message
(`{"costAmount": 999, "budgetAmount": 50}` base64-encoded in the
`message.data` field) before trusting it in anger.

---

## Part B — branch protection on `main`

```bash
gh repo edit "$GH_REPO" \
  --enable-squash-merge \
  --enable-merge-commit=false \
  --enable-rebase-merge=false \
  --delete-branch-on-merge

gh api "repos/${GH_REPO}/rulesets" --method POST --input - <<'EOF'
{
  "name": "main-trunk-protection",
  "target": "branch",
  "enforcement": "active",
  "conditions": {
    "ref_name": { "include": ["refs/heads/main"], "exclude": [] }
  },
  "rules": [
    {
      "type": "merge_queue",
      "parameters": {
        "merge_method": "SQUASH",
        "grouping_strategy": "ALLGREEN",
        "min_entries_to_merge": 1,
        "max_entries_to_merge": 5,
        "min_entries_to_merge_wait_minutes": 0,
        "max_entries_to_build": 5,
        "check_response_timeout_minutes": 60
      }
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": true,
        "required_status_checks": [
          { "context": "ci / lint" },
          { "context": "agent-eval / evaluate" }
        ]
      }
    },
    {
      "type": "pull_request",
      "parameters": {
        "dismiss_stale_reviews_on_push": false,
        "require_code_owner_review": true,
        "require_last_push_approval": false,
        "required_approving_review_count": 0,
        "required_review_thread_resolution": false
      }
    }
  ]
}
EOF

gh api "repos/${GH_REPO}/rulesets" --jq '.[].name'
```

Note on the "agent bypasses review outside CODEOWNERS" item from the
original plan: no bypass is actually needed. `required_approving_review_count: 0`
plus `require_code_owner_review: true` means only paths CODEOWNERS
matches (`services/**`, `.github/**`, `docs/adr/**`, pricing pages) need
any review at all - `packages/**` needs zero by construction. If a
blanket "require N approvals" rule is ever added later, *that's* when an
explicit `bypass_actors` entry for the `thrw-agent` App would be needed,
and that specific setting is web-UI-only (Settings → Rules → Rulesets →
the ruleset → Bypass list).

**Verified working, `pull_request` rule**: initially 422'd with just
`require_code_owner_review` and `required_approving_review_count` -
GitHub's schema requires the full five-field parameter set shown
above, not a partial one. The `merge_queue` and `required_status_checks`
rules were both *accepted* by the API on the first try - but accepted
is not the same as correct, see below.

**`required_status_checks` has a real first-PR bootstrapping trap -
read this before requiring any check by name.** On thrwapp/thrw's very
first PR after this ruleset went live, both `ci / lint` and
`agent-eval / evaluate` passed repeatedly and unambiguously on the
PR's own head commit, and the PR still sat forever on "Expected -
Waiting for status to be reported" for those exact two required-check
slots, blocking the merge queue indefinitely. What did **not** fix it:
adding `merge_group:` triggers to the workflows (necessary, real fix
for a different problem, but not this one); renaming the required
checks to literally include `(pull_request)` (that suffix is a
GitHub UI decoration showing which event triggered a check, never
literal context text - don't type it into a required-check name).
What we could not get to work at all via the API-constructed ruleset:
free-text/hand-written `context` strings for checks that had never
been reported anywhere in the repo before. The GitHub UI's own
required-check picker (Settings → Rules → Rulesets → the ruleset →
"Require status checks to pass" → the search box) showed **zero
suggestions** for these exact same check names, at the same time they
were visibly succeeding on the open PR - strong evidence GitHub's
required-status-check matching needs something beyond a bare context
string (most likely a specific GitHub App binding) that a hand-built
API payload doesn't easily supply, and that the UI's picker only
offers once it has independently seen a check reported somewhere it
recognizes.

The unblock that actually worked: remove the `required_status_checks`
rule entirely, let the PR merge through the queue (`merge_queue` +
`pull_request` rules alone are enough to require review + queue
ordering), and only *after* that real merge exists, re-add the
required checks - at that point the repo has enough history for
whatever the UI picker needs, and picking them from its dropdown
(never typing the context by hand) is the way to add them. If you're
setting this up fresh and hit the same empty-dropdown symptom on your
first PR, don't fight it: drop `required_status_checks` from the
initial ruleset, get one PR through, then add it back via the UI.

One more real mechanic worth knowing: on a merge-queue-required repo,
GitHub's "auto-merge" toggle and the PR page's "Merge when ready"
button fire the *identical* underlying event - they are not two
different mechanisms. What actually got PR #1 enqueued was disabling
auto-merge and then clicking "Merge when ready" directly, which
produced the same webhook event as every earlier attempt - so the fix
that worked was removing the blocking rule, not switching mechanisms.
Also: a job that's scheduled but can never complete (no matching
runner, e.g. `mac-ipad` needing self-hosted macOS) blocks auto-merge/
the queue even when it isn't in the required-checks list - GitHub
waits for every check suite on a PR to reach a terminal state, not
just the required ones. Gate such jobs behind a repo variable
(`if: vars.HAS_MACOS_RUNNER == 'true'`) so they skip cleanly instead of
queuing forever, rather than discovering this the way we did.

---

## Step B.5 — bootstrap the pipeline's labels (found missing on first real run)

`agent-triage.yml`, `agent-code.yml`, and `agent-eval.yml` all assume
`agent-ready`, `needs-spec`, `needs-human`, and `model:opus` already exist
as labels on the repo - none of the scaffolding prompts ever created them.
The first real smoke-test issue (#4) proved this the hard way: triage ran
end-to-end correctly (GCP WIF auth succeeded, `scripts/triage.py` scored
it 1.00, decided to apply `agent-ready`) and then the whole job failed
with `failed to update ...: 'agent-ready' not found`, so the issue was
never labeled and the rest of the chain (agent-code, agent-eval) never
triggered. Run this once, before opening any smoke-test issue:

```bash
gh label create agent-ready   --repo "$GH_REPO" --color 0E8A16 --description "Passed agent-triage; agent-code will pick it up"
gh label create needs-spec    --repo "$GH_REPO" --color D93F0B --description "Issue is missing required agent-task sections"
gh label create needs-human   --repo "$GH_REPO" --color B60205 --description "Agent hit a stop condition or failed evaluation; needs human attention"
gh label create model:opus    --repo "$GH_REPO" --color 5319E7 --description "Route this issue to Opus instead of Sonnet"
```

## Step C — Day-2 smoke test

Once Parts A and B (and B.5) are done: open a trivial issue using the
`agent-task.yml` template, and watch it flow triage → `agent-ready` label
→ agent-code run → PR → agent-eval → merge (or `needs-human` if something
fails). Report back what actually happened at each stage, including
partial completion - per AGENTS.md's honesty requirement.

Note: issue events only fire `agent-triage.yml` on `types: [opened]` -
closing/reopening an issue does not refire it, and neither does adding a
label by hand skip validating triage itself. If a smoke-test issue's
triage run fails for a fixable reason (like the missing labels above),
fix the root cause and open a *new* issue rather than trying to re-trigger
triage on the same one.
