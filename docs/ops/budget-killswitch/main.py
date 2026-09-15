"""Cloud Function (2nd gen, Pub/Sub-triggered) that disables the Vertex AI
API on GCP_PROJECT_AI when its budget threshold is reached.

Deliberately scoped narrower than the common "detach billing" kill-switch
pattern: disabling billing on a project can permanently destroy resources
in it (per Google's own reference implementation's warning), which here
would risk the WIF pool and service accounts set up alongside this
project. Disabling just the Vertex AI API stops the actual cost driver
(agent-triage/agent-code/agent-eval/release-announce all call Vertex)
without touching anything else, and is trivially, safely reversible:

    gcloud services enable aiplatform.googleapis.com --project=<project>

See docs/ops/prompt-5-gcp-and-branch-protection.md, Part A3.
"""

import base64
import json
import os

from googleapiclient import discovery

PROJECT_ID = os.environ["PROJECT_ID"]
PROJECT_NUMBER = os.environ["PROJECT_NUMBER"]
SERVICE_TO_DISABLE = "aiplatform.googleapis.com"


def stop_vertex_spend(cloud_event):
    data = cloud_event.data["message"]["data"]
    budget_data = json.loads(base64.b64decode(data).decode("utf-8"))

    cost_amount = budget_data["costAmount"]
    budget_amount = budget_data["budgetAmount"]

    if cost_amount <= budget_amount:
        print(f"No action necessary. (cost={cost_amount}, budget={budget_amount})")
        return

    service_usage = discovery.build("serviceusage", "v1", cache_discovery=False)
    service_name = f"projects/{PROJECT_NUMBER}/services/{SERVICE_TO_DISABLE}"

    try:
        state = service_usage.services().get(name=service_name).execute()
        if state.get("state") == "DISABLED":
            print(f"{SERVICE_TO_DISABLE} is already disabled on {PROJECT_ID}.")
            return
    except Exception as exc:  # noqa: BLE001 - log and proceed regardless
        print(f"Could not check current service state, disabling anyway: {exc}")

    try:
        result = service_usage.services().disable(name=service_name, body={}).execute()
        print(f"Disabled {SERVICE_TO_DISABLE} on {PROJECT_ID}: {json.dumps(result)}")
    except Exception as exc:  # noqa: BLE001 - surface as a function failure
        print(f"Failed to disable {SERVICE_TO_DISABLE} on {PROJECT_ID}: {exc}")
        raise
