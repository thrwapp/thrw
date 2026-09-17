#!/bin/bash
# Redeploys the relay container on the relay VM to a new image. Run via
# SSH by deploy.yml's "Roll the relay VM" step (gcloud compute scp + ssh),
# not meant to be run by hand except for manual recovery.
#
# gcloud compute instances update-container / create-with-container (the
# Container-Optimized OS + container-startup-agent approach) is
# discontinued by Google as of this writing - confirmed live, a real
# create-with-container attempt was outright refused with "the option to
# deploy a container during VM instance creation that relies on a
# container startup agent is discontinued." The relay VM is a plain
# Debian image instead, so redeploying its container means SSHing in and
# running Docker directly - there's no GCE API call left that does this
# for a non-Container-Optimized-OS instance.
set -euo pipefail

USAGE="Usage: relay-redeploy.sh <image-ref> <artifact-registry-host> <base64-emqx-username> <base64-emqx-password>"
IMAGE_REF="${1:?$USAGE}"
ARTIFACT_HOST="${2:?$USAGE}"
# base64-encoded on the way in (deploy.yml) and decoded here, purely to
# avoid shell-quoting hazards for arbitrary credential content crossing
# two layers of quoting (this script's own args, inside gcloud compute
# ssh's --command string) - not a secrecy measure by itself.
EMQX_RELAY_USERNAME=$(printf '%s' "${3:?$USAGE}" | base64 -d)
EMQX_RELAY_PASSWORD=$(printf '%s' "${4:?$USAGE}" | base64 -d)

# Compute Engine's metadata server hands the VM's attached service account
# a short-lived access token - used directly as the Docker registry
# password rather than installing the full gcloud CLI on the VM just for
# `gcloud auth configure-docker` (a much bigger footprint on a plain,
# non-Container-Optimized-OS image than this VM needs otherwise).
ACCESS_TOKEN=$(curl -s -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" \
  | grep -o '"access_token":"[^"]*' | cut -d'"' -f4)

echo "$ACCESS_TOKEN" | docker login -u oauth2accesstoken --password-stdin "https://${ARTIFACT_HOST}"
docker pull "$IMAGE_REF"
docker stop relay || true
docker rm relay || true

# services/relay-hosted/docker-entrypoint-relay.sh requires these two at
# container start (confirmed live: the container crash-looped without
# them - "EMQX_RELAY_USERNAME must be set"). Written to a restricted-
# permission env file rather than passed as `-e` flags directly, so the
# credential doesn't sit in this process's own argv (visible to anything
# on the VM running `ps aux` while the container starts).
ENV_FILE=$(mktemp)
chmod 600 "$ENV_FILE"
trap 'rm -f "$ENV_FILE"' EXIT
{
  printf 'EMQX_RELAY_USERNAME=%s\n' "$EMQX_RELAY_USERNAME"
  printf 'EMQX_RELAY_PASSWORD=%s\n' "$EMQX_RELAY_PASSWORD"
} > "$ENV_FILE"

docker run -d --name relay --restart unless-stopped \
  -p 8083:8083 -p 18083:18083 \
  --env-file "$ENV_FILE" \
  "$IMAGE_REF"
