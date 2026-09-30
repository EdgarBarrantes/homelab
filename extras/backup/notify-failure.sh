#!/bin/bash
# OnFailure= hook of homelab-backup.service: POSTs the tail of the log as
# JSON {"title": ..., "message": ...} to BACKUP_NOTIFY_URL from
# extras/backup/.env. A Home Assistant webhook automation works well (no HA
# token on this machine, see extras/backup/README.md); so does anything
# else that accepts a JSON POST.
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
source "$ROOT/lib/common.sh"
url="$(env_get "$ROOT/extras/backup/.env" BACKUP_NOTIFY_URL)"
[ -n "$url" ] || { echo "BACKUP_NOTIFY_URL not set, not notifying"; exit 0; }

msg=$(tail -n 5 /var/log/homelab-backup.log 2>/dev/null || echo "no log")
python3 -c 'import json, sys; print(json.dumps({"title": sys.argv[1], "message": sys.argv[2]}))' \
    "$(hostname) backup failed" "$msg" \
    | curl -fsS -m 20 --retry 5 --retry-delay 30 --retry-all-errors \
        -X POST -H 'Content-Type: application/json' --data-binary @- "$url"
