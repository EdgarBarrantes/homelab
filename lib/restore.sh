# lab restore: bring data back from the backups (restic snapshots + database
# dumps) into the stacks enabled here, e.g. on a new machine after
# ./install.sh. Sourced by lab after common.sh and render.sh; uses lab's dc.
#
# For each enabled stack, from its stack.conf:
# - BACKUP_PATHS: restored from the snapshot. The snapshot may come from
#   another machine with other paths, so each path is matched by its tail:
#   the part under stacks/ (paperless-ngx/data/media) or the folder name
#   (Immich, Calibre Library). --map OLD=NEW sets one explicitly.
# - PG_*: the fresh database folder is moved aside (never deleted), only
#   Postgres starts, the dump is loaded, and the role's password is reset to
#   the one in this machine's .env (the dump carries the old one).
# Actual's export can only be imported in its UI: it's copied out for that.

RESTIC_PW=/etc/homelab/restic-password

rs_restic() {
  sudo env RESTIC_PASSWORD_FILE="$RESTIC_PW" HOME=/root restic -r "$BACKUP_DIR/restic-repo" "$@"
}

# rs_key <path>: what identifies a path across machines.
rs_key() {
  local p="${1%/}"
  if [[ "$p" == "$STACKS_DIR/"* ]]; then echo "${p#"$STACKS_DIR/"}"; else basename "$p"; fi
}

# rs_match <new path> <snapshot paths...>: the snapshot path it came from.
rs_match() {
  local new="$1" key m o; shift
  for m in "${RS_MAP[@]}"; do
    [[ "${m#*=}" == "$new" ]] && { echo "${m%%=*}"; return; }
  done
  key="$(rs_key "$new")"
  for o in "$@"; do
    [[ "$o" == "$new" || "$o" == */"$key" ]] && { echo "$o"; return; }
  done
}

# rs_upto <YYYY-MM-DD>: from a sorted list of dated files on stdin, the
# newest dated on or before that day.
rs_upto() {
  awk -v d="$1" 'match($0, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) && substr($0, RSTART, 10) <= d { f = $0 } END { print f }'
}

# rs_wait_healthy <container>: up to ~3 minutes.
rs_wait_healthy() {
  local i st
  for i in $(seq 1 90); do
    st="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$1" 2>/dev/null || true)"
    [[ "$st" == healthy ]] && return 0
    sleep 2
  done
  return 1
}

run_restore() {
  local snap="" date="" only="" dry=0 yes=0
  RS_MAP=()
  while (($#)); do
    case "$1" in
      --snapshot) snap="$2"; shift ;;
      --date) date="$2"; shift ;;
      --only) only=" ${2//,/ } "; shift ;;
      --map) RS_MAP+=("$2"); shift ;;
      --dry-run) dry=1 ;;
      --yes|-y) yes=1 ;;
      *) die "usage: lab restore [--snapshot ID] [--date YYYY-MM-DD] [--only a,b] [--map OLD=NEW] [--dry-run] [--yes]" ;;
    esac
    shift
  done

  [[ "${BACKUP_TARGET:-none}" != none ]] || die "BACKUP_TARGET=none: point homelab.env at the backups, then ./install.sh --backup"
  sudo stat "$BACKUP_DIR" >/dev/null 2>&1 || true   # triggers an SMB automount
  sudo test -f "$BACKUP_DIR/restic-repo/config" || die "no restic repository at $BACKUP_DIR/restic-repo"
  sudo test -s "$RESTIC_PW" || die "no $RESTIC_PW: ./install.sh --backup asks for the repository's password"

  info "Reading snapshots in $BACKUP_DIR/restic-repo"
  local json; json="$(rs_restic snapshots --json)" || die "restic can't read the repository (wrong password?)"
  local line
  local pick='
import json, sys
want = sys.argv[1]
snaps = json.load(sys.stdin) or []
if want:
    snaps = [s for s in snaps if s["id"].startswith(want) or s.get("short_id") == want]
if not snaps:
    sys.exit(1)
s = max(snaps, key=lambda s: s["time"])
print("\t".join([s["short_id"], s["time"][:10], s["time"][11:16], s["hostname"]] + s["paths"]))
'
  line="$(python3 -c "$pick" "$snap" <<<"$json")" || die "no matching snapshot (list them: sudo restic -r $BACKUP_DIR/restic-repo snapshots)"
  local sid sday stime shost
  IFS=$'\t' read -r sid sday stime shost rest <<<"$line"
  local snap_paths=(); IFS=$'\t' read -r -a snap_paths <<<"$(cut -f5- <<<"$line")"
  date="${date:-$sday}"

  # Plan: (stack, kind, source, target)
  local plan=() s p o stack_paths=() f
  for s in $(enabled_stacks); do
    [[ -z "$only" || "$only" == *" $s "* ]] || continue
    IFS='|' read -r -a stack_paths <<<"$(stack_meta "$s" BACKUP_PATHS | render_template)"
    for p in "${stack_paths[@]}"; do
      [[ -n "$p" ]] || continue
      o="$(rs_match "$p" "${snap_paths[@]}")"
      if [[ -n "$o" ]]; then plan+=("$s|files|$o|$p"); else plan+=("$s|missing|$(rs_key "$p")|$p"); fi
    done
    if [[ -n "$(stack_meta "$s" PG_CONTAINER)" ]]; then
      f="$(sudo find "$BACKUP_DIR/db-dumps" -maxdepth 1 -name "$(stack_meta "$s" PG_DUMP)-*.sql.gz" 2>/dev/null \
        | sort | rs_upto "$date")"
      if [[ -z "$f" ]]; then
        f="$(sudo find "$BACKUP_DIR/db-dumps" -maxdepth 1 -name "$(stack_meta "$s" PG_DUMP)-*.sql.gz" 2>/dev/null | sort | tail -n1)"
      fi
      if [[ -n "$f" ]]; then plan+=("$s|database|$f|$(stack_meta "$s" PG_CONTAINER)"); else plan+=("$s|nodump|$(stack_meta "$s" PG_DUMP)|"); fi
    fi
  done
  if is_enabled actual-budget && [[ -z "$only" || "$only" == *" actual-budget "* ]]; then
    f="$(sudo find "$BACKUP_DIR/db-dumps" -maxdepth 1 -name 'actual-*.zip' 2>/dev/null | sort | rs_upto "$date")"
    [[ -n "$f" ]] && plan+=("actual-budget|actual|$f|$ROOT/restore")
  fi

  say ""
  say "  Snapshot ${C_B}$sid${C_0} from ${C_B}$shost${C_0}, $sday $stime. Dumps: newest on or before $date."
  say ""
  local item k src dst used=" "
  for item in "${plan[@]}"; do
    IFS='|' read -r s k src dst <<<"$item"
    case "$k" in
      files)    printf '  %-15s %s\n  %-15s   -> %s\n' "$s" "$src" "" "$dst"; used+="$src " ;;
      database) printf '  %-15s database %s\n' "$s" "$(basename "$src")" ;;
      actual)   printf '  %-15s %s -> import in Actual (steps below)\n' "$s" "$(basename "$src")" ;;
      missing)  printf '  %-15s %s(not in this snapshot: %s, skipped)%s\n' "$s" "$C_DIM" "$src" "$C_0" ;;
      nodump)   printf '  %-15s %s(no %s-*.sql.gz dump found, skipped)%s\n' "$s" "$C_DIM" "$src" "$C_0" ;;
    esac
  done
  for o in "${snap_paths[@]}"; do
    [[ "$used" == *" $o "* ]] || printf '  %-15s %s(in the snapshot, nothing here takes it: %s; use --map %s=/new/path)%s\n' "" "$C_DIM" "$o" "$o" "$C_0"
  done
  say ""
  if ((dry)); then ok "dry run: nothing changed"; return 0; fi
  warn "This replaces the current data of the stacks above with the backup."
  hint "Current database folders are kept as <folder>.pre-restore-<time>; files are overwritten in place."
  if ((yes == 0)); then confirm "Restore now?" n || { say "  cancelled"; return 0; }; fi

  local ts; ts="$(date +%Y%m%d-%H%M%S)"
  sudo systemctl stop homelab-backup.timer 2>/dev/null || true
  local stopped=" " dir svc c user pwkey pw
  for item in "${plan[@]}"; do
    IFS='|' read -r s k src dst <<<"$item"
    [[ "$k" == files || "$k" == database ]] || continue
    if [[ "$stopped" != *" $s "* ]]; then info "Stopping $s"; dc "$s" stop >/dev/null 2>&1 || true; stopped+="$s "; fi
    dir="$STACKS_DIR/$s"
    case "$k" in
      files)
        info "Restoring $src -> $dst"
        sudo mkdir -p "$dst"
        rs_restic restore "$sid:$src" --target "$dst" | tail -n 1
        # Your own folders go back to you; stack folders keep the container's owner.
        [[ "$dst" == "$STACKS_DIR/"* ]] || sudo chown -R "$PUID:$PGID" "$dst"
        ;;
      database)
        info "Restoring $s database from $(basename "$src")"
        c="$dst"; svc="$(stack_meta "$s" PG_SERVICE)"; user="$(stack_meta "$s" PG_USER)"
        pwkey="$(stack_meta "$s" PG_PASSWORD_KEY)"
        if sudo test -e "$dir/$(stack_meta "$s" PG_DATA)"; then
          sudo mv "$dir/$(stack_meta "$s" PG_DATA)" "$dir/$(stack_meta "$s" PG_DATA).pre-restore-$ts"
          ok "previous database kept: $(stack_meta "$s" PG_DATA).pre-restore-$ts"
        fi
        dc "$s" up -d "$svc" >/dev/null 2>&1
        rs_wait_healthy "$c" || die "$c did not become healthy: ./lab logs $s $svc"
        # search_path fix from Immich's restore docs; harmless for other dumps.
        sudo cat "$src" | gunzip \
          | sed "s/SELECT pg_catalog.set_config('search_path', '', false);/SELECT pg_catalog.set_config('search_path', 'public, pg_catalog', true);/g" \
          | docker exec -i "$c" psql -q -U "$user" -d postgres >/dev/null 2>"$ROOT/rendered/restore-$s.log" || true
        pw="$(env_get "$dir/.env" "$pwkey")"
        docker exec -i "$c" psql -q -U "$user" -d postgres -v ON_ERROR_STOP=1 >/dev/null <<<"ALTER ROLE \"$user\" WITH PASSWORD '$pw';" \
          || die "couldn't reset the $user password in $c"
        ok "loaded (psql notices: rendered/restore-$s.log)"
        ;;
    esac
  done
  for s in $stopped; do info "Starting $s"; dc "$s" up -d >/dev/null 2>&1; done
  if [[ "$stopped" == *" paperless-ngx "* ]]; then
    info "Rebuilding Paperless's search index (can take a while)"
    rs_wait_healthy paperless_webserver && docker exec paperless_webserver document_index reindex >/dev/null 2>&1 \
      && ok "search index rebuilt" || warn "run later: docker exec paperless_webserver document_index reindex"
  fi
  for item in "${plan[@]}"; do
    IFS='|' read -r s k src dst <<<"$item"
    [[ "$k" == actual ]] || continue
    mkdir -p "$dst"; sudo cat "$src" > "$dst/$(basename "$src")"
    info "Actual Budget"
    say "  Open https://budget.$DOMAIN > (log in / set a password) > Files > Import file >"
    say "  Actual > $dst/$(basename "$src"). Then set its Sync ID: ./lab config actual-budget ACTUAL_BUDGET_SYNC_ID"
  done
  sudo systemctl start homelab-backup.timer 2>/dev/null || true
  say ""
  ok "restore done. Check: ./lab doctor"
}
