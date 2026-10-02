#!/bin/bash
# Forced command for one restricted SSH key (see README.md): the only thing
# that key can run. Lets Home Assistant pause the heavy services (GPU, CPU)
# when the machine is wanted as a desktop, and bring them back.
#   pause   lab pause (stops containers labelled lab.tier=heavy)
#   resume  lab resume (starts everything enabled again)
#   status  "paused" when no heavy container runs, else "running"
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
  *) echo "usage: pause | resume | status" >&2; exit 2 ;;
esac
if [ -n "$(heavy)" ]; then echo running; else echo paused; fi
