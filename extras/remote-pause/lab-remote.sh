#!/bin/bash
# Forced command for one restricted SSH key (see README.md): the only thing
# that key can run. Lets Home Assistant pause the heavy services (GPU, CPU)
# when the machine is wanted as a desktop, and bring them back.
#   pause   lab pause (stops containers labelled lab.tier=heavy)
#   resume  lab resume (starts everything enabled again)
#   status  "paused" when no heavy container runs, else "running"
#   doctor  lab doctor as one JSON line: {"bad", "warn", "problems",
#           "paused"}; while paused, the stopped heavy containers aren't
#           counted as problems
set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
LOG="${XDG_STATE_HOME:-$HOME/.local/state}/lab-remote.log"
mkdir -p "$(dirname "$LOG")"

heavy() { docker ps -q --filter label=lab.tier=heavy; }

cmd="${SSH_ORIGINAL_COMMAND:-status}"
case "$cmd" in
  pause|resume)
    echo "[$(date '+%F %T')] $cmd (from ${SSH_CLIENT%% *})" >> "$LOG"
    "$ROOT/lab" "$cmd" >> "$LOG" 2>&1 ;;
  status) ;;
  doctor)
    skip=""
    [ -z "$(heavy)" ] && skip="$(docker ps -a --filter label=lab.tier=heavy --format '{{.Names}}')"
    { "$ROOT/lab" doctor 2>&1 || true; } | sed 's/\x1b\[[0-9;]*m//g' | SKIP="$skip" python3 -c '
import json, os, sys
skip = [n for n in os.environ["SKIP"].split() if n]
bad, warn = [], []
lines = sys.stdin.read().splitlines()
if not any(l.startswith("==>") for l in lines):  # doctor itself did not run
    bad.append("lab doctor did not run: " + (lines[0].strip() if lines else "no output"))
    lines = []
for line in lines:
    t = line.strip()
    if t[:1] not in ("\u2718", "!") or any(n in t for n in skip):
        continue
    (bad if t[0] == "\u2718" else warn).append(t[1:].strip())
print(json.dumps({"bad": len(bad), "warn": len(warn), "problems": (bad + warn)[:10], "paused": bool(skip)}))'
    exit 0 ;;
  *) echo "usage: pause | resume | status | doctor" >&2; exit 2 ;;
esac
if [ -n "$(heavy)" ]; then echo running; else echo paused; fi
