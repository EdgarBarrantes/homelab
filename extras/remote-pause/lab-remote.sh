#!/bin/bash
# Forced command for one restricted SSH key (see README.md): the only thing
# that key can run. Lets Home Assistant pause the heavy services (GPU, CPU)
# when the machine is wanted as a desktop, and bring them back.
#   pause   lab pause (stops containers labelled lab.tier=heavy)
#   resume  lab resume (starts everything enabled again)
#   status  "paused" when no heavy container runs, else "running"
#   doctor  lab doctor as one JSON line: {"bad", "warn", "problems",
#           "paused", "reboot", "reboot_since", "reboot_pkgs"}; while
#           paused, the stopped heavy containers aren't counted as problems;
#           "reboot" is the OS's "reboot required" flag (set by updates)
#   screen  {"brightness": 0-100, "volume": 0-100, "muted": bool} of the
#           desktop session (null when nobody is logged in)
#   brightness <0-100>  screen brightness; 0 is the dimmest, never off
#   volume <0-100>      output volume (default sink)
set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
LOG="${XDG_STATE_HOME:-$HOME/.local/state}/lab-remote.log"
mkdir -p "$(dirname "$LOG")"

heavy() { docker ps -q --filter label=lab.tier=heavy; }

# The logged-in desktop session: its bus (brightness through COSMIC's
# settings daemon, which keeps its own slider in sync) and PipeWire.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
COSMIC=(com.system76.CosmicSettingsDaemon /com/system76/CosmicSettingsDaemon com.system76.CosmicSettingsDaemon)
bright_get() { busctl --user get-property "${COSMIC[@]}" "$1" 2>/dev/null | awk '{print $2}'; }
pct() { [[ "$1" =~ ^(100|[1-9]?[0-9])$ ]] || { echo "expected 0-100" >&2; exit 2; }; }

cmd="${SSH_ORIGINAL_COMMAND:-status}"
arg=""
[[ "$cmd" =~ ^(brightness|volume)\ ([0-9]+)$ ]] && { cmd="${BASH_REMATCH[1]}"; arg="${BASH_REMATCH[2]}"; pct "$arg"; }
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
flag = "/var/run/reboot-required"
reboot = os.path.exists(flag)
since = __import__("datetime").datetime.fromtimestamp(os.path.getmtime(flag)).astimezone().isoformat(timespec="minutes") if reboot else None
try:
    pkgs = open(flag + ".pkgs").read().split() if reboot else []
except OSError:
    pkgs = []
print(json.dumps({"bad": len(bad), "warn": len(warn), "problems": (bad + warn)[:10], "paused": bool(skip),
                  "reboot": reboot, "reboot_since": since, "reboot_pkgs": sorted(set(pkgs))[:10]}))'
    exit 0 ;;
  screen)
    b="$(bright_get DisplayBrightness)"; m="$(bright_get MaxDisplayBrightness)"
    v="$(wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null || true)"
    B="$b" M="$m" V="$v" python3 -c '
import json, os
b, m, v = os.environ["B"], os.environ["M"], os.environ["V"].split()
print(json.dumps({
    "brightness": round(100 * int(b) / int(m)) if b.isdigit() and m.isdigit() and int(m) else None,
    "volume": round(100 * float(v[1])) if len(v) > 1 else None,
    "muted": "[MUTED]" in v}))'
    exit 0 ;;
  brightness)
    m="$(bright_get MaxDisplayBrightness)"; [[ "$m" =~ ^[0-9]+$ ]] || { echo "no desktop session" >&2; exit 1; }
    raw=$(( (arg * m + 50) / 100 )); ((raw >= 1)) || raw=1
    busctl --user set-property "${COSMIC[@]}" DisplayBrightness i "$raw"
    exit 0 ;;
  volume)
    wpctl set-volume @DEFAULT_AUDIO_SINK@ "$arg%"
    if ((arg > 0)); then wpctl set-mute @DEFAULT_AUDIO_SINK@ 0; fi
    exit 0 ;;
  *) echo "usage: pause | resume | status | doctor | screen | brightness <0-100> | volume <0-100>" >&2; exit 2 ;;
esac
if [ -n "$(heavy)" ]; then echo running; else echo paused; fi
