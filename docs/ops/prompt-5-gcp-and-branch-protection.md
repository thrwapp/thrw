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

gh variable set GCP_VERTEX_REGION --repo "$GH_REPO" --body "$GCP_REGION"
gh variable set GCP_ARTIFACT_REGISTRY_REGION --repo "$GH_REPO" --body "$GCP_REGION"
gh variable set GCP_RELAY_ZONE --repo "$GH_REPO" --body "${GCP_REGION}-a"
gh variable set GCP_RELAY_VM_NAME --repo "$GH_REPO" --body "thrw-relay"   # confirm this matches the real VM name
gh variable set RELAY_HEALTH_URL --repo "$GH_REPO" --body "REPLACE_ME"   # real health endpoint, once known
```

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
        "require_code_owner_review": true,
        "required_approving_review_count": 0
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

**Caveat carried over from when this was first drafted:** the ruleset
JSON above hasn't been executed against a live repo - it's a best-effort
reading of the current GitHub Rulesets API schema, not a verified one.
It's safe to try (a rejected field just errors, nothing destructive) but
check https://docs.github.com/en/rest/repos/rules if anything is
rejected, rather than assuming the JSON is exactly right.

---

## Step C — Day-2 smoke test

Once Parts A and B are done: open a trivial issue using the
`agent-task.yml` template, and watch it flow triage → `agent-ready` label
→ agent-code run → PR → agent-eval → merge (or `needs-human` if something
fails). Report back what actually happened at each stage, including
partial completion - per AGENTS.md's honesty requirement.
