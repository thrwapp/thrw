#!/bin/bash
# Captures all three logs of a thrw handover at once, into one run
# directory, for the #193 QA pass.
#
# ## Why this exists
#
# Every bug found in the week before this was written (#282, #295, #298,
# #301) was diagnosed by correlating a physical action against the relay's
# decision at that moment. Doing that by hand lost two captures outright:
#
#   - Swift `print` block-buffers when stdout is not a terminal, so a live
#     capture produced nothing until the process exited.
#   - `adb logcat` overran the device's ring buffer mid-session and died
#     with "Unexpected EOF", taking the window of interest with it.
#
# Both are addressed below rather than hoped about. The third source, the
# relay, could only be polled until `relay-logs.sh --follow` was added
# alongside this.
#
# ## Usage
#
#   ./scripts/qa-capture.sh start [name]   # begin capturing
#   ./scripts/qa-capture.sh mark "text"    # timestamp a physical action
#   ./scripts/qa-capture.sh status         # are the captures still alive?
#   ./scripts/qa-capture.sh stop           # end, and print where it landed
#   ./scripts/qa-capture.sh merge          # one time-ordered view of a run
#
# `mark` is the part that matters. A log says what thrw did; only a mark
# says what the human did, and a handover with no recorded cause is the
# thing this pass exists to stop producing.
#
# Runs land in $THRW_QA_DIR (default ~/thrw-qa-runs/<timestamp>-<name>),
# deliberately outside the repo so a capture is never a dirty worktree.
set -uo pipefail

QA_ROOT="${THRW_QA_DIR:-$HOME/thrw-qa-runs}"
CURRENT="$QA_ROOT/.current"
MAC_SUBSYSTEM="app.thrw.mac"
ANDROID_PKG="app.thrw.android"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "qa-capture: $*" >&2; exit 1; }

# ISO-8601 in UTC, to match the relay's own `ts` field exactly. The Mac
# logs in local time and adb in device-local time, so the merged view
# below is the only place the three are made comparable - having marks in
# the relay's own timebase is what makes that conversion checkable.
now_utc() { date -u +%Y-%m-%dT%H:%M:%S.000Z; }

run_dir() {
  [ -f "$CURRENT" ] || die "no capture running - './scripts/qa-capture.sh start' first"
  cat "$CURRENT"
}

cmd_start() {
  [ -f "$CURRENT" ] && die "a capture is already running in $(cat "$CURRENT") - stop it first"

  local name="${1:-pass}"
  local dir="$QA_ROOT/$(date -u +%Y%m%dT%H%M%SZ)-$name"
  mkdir -p "$dir" || die "could not create $dir"

  {
    echo "run:      $name"
    echo "started:  $(now_utc)"
    echo "mac app:  $(defaults read /Applications/AdapterMac.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || echo 'not installed in /Applications')"
    echo "android:  $(adb shell dumpsys package "$ANDROID_PKG" 2>/dev/null | awk -F= '/versionName=/{print $2; exit}' || echo 'no device')"
    echo "git:      $(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  } > "$dir/run.txt"

  # --- Android -----------------------------------------------------
  # The "Unexpected EOF" overrun that lost a capture is a *reading*
  # problem, not a device-buffer one: the window of interest is evicted
  # while nobody is draining it. Writing continuously to a file from the
  # first second is the fix, and it is what this does.
  #
  # Deliberately not `-G 16M`: on the Pixel 10 Pro that invocation never
  # returns (verified 2026-09-25 - it behaves like a follow rather than
  # setting the size and exiting), so it hangs `start` and the capture
  # that follows it dies. Deliberately not `-c` either: clearing races
  # with the reader and buys nothing once -T is used.
  #
  # `-T 1` starts one line back rather than replaying the whole ring,
  # so the file holds the run and not the hour before it. `-b all`
  # because the interesting lines are split across main, system and
  # events.
  if adb get-state >/dev/null 2>&1; then
    adb logcat -b all -v threadtime -T 1 > "$dir/android.log" 2>"$dir/android.err" &
    echo $! > "$dir/.android.pid"
  else
    echo "qa-capture: no adb device - skipping Android capture" >&2
    echo "no device at start" > "$dir/android.err"
  fi

  # --- macOS -------------------------------------------------------
  # `log stream` on the unified log, not the app's stdout: os.Logger
  # writes there (AdapterLog.swift) and it does not block-buffer the way
  # a redirected `print` does. ndjson so the merge below can parse it
  # rather than regex it.
  #
  # Note `--level info`: os_log info-level records are memory-backed and
  # are NOT retained for a later `log show`. Streaming is therefore the
  # only way to keep them, unless persistence is enabled first - see
  # docs/testing/qa-pass-193.md.
  /usr/bin/log stream --predicate "subsystem == \"$MAC_SUBSYSTEM\"" \
    --level info --style ndjson > "$dir/mac.ndjson" 2>"$dir/mac.err" &
  echo $! > "$dir/.mac.pid"

  # --- relay -------------------------------------------------------
  "$SCRIPT_DIR/relay-logs.sh" --follow relay-service > "$dir/relay.ndjson" 2>"$dir/relay.err" &
  echo $! > "$dir/.relay.pid"

  echo "$dir" > "$CURRENT"
  sleep 3
  cmd_status
  echo
  echo "Capturing into $dir"
  echo "Mark every physical action:  ./scripts/qa-capture.sh mark \"played YouTube on Mac\""
}

alive() { [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null; }

cmd_status() {
  local dir; dir="$(run_dir)"
  local bad=0
  for s in android mac relay; do
    local pidfile="$dir/.$s.pid"
    if alive "$pidfile"; then
      # cat-into-wc rather than `wc -l < glob`: the capture file is
      # .log for one source and .ndjson for the others, and a glob on
      # the left of `<` is an ambiguous redirect, not a file list.
      printf "  %-8s capturing (pid %s, %s lines)\n" "$s" "$(cat "$pidfile")" \
        "$(cat "$dir/$s".* 2>/dev/null | wc -l | tr -d ' ')"
    elif [ -f "$pidfile" ]; then
      printf "  %-8s DEAD - see %s\n" "$s" "$dir/$s.err"
      bad=1
    else
      printf "  %-8s not started\n" "$s"
    fi
  done
  # A dead capture that is only noticed at `stop` has already lost the
  # run. Non-zero here so a watcher can catch it while it still matters.
  return $bad
}

cmd_mark() {
  local dir; dir="$(run_dir)"
  [ $# -gt 0 ] || die "mark needs a description"
  printf '{"ts":"%s","event":"mark","text":%s}\n' "$(now_utc)" \
    "$(printf '%s' "$*" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
    >> "$dir/marks.ndjson"
  echo "marked: $*"
}

cmd_stop() {
  local dir; dir="$(run_dir)"
  for s in android mac relay; do
    local pidfile="$dir/.$s.pid"
    [ -f "$pidfile" ] && kill "$(cat "$pidfile")" 2>/dev/null
    rm -f "$pidfile"
  done
  echo "stopped: $(now_utc)" >> "$dir/run.txt"
  rm -f "$CURRENT"
  echo "Capture stopped. Run directory:"
  echo "  $dir"
  wc -l "$dir"/*.ndjson "$dir"/*.log 2>/dev/null | sed 's|'"$dir"'/||'
  echo
  echo "Merged view:  ./scripts/qa-capture.sh merge $dir"
}

# One time-ordered stream of marks + relay decisions, which is the view
# that actually answers "why did it switch then?". Deliberately only
# these two: the per-device logs stay on disk for when a specific
# decision needs explaining, but interleaving all four produces a wall
# of Bluetooth chatter nobody reads.
cmd_merge() {
  local dir="${1:-$(run_dir)}"
  python3 - "$dir" <<'PY'
import json, sys, pathlib
d = pathlib.Path(sys.argv[1])
rows = []
for name, kind in (("marks.ndjson", "MARK"), ("relay.ndjson", "relay")):
    f = d / name
    if not f.exists():
        continue
    for line in f.read_text(errors="replace").splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            o = json.loads(line)
        except ValueError:
            continue
        ts = o.get("ts")
        if not ts:
            continue
        if kind == "MARK":
            rows.append((ts, "MARK", o.get("text", "")))
        else:
            ev = o.get("event", "?")
            rest = {k: v for k, v in o.items() if k not in ("ts", "event", "account")}
            # Node ids are UUIDs and unreadable at a glance; the last 4
            # characters are enough to tell the two reference devices apart.
            for k in ("node", "from", "to", "holderBefore", "holderAfter", "believedHolder"):
                if isinstance(rest.get(k), str) and len(rest[k]) > 8:
                    rest[k] = "…" + rest[k][-4:]
            rows.append((ts, ev, " ".join(f"{k}={v}" for k, v in rest.items() if v is not None)))
rows.sort(key=lambda r: r[0])
if not rows:
    print("nothing to merge in", d)
for ts, ev, text in rows:
    marker = ">>>" if ev == "MARK" else "   "
    print(f"{marker} {ts[11:23]}  {ev:<16} {text}")
PY
}

case "${1:---help}" in
  start)  shift; cmd_start "$@" ;;
  mark)   shift; cmd_mark "$@" ;;
  status) cmd_status ;;
  stop)   cmd_stop ;;
  merge)  shift; cmd_merge "$@" ;;
  --help | -h) sed -n '/^# ## Usage/,/^# Runs land/p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command: $1 (try --help)" ;;
esac
