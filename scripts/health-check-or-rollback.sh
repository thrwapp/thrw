#!/usr/bin/env bash
# Post-deploy health check for the relay VM.
#
# The health check itself is real: it curls the given URL and fails the
# job (exit 1) if the relay isn't healthy after a deploy. What's still a
# stub is the ROLLBACK - today a failure just fails the workflow; it does
# not yet roll the VM back to the previous container image.
#
# TODO(deploy): on failure, look up the previously-deployed image tag
# (e.g. from the Artifact Registry image history or a recorded deploy
# manifest) and re-run `gcloud compute instances update-container` with
# it, so a bad deploy self-heals instead of just alerting.
set -euo pipefail

HEALTH_URL="${1:?Usage: health-check-or-rollback.sh <health-check-url>}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-5}"
SLEEP_SECONDS="${SLEEP_SECONDS:-5}"

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  echo "Health check attempt ${attempt}/${MAX_ATTEMPTS}: ${HEALTH_URL}"
  if status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' "$HEALTH_URL"); then
    if [ "$status" -ge 200 ] && [ "$status" -lt 300 ]; then
      echo "Healthy (HTTP ${status})."
      exit 0
    fi
    echo "Unhealthy: HTTP ${status}."
  else
    echo "curl failed to reach ${HEALTH_URL}."
  fi
  sleep "$SLEEP_SECONDS"
done

echo "Relay failed its post-deploy health check after ${MAX_ATTEMPTS} attempts."
echo "TODO: roll back to the previous container image instead of just failing."
exit 1
