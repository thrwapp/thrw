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

IMAGE_REF="${1:?Usage: relay-redeploy.sh <image-ref> <artifact-registry-host>}"
ARTIFACT_HOST="${2:?Usage: relay-redeploy.sh <image-ref> <artifact-registry-host>}"

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
docker run -d --name relay --restart unless-stopped -p 8083:8083 -p 18083:18083 "$IMAGE_REF"
