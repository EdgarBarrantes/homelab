#!/bin/bash
# Nightly backup of every enabled stack to $BACKUP_DIR (a local disk or an
# SMB share mounted by systemd). Run by homelab-backup.service as root: it
# needs /etc/homelab/restic-password (600) and docker exec into containers.
#
# Two strategies on purpose:
# - Postgres dumps and the Actual export are small and change daily: dated
#   files, pruned after BACKUP_RETAIN_DAYS.
# - Large, mostly static folders (photos, documents, books) go through
#   restic: deduplicated snapshots, 7 daily / 4 weekly / 6 monthly.
#
# It only ever writes $BACKUP_DIR/db-dumps and $BACKUP_DIR/restic-repo, and
# its only delete is the age-based prune inside db-dumps, so the target can
# safely hold other files.
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
source "$ROOT/lib/common.sh"
load_config || { echo "no homelab.env in $ROOT" >&2; exit 1; }

DB_DUMP_DIR="$BACKUP_DIR/db-dumps"
RESTIC_REPO="$BACKUP_DIR/restic-repo"
export RESTIC_PASSWORD_FILE=/etc/homelab/restic-password
# systemd doesn't set $HOME; restic needs it for its local cache.
export HOME=/root

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Network targets can blip mid-transfer; retry whole steps with backoff.
retry() {
    local attempts=3 delay=60 n=1
    until "$@"; do
        if [ "$n" -ge "$attempts" ]; then
            log "Command failed after $attempts attempts: $*"
            return 1
        fi
        log "Attempt $n failed, retrying in ${delay}s: $*"
        n=$((n + 1))
        sleep "$delay"
    done
}

running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }

# For SMB, `stat` triggers the automount; then make sure it really mounted
# instead of silently backing up into an empty local folder.
stat "$BACKUP_DIR" >/dev/null
if [ "$BACKUP_TARGET" = smb ] && ! mountpoint -q "$BACKUP_DIR"; then
    log "ERROR: $BACKUP_DIR did not mount ($BACKUP_SMB_SHARE unreachable?)"
    exit 1
fi
mkdir -p "$DB_DUMP_DIR"

# Written as .partial and renamed on success, so a dump cut off mid-transfer
# never looks like a valid backup.
dump() {  # <container> <db user> <name>
    local out="$DB_DUMP_DIR/$3-$(date +%F).sql.gz"
    docker exec "$1" pg_dumpall --clean --if-exists -U "$2" | gzip > "$out.partial"
    mv "$out.partial" "$out"
}

paths=()
for s in $(enabled_stacks); do
    container="$(stack_meta "$s" PG_CONTAINER)"
    if [ -n "$container" ]; then
        name="$(stack_meta "$s" PG_DUMP)"
        if running "$container"; then
            log "Dumping $name Postgres..."
            dump "$container" "$(stack_meta "$s" PG_USER)" "$name"
        else
            log "WARN: $container not running, skipping its dump"
        fi
    fi
    IFS='|' read -r -a stack_paths <<< "$(stack_meta "$s" BACKUP_PATHS | render_template)"
    for p in "${stack_paths[@]}"; do
        [ -n "$p" ] && [ -e "$p" ] && paths+=("$p")
    done
done

if is_enabled actual-budget && running actual_http_api; then
    sync_id="$(env_get "$STACKS_DIR/actual-budget/.env" ACTUAL_BUDGET_SYNC_ID)"
    if [ -n "$sync_id" ]; then
        log "Exporting Actual budget..."
        key="$(docker exec actual_http_api printenv API_KEY)"
        out="$DB_DUMP_DIR/actual-$(date +%F).zip"
        curl -fsSL -o "$out.partial" -H "x-api-key: $key" \
            "http://127.0.0.1:5007/v1/budgets/$sync_id/export"
        mv "$out.partial" "$out"
    else
        log "WARN: ACTUAL_BUDGET_SYNC_ID not set, skipping the Actual export"
    fi
fi

log "Pruning dumps older than $BACKUP_RETAIN_DAYS days..."
find "$DB_DUMP_DIR" -type f -mtime "+$BACKUP_RETAIN_DAYS" -delete

# Config and secrets, so a new machine comes back with the same settings
# (install.sh --from-backup). Small, and the restic repo is encrypted.
# info.txt labels each path for the restore.
META=/var/lib/homelab/backup-meta
mkdir -p "$META"
{
    printf 'root\t%s\nhost\t%s\n' "$ROOT" "$(hostname)"
    add_cfg() { [ -e "$2" ] && printf '%s\t%s\n' "$1" "$(readlink -f "$2")"; return 0; }
    add_cfg homelab_env "$ROOT/homelab.env"
    for f in "$ROOT"/stacks/*/.env; do add_cfg "stack_env:$(basename "$(dirname "$f")")" "$f"; done
    add_cfg backup_env "$ROOT/extras/backup/.env"
    [ -n "${LOCAL_DIR:-}" ] && add_cfg local_dir "$LOCAL_DIR"
    add_cfg cloudflared /etc/cloudflared
    home="$(getent passwd "$PUID" | cut -d: -f6)"
    for f in config.xml cert.pem key.pem; do add_cfg syncthing "$home/.local/state/syncthing/$f"; done
} > "$META/info.txt"
if running ollama; then
    docker exec ollama ollama list 2>/dev/null | awk 'NR > 1 { print $1 }' > "$META/ollama-models.txt" || true
fi
paths+=("$META")
while IFS=$'\t' read -r kind p; do
    case "$kind" in root|host) ;; *) paths+=("$p") ;; esac
done < "$META/info.txt"

if [ "${#paths[@]}" -gt 0 ]; then
    if [ ! -f "$RESTIC_REPO/config" ]; then
        log "Initialising restic repository..."
        restic -r "$RESTIC_REPO" init
    fi
    # A run killed mid-backup leaves a stale lock; this service never runs
    # twice at once, so clearing it is safe.
    restic -r "$RESTIC_REPO" unlock || true
    log "Running restic backup: ${paths[*]}"
    # plan:/created-by: are Backrest's tags: they file the snapshots under a
    # label-only Backrest plan instead of "__unassociated__".
    retry restic -r "$RESTIC_REPO" backup "${paths[@]}" \
        --tag "$HOMELAB_NAME-daily" \
        --tag "plan:$HOMELAB_NAME-nightly" --tag "created-by:$HOMELAB_NAME"

    log "Pruning old restic snapshots..."
    # Grouped by host and tags, not paths: a moved folder stays one series.
    retry restic -r "$RESTIC_REPO" forget --group-by host,tags \
        --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune

    # Weekly, read back 5% of the data: proves restores work, not just writes.
    if [ "$(date +%u)" = 7 ]; then
        log "Sunday: verifying 5% of repository data..."
        retry restic -r "$RESTIC_REPO" check --read-data-subset=5%
    fi

    # Backrest only re-reads a repo after its own operations. Cosmetic.
    if running backrest; then
        docker exec backrest wget -q -O /dev/null \
            --header 'Content-Type: application/json' \
            --post-data "{\"repoId\":\"${BACKREST_REPO:-main}\",\"task\":\"TASK_INDEX_SNAPSHOTS\"}" \
            http://localhost:9898/v1.Backrest/DoRepoTask \
            || log "WARN: Backrest index request failed"
    fi
fi

log "Backup complete."
