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
#
# /var/log/thrw, world-readable. The comment that used to sit here
# argued for $HOME over /var/log because "nothing in this script uses
# sudo", so /var/log/thrw would not be writable. That premise was
# false: deploy.yml invokes this script as `sudo bash
# ~/relay-redeploy.sh`, so it runs as root and $HOME is /root. The one
# path it chose to avoid was writable all along, and the path it chose
# instead is mode 0700 - `gcloud compute ssh` lands an interactive user
# as themselves, not root, so $HOME/thrw-logs did not exist for the
# humans the archive exists for. The archives were being written
# correctly and reported in the deploy output, and were still
# unreachable (#241). That cost a real investigation during #236, where
# they looked absent rather than unreadable.
#
# So: a fixed, world-readable path outside any home directory, plus the
# readability probe below. "Wrote the file" and "a human can read the
# file" are different claims, and only the second one is the point.
#
# What lands here is operational events only - holder changes, route
# drift, broker connection lines carrying account and node ids. The
# shared EMQX credential does not appear in either container's stdout:
# docker-entrypoint-relay.sh writes it to a mode-0600 file inside the
# container, and this script passes it through a mode-0600 env file
# rather than argv.
#
# THRW_LOG_ARCHIVE_DIR still overrides, for a manual recovery run made
# without root where /var/log is not writable.
LOG_ARCHIVE_DIR="${THRW_LOG_ARCHIVE_DIR:-/var/log/thrw}"
# Where archives landed before #241. Both entries, because a CI run has
# $HOME=/root while a by-hand run does not; when they coincide the
# second pass simply finds nothing.
LEGACY_LOG_ARCHIVE_DIRS=(/root/thrw-logs "$HOME/thrw-logs")

ensure_archive_dir() {
  if ! mkdir -p "$LOG_ARCHIVE_DIR" 2>/dev/null; then
    return 1
  fi
  # mkdir -p honours umask, so root's umask would otherwise decide who
  # can reach this directory - which is the entire bug in #241.
  chmod 755 "$LOG_ARCHIVE_DIR" 2>/dev/null || true
}

# Can an ordinary, non-root user actually read $1? Probed by reading it
# as `nobody`, not by inspecting one path's mode bits: readability also
# depends on traversal permission on every ancestor directory, which a
# single stat cannot tell you - and an unreadable ancestor is exactly
# how #241 happened.
#
# Returns 2 for "cannot tell" when this run is not root (dropping
# privileges needs root), which is reported as such rather than as a
# failure - a manual recovery run should not print a warning it has no
# evidence for.
readable_without_sudo() {
  if [ "$(id -u)" -ne 0 ]; then
    return 2
  fi
  su -s /bin/sh -c "head -c 1 -- '$1' >/dev/null" nobody >/dev/null 2>&1
}

# One-time move of the pre-#241 archives into the readable location.
# Moved rather than copied: a second copy left behind in an unreadable
# directory is how this went unnoticed for as long as it did. Names are
# timestamped per container, so `mv -n` cannot quietly drop a distinct
# archive - and it will not overwrite one if it somehow collides.
migrate_legacy_archives() {
  if ! ensure_archive_dir; then
    return 0
  fi
  for legacy in "${LEGACY_LOG_ARCHIVE_DIRS[@]}"; do
    if [ ! -d "$legacy" ] || [ "$legacy" = "$LOG_ARCHIVE_DIR" ]; then
      continue
    fi
    moved=0
    for f in "$legacy"/*.log; do
      [ -e "$f" ] || continue
      if mv -n "$f" "$LOG_ARCHIVE_DIR/" 2>/dev/null; then
        moved=$((moved + 1))
      else
        echo "WARNING: could not move $f to $LOG_ARCHIVE_DIR - it stays unreadable there" >&2
      fi
    done
    if [ "$moved" -gt 0 ]; then
      chmod 644 "$LOG_ARCHIVE_DIR"/*.log 2>/dev/null || true
      echo "Migrated $moved archived log file(s) from $legacy to $LOG_ARCHIVE_DIR (#241)"
    fi
    if rmdir "$legacy" 2>/dev/null; then
      echo "Removed now-empty $legacy"
    fi
  done
}

archive_logs() {
  container="$1"
  if ! ensure_archive_dir; then
    echo "WARNING: cannot create $LOG_ARCHIVE_DIR - $container logs will be lost on rm" >&2
    return 0
  fi
  if docker inspect "$container" >/dev/null 2>&1; then
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    target="$LOG_ARCHIVE_DIR/${container}-${stamp}.log"
    if docker logs "$container" > "$target" 2>&1; then
      chmod 644 "$target" 2>/dev/null || true
      echo "Archived $container logs to $target ($(wc -l < "$target") lines)"
      # #241: say in the deploy output whether the thing just written is
      # reachable, instead of succeeding quietly into a path no human
      # can open. This line is the difference between the two.
      readable_without_sudo "$target" && probe=0 || probe=$?
      case "$probe" in
        0) echo "  Readable without sudo: yes - verified by reading it as an unprivileged user" ;;
        2) echo "  Readable without sudo: not checked - this run is not root, so it cannot drop privileges to test" ;;
        *) echo "WARNING: $target is NOT readable without sudo - an interactive SSH user cannot read this archive (#241)" >&2 ;;
      esac
    else
      echo "WARNING: could not archive $container logs" >&2
    fi
  fi
  # shellcheck disable=SC2012  # names are ours, no odd characters
  ls -1t "$LOG_ARCHIVE_DIR/${container}"-*.log 2>/dev/null | tail -n +21 | xargs -r rm -f || true
}

migrate_legacy_archives
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
