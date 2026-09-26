#!/bin/bash
# Reads the relay VM's logs from a repo checkout, over `gcloud compute
# ssh` - both the live containers and the archives relay-redeploy.sh
# keeps across redeploys (#207).
#
# Written for #241, whose criterion 5 names this script. It did not
# exist: #207 built the writing half (archive before `docker rm`) and
# nothing on the reading half, which is how archives spent two weeks in
# a mode-0700 /root/thrw-logs with the deploy output cheerfully
# reporting them. `--archives` deliberately uses no sudo, so it fails
# if that regresses instead of papering over it.
#
# Usage:
#   ./scripts/relay-logs.sh --archives            # list archived logs
#   ./scripts/relay-logs.sh --cat <filename>      # print one archive
#   ./scripts/relay-logs.sh --live [container]    # live container logs
#   ./scripts/relay-logs.sh --follow [container]  # live logs, streaming
#
# Env overrides (defaults match deploy.yml's):
#   GCP_RELAY_VM_NAME (thrw-relay), GCP_RELAY_ZONE (us-central1-a),
#   GCP_PROJECT_PROD (gcloud's configured project),
#   THRW_LOG_ARCHIVE_DIR (/var/log/thrw)
set -euo pipefail

VM="${GCP_RELAY_VM_NAME:-thrw-relay}"
ZONE="${GCP_RELAY_ZONE:-us-central1-a}"
PROJECT="${GCP_PROJECT_PROD:-$(gcloud config get-value project 2>/dev/null)}"
ARCHIVE_DIR="${THRW_LOG_ARCHIVE_DIR:-/var/log/thrw}"
TAIL_LINES="${THRW_LOG_TAIL:-200}"

usage() {
  sed -n '/^# Usage:/,/^#   THRW_LOG/p' "$0" | sed 's/^# \{0,1\}//'
}

if [ -z "$PROJECT" ]; then
  echo "relay-logs: no project - set GCP_PROJECT_PROD or run 'gcloud config set project'" >&2
  exit 2
fi

# --tunnel-through-iap: the relay VM has no public SSH path, same as
# deploy.yml's own access to it.
remote() {
  gcloud compute ssh "$VM" --zone="$ZONE" --project="$PROJECT" \
    --tunnel-through-iap --command="$1"
}

# Single-quoted, so $dir and friends below are expanded by the *remote*
# shell, not this one. The directory crosses over as THRW_DIR, prefixed
# onto the command string by each caller.
REMOTE_LIST='
dir="$THRW_DIR"
if [ ! -d "$dir" ]; then
  echo "relay-logs: no archive directory at $dir on $(hostname -s)." >&2
  echo "relay-logs: it is created by the next redeploy (scripts/relay-redeploy.sh)." >&2
  exit 1
fi
if ! ls -A "$dir" >/dev/null 2>&1; then
  echo "relay-logs: $dir exists but $(id -un) cannot list it without sudo." >&2
  echo "relay-logs: that is #241 recurring - the archive is unreachable, not missing." >&2
  exit 1
fi
listing=$(
  for f in "$dir"/*.log; do
    [ -e "$f" ] || continue
    if [ -r "$f" ]; then
      lines="$(wc -l < "$f")"
    else
      lines="unreadable"
    fi
    printf "%s  %6s  %8s lines  %s\n" \
      "$(date -ur "$f" +%Y-%m-%dT%H:%M:%SZ)" \
      "$(du -h "$f" | cut -f1)" \
      "$lines" \
      "$(basename "$f")"
  done | sort -r
)
if [ -z "$listing" ]; then
  echo "relay-logs: $dir is empty - no redeploy has archived anything yet." >&2
  exit 1
fi
echo "Archived relay logs in $dir, read as $(id -un) with no sudo:"
printf "%s\n" "$listing"
if printf "%s\n" "$listing" | grep -q unreadable; then
  echo "relay-logs: some files above need sudo to read - see #241." >&2
  exit 1
fi
'

REMOTE_CAT='
f="$THRW_DIR/$THRW_FILE"
if [ ! -e "$f" ]; then
  echo "relay-logs: no such archive: $f" >&2
  exit 1
fi
if [ ! -r "$f" ]; then
  echo "relay-logs: $f is not readable by $(id -un) without sudo - see #241." >&2
  exit 1
fi
cat "$f"
'

# Live logs are a different question from the archives: docker itself
# needs privileges, so this one may legitimately use sudo. It tries
# without first, because GCE's guest agent puts SSH users in the docker
# group.
REMOTE_LIVE='
c="$THRW_CONTAINER"
n="$THRW_TAIL"
if docker logs --tail "$n" "$c" 2>&1; then
  exit 0
fi
echo "relay-logs: retrying with sudo (no docker group access)" >&2
sudo docker logs --tail "$n" "$c" 2>&1
'

# --follow is --live that does not return. Added for #193: a QA pass has
# to correlate a physical action against what the relay decided at that
# moment, and `--live` can only be polled - which either misses lines
# between polls or re-prints the same tail.
#
# `docker logs -f` inherits the SSH session's lifetime, so closing this
# end (Ctrl-C, or the capture script's trap) ends the remote process
# too. The `--tail` is deliberately small: the point here is what
# happens next, not what already happened, and --archives covers the
# past.
REMOTE_FOLLOW='
c="$THRW_CONTAINER"
n="$THRW_TAIL"
if docker logs --tail "$n" -f "$c" 2>&1; then
  exit 0
fi
echo "relay-logs: retrying with sudo (no docker group access)" >&2
sudo docker logs --tail "$n" -f "$c" 2>&1
'

case "${1:---help}" in
  --archives)
    remote "THRW_DIR='$ARCHIVE_DIR'$REMOTE_LIST"
    ;;
  --cat)
    if [ $# -lt 2 ]; then
      echo "relay-logs: --cat needs a filename (see --archives)" >&2
      exit 2
    fi
    remote "THRW_DIR='$ARCHIVE_DIR' THRW_FILE='$2'$REMOTE_CAT"
    ;;
  --live)
    remote "THRW_CONTAINER='${2:-relay-service}' THRW_TAIL='$TAIL_LINES'$REMOTE_LIVE"
    ;;
  --follow)
    remote "THRW_CONTAINER='${2:-relay-service}' THRW_TAIL='${THRW_FOLLOW_TAIL:-5}'$REMOTE_FOLLOW"
    ;;
  --help | -h)
    usage
    ;;
  *)
    echo "relay-logs: unknown option: $1" >&2
    usage >&2
    exit 2
    ;;
esac
