#!/bin/bash
# Redeploys the relay container on the relay VM to a new image, and
# ensures Caddy (TLS termination in front of EMQX, #119) is running.
# Run via SSH by deploy.yml's "Roll the relay VM" step (gcloud compute
# scp + ssh), not meant to be run by hand except for manual recovery.
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

USAGE="Usage: relay-redeploy.sh <image-ref> <artifact-registry-host> <base64-emqx-username> <base64-emqx-password> <relay-service-image-ref> <base64-thrw-relay-accounts>"
IMAGE_REF="${1:?$USAGE}"
ARTIFACT_HOST="${2:?$USAGE}"
# base64-encoded on the way in (deploy.yml) and decoded here, purely to
# avoid shell-quoting hazards for arbitrary credential content crossing
# two layers of quoting (this script's own args, inside gcloud compute
# ssh's --command string) - not a secrecy measure by itself.
EMQX_RELAY_USERNAME=$(printf '%s' "${3:?$USAGE}" | base64 -d)
EMQX_RELAY_PASSWORD=$(printf '%s' "${4:?$USAGE}" | base64 -d)
# #129: relay-service's own image and the accounts it manages. Same
# base64 treatment as the credential above, applied here for consistency
# even though THRW_RELAY_ACCOUNTS isn't itself secret.
RELAY_SERVICE_IMAGE_REF="${5:?$USAGE}"
THRW_RELAY_ACCOUNTS=$(printf '%s' "${6:?$USAGE}" | base64 -d)

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
docker pull "$RELAY_SERVICE_IMAGE_REF"
# Archive the outgoing container's logs before removing it (#207).
#
# `docker rm` destroys a container's logs with it, and this script runs on
# every relay change merged to main - so the record of what the relay did
# was being deleted routinely, and "what happened yesterday" had no
# answer. Adapters reconnect after a redeploy (#182) but their evidence
# does not come back.
#
# Best-effort by design: a failure to archive must never block a
# redeploy. Keeps the last 20 archives, which at this cadence is weeks.
# Under $HOME, not /var/log: nothing in this script uses sudo (docker
# runs via the SSH user's docker group), so /var/log/thrw would not be
# writable and archiving would silently do nothing - the failure mode
# this whole change exists to remove. Adding sudo for a log copy would
# be a privilege escalation in exchange for a nicer path.
LOG_ARCHIVE_DIR="${THRW_LOG_ARCHIVE_DIR:-$HOME/thrw-logs}"

archive_logs() {
  container="$1"
  if ! mkdir -p "$LOG_ARCHIVE_DIR"; then
    echo "WARNING: cannot create $LOG_ARCHIVE_DIR - $container logs will be lost on rm" >&2
    return 0
  fi
  if docker inspect "$container" >/dev/null 2>&1; then
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    target="$LOG_ARCHIVE_DIR/${container}-${stamp}.log"
    if docker logs "$container" > "$target" 2>&1; then
      echo "Archived $container logs to $target ($(wc -l < "$target") lines)"
    else
      echo "WARNING: could not archive $container logs" >&2
    fi
  fi
  # shellcheck disable=SC2012  # names are ours, no odd characters
  ls -1t "$LOG_ARCHIVE_DIR/${container}"-*.log 2>/dev/null | tail -n +21 | xargs -r rm -f || true
}

archive_logs relay
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

# Bounded live logs (#207). Docker's json-file driver is unbounded by
# default, so a long-lived container can fill the VM's disk - which on
# this single VM would take the broker down with it.
docker run -d --name relay --restart unless-stopped \
  --log-opt max-size=20m --log-opt max-file=5 \
  -p 8083:8083 -p 18083:18083 \
  --env-file "$ENV_FILE" \
  "$IMAGE_REF"

# Caddy (#119): TLS termination in front of EMQX's plaintext ws:8083 -
# see services/relay-hosted/Caddyfile's own comment for the architecture
# choice. Deliberately NOT torn down/recreated on every redeploy the way
# `relay` is above: this script runs on every EMQX image roll, but Caddy
# itself only needs touching when its own config changes, and recreating
# it needlessly would mean re-fetching/re-validating its Let's Encrypt
# cert more often than necessary. Idempotent instead: (re)write the
# Caddyfile at its stable path every run (cheap), then either start Caddy
# fresh or hot-reload its config into the already-running instance.
#
# deploy.yml's "Roll the relay VM" step scp's
# services/relay-hosted/Caddyfile next to this script, so it is resolved
# relative to wherever this script actually is rather than a fixed path
# (#180).
#
# That indirection is the fix, not a nicety: both files used to be
# uploaded to fixed paths under /tmp, which is sticky - only the owner
# may overwrite a file there. A single manual deploy left them owned by a
# human, after which every CI deploy (running as `runner`) failed on
# `scp: Permission denied` and could never recover on its own. That went
# unnoticed for two days while merged fixes sat undeployed.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CADDYFILE_DIR=/etc/caddy
mkdir -p "$CADDYFILE_DIR"
cp "$SCRIPT_DIR/Caddyfile" "$CADDYFILE_DIR/Caddyfile"

docker volume create caddy_data >/dev/null
docker volume create caddy_config >/dev/null

if docker ps --format '{{.Names}}' | grep -qx caddy; then
  # Zero-downtime: Caddy natively supports reloading its config without
  # dropping the TLS listener or an in-flight connection.
  docker exec caddy caddy reload --config /etc/caddy/Caddyfile
else
  docker run -d --name caddy --restart unless-stopped \
    --network host \
    -v "$CADDYFILE_DIR/Caddyfile:/etc/caddy/Caddyfile:ro" \
    -v caddy_data:/data \
    -v caddy_config:/config \
    caddy:2-alpine
fi

# relay-service (#118/#129): the live PriorityEngine/DeviceRegistry
# process. Torn down/recreated on every redeploy, same as `relay` above
# (not idempotent like `caddy`) - this *is* the thing being versioned by
# each deploy, unlike Caddy, which only needs touching when its own
# config changes.
#
# --network host, same as caddy: reaches EMQX directly via
# ws://localhost:8083/mqtt rather than round-tripping out through Caddy/
# TLS/DNS for a connection that never leaves this VM - EMQX's ws listener
# expects the /mqtt path (matches every adapter's own
# wss://relay.thrw.app/mqtt, see config/adapter.properties in each
# adapter package).
#
# MQTT credential: reuses the same shared EMQX_RELAY_USERNAME/PASSWORD
# `relay` itself authenticates with, rather than a second credential -
# acl.conf's ACL is currently `{allow, all, ...}` per the single-shared-
# credential interim model (#80), so a second credential would be
# functionally identical to this one right now, and inventing per-
# service credential management before services/accounts exists is
# premature (#129's own acceptance criteria asked this be a documented
# choice, not necessarily the more elaborate one).
archive_logs relay-service
docker stop relay-service || true
docker rm relay-service || true

# Same env-file discipline as $ENV_FILE above (not `-e` flags) - the
# credential must not sit in this process's own argv, visible to
# anything on the VM running `ps aux` while the container starts.
RELAY_SERVICE_ENV_FILE=$(mktemp)
chmod 600 "$RELAY_SERVICE_ENV_FILE"
trap 'rm -f "$ENV_FILE" "$RELAY_SERVICE_ENV_FILE"' EXIT
{
  printf 'THRW_RELAY_ACCOUNTS=%s\n' "$THRW_RELAY_ACCOUNTS"
  printf 'MQTT_BROKER_URL=ws://localhost:8083/mqtt\n'
  printf 'EMQX_RELAY_USERNAME=%s\n' "$EMQX_RELAY_USERNAME"
  printf 'EMQX_RELAY_PASSWORD=%s\n' "$EMQX_RELAY_PASSWORD"
} > "$RELAY_SERVICE_ENV_FILE"

docker run -d --name relay-service --restart unless-stopped \
  --log-opt max-size=20m --log-opt max-file=5 \
  --network host \
  --env-file "$RELAY_SERVICE_ENV_FILE" \
  "$RELAY_SERVICE_IMAGE_REF"
