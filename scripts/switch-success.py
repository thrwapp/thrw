#!/usr/bin/env python3
"""Compute switch success rate from archived relay logs (#207).

Usage:
    ./scripts/relay-logs.sh --archives                  # what exists
    ./scripts/relay-logs.sh --cat <file> > /tmp/a.log   # pull one
    ./scripts/switch-success.py /tmp/*.log

It reports its own weaknesses - orphaned outcomes, switches with no
outcome - rather than dropping them silently, because on the first real
run those two numbers mattered more than the rate did.


`scenarios.md`'s exit criterion 3 asks for ">= 99% switch success,
computed from persisted command outcomes (#207)". Its own definition says
the denominator is "every switch that should have happened, not every
command sent". Those two do not line up, and this is an attempt to
actually satisfy the definition rather than count outcomes.

Rules implemented, each with the reason:

1. A SWITCH is a `holder_change`, not a command. ADR 0002's sequential
   handoff means one change emits a RELEASE to the outgoing holder and a
   CLAIM to the incoming one - two outcomes, one switch.

2. A switch SUCCEEDS only if every command it comprises succeeded. A
   release that worked and a claim that timed out is one wholly failed
   switch, not 50%: the user's headset did not move.

3. `superseded_by_newer_command` is EXCLUDED from both numerator and
   denominator. It is ADR 0020's coalescing working correctly (#206
   criterion 5), and counting it would drop the rate every time the
   debouncer did its job.

4. Commands are attributed to the most recent preceding holder_change for
   the same (account, resource). Outcomes carry no correlation id, so
   this is the only join available - and its weakness is reported rather
   than hidden (see `orphans`).
"""

import glob
import json
import sys
from collections import defaultdict

WINDOW_MS = 30_000  # a command belongs to a switch only if it lands within this


def parse(paths):
    rows = []
    for path in paths:
        with open(path, errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line.startswith("{"):
                    continue
                try:
                    rows.append(json.loads(line))
                except ValueError:
                    continue
    rows.sort(key=lambda r: r.get("ts", ""))
    return rows


def ms(ts):
    # 2026-09-29T16:40:33.010Z
    from datetime import datetime

    return datetime.strptime(ts, "%Y-%m-%dT%H:%M:%S.%fZ").timestamp() * 1000


def main(paths):
    rows = parse(paths)
    switches = []  # each: dict(ts, account, resource, from, to, outcomes=[])
    open_switch = {}  # (account, resource) -> switch

    orphans = 0
    superseded = 0
    outcomes_total = 0

    for r in rows:
        ev = r.get("event")
        if ev == "holder_change":
            key = (r.get("account"), r.get("resource"))
            sw = {
                "ts": r.get("ts"),
                "account": r.get("account"),
                "resource": r.get("resource"),
                "from": r.get("from"),
                "to": r.get("to"),
                "outcomes": [],
            }
            switches.append(sw)
            open_switch[key] = sw
        elif ev == "command_outcome":
            outcomes_total += 1
            if r.get("reason") == "superseded_by_newer_command":
                superseded += 1
                continue  # rule 3
            key = (r.get("account"), r.get("resource"))
            sw = open_switch.get(key)
            if sw is None:
                orphans += 1
                continue
            try:
                if ms(r["ts"]) - ms(sw["ts"]) > WINDOW_MS:
                    orphans += 1
                    continue
            except Exception:
                pass
            sw["outcomes"].append(r)

    # Rule 1+2.
    scored = [s for s in switches if s["outcomes"]]
    unobserved = len(switches) - len(scored)
    succeeded = [
        s for s in scored if all(o.get("outcome") == "succeeded" for o in s["outcomes"])
    ]

    print(f"lines parsed              {len(rows)}")
    print(f"command_outcome events    {outcomes_total}")
    print(f"  superseded (excluded)   {superseded}")
    print(f"  orphaned (no switch)    {orphans}")
    print()
    print(f"holder_change (switches)  {len(switches)}")
    print(f"  with >=1 outcome        {len(scored)}")
    print(f"  with none               {unobserved}")
    print()
    if scored:
        rate = 100.0 * len(succeeded) / len(scored)
        print(f"SWITCH SUCCESS            {len(succeeded)}/{len(scored)} = {rate:.1f}%")
    naive = [r for r in rows if r.get("event") == "command_outcome"]
    if naive:
        ok = [r for r in naive if r.get("outcome") == "succeeded"]
        print(
            f"(naive per-command rate   {len(ok)}/{len(naive)} = "
            f"{100.0*len(ok)/len(naive):.1f}%  <- what a simple query gives)"
        )

    # How many commands per switch, to show rule 1 matters.
    dist = defaultdict(int)
    for s in scored:
        dist[len(s["outcomes"])] += 1
    print()
    print("outcomes per switch       " + ", ".join(f"{k}:{v}" for k, v in sorted(dist.items())))

    # Failure breakdown.
    fails = defaultdict(int)
    for s in scored:
        for o in s["outcomes"]:
            if o.get("outcome") != "succeeded":
                fails[f"{o.get('outcome')}/{o.get('reason')}"] += 1
    if fails:
        print("failure modes             " + ", ".join(f"{k}={v}" for k, v in sorted(fails.items())))


if __name__ == "__main__":
    paths = sys.argv[1:] or sorted(glob.glob("relaylogs/*.log"))
    if not paths:
        print("no logs given", file=sys.stderr)
        sys.exit(2)
    main(paths)
