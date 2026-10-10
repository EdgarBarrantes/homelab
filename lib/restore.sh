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
#
# --from offsite reads the off-site copy (BACKUP_OFFSITE, e.g. Google Drive
# through rclone) instead of $BACKUP_DIR: same snapshots, and the database
# dumps come out of the snapshot (they are backed up with it), so only the
# dates still in the snapshots can be picked. Stacks are restored in
# parallel or one after another, like `lab up` (--parallel / --serial,
# LAB_UP_MODE).

RESTIC_PW=/etc/homelab/restic-password
RS_FROM=primary

rs_repo() { if [[ "$RS_FROM" == offsite ]]; then echo "$BACKUP_OFFSITE"; else echo "$BACKUP_DIR/restic-repo"; fi; }
rs_restic() {
  sudo env RESTIC_PASSWORD_FILE="$RESTIC_PW" HOME=/root RCLONE_CONFIG=/etc/homelab/rclone.conf \
    restic -r "$(rs_repo)" "$@"
}

# rs_dumps <name> <ext>: the dumps <name>-<date><ext>, oldest first: files in
# $BACKUP_DIR/db-dumps, or (off-site) paths inside the snapshot RS_SID.
rs_dumps() {
  if [[ "$RS_FROM" == offsite ]]; then
    local d; for d in "${RS_PATHS[@]}"; do [[ "$d" == */db-dumps ]] && break; d=""; done
    [[ -n "$d" ]] || return 0
    rs_restic ls "$RS_SID" "$d" 2>/dev/null | grep -E "/$1-[^/]*${2//./\\.}\$" | sort || true
  else
    sudo find "$BACKUP_DIR/db-dumps" -maxdepth 1 -name "$1-*$2" 2>/dev/null | sort
  fi
}
# rs_cat <dump>: its content, from wherever rs_dumps found it.
rs_cat() { if [[ "$RS_FROM" == offsite ]]; then rs_restic dump "$RS_SID" "$1"; else sudo cat "$1"; fi; }

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

RS_META=/var/lib/homelab/backup-meta

# rs_open [snapshot]: check the repository, pick the snapshot (newest, or
# the given id) and read its config manifest. Sets RS_SID RS_DAY RS_TIME
# RS_HOST RS_PATHS[] RS_INFO RS_CFG_PATHS[].
rs_open() {
  sudo test -s "$RESTIC_PW" || die "no $RESTIC_PW: ./install.sh --backup asks for the repository's password"
  if [[ "$RS_FROM" == offsite ]]; then
    [[ -n "${BACKUP_OFFSITE:-}" ]] || die "BACKUP_OFFSITE is empty: no off-site copy configured"
    rs_restic cat config >/dev/null 2>&1 || die "can't open the off-site repository $BACKUP_OFFSITE (rclone config in /etc/homelab/rclone.conf?)"
  else
    [[ "${BACKUP_TARGET:-none}" != none ]] || die "BACKUP_TARGET=none: point homelab.env at the backups, then ./install.sh --backup"
    sudo stat "$BACKUP_DIR" >/dev/null 2>&1 || true   # triggers an SMB automount
    sudo test -f "$BACKUP_DIR/restic-repo/config" || die "no restic repository at $BACKUP_DIR/restic-repo"
  fi
  info "Reading snapshots in $(rs_repo)"
  local json line pick
  json="$(rs_restic snapshots --json)" || die "restic can't read the repository (wrong password?)"
  pick='
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
  line="$(python3 -c "$pick" "${1:-}" <<<"$json")" || die "no matching snapshot (list them: sudo restic -r $(rs_repo) snapshots)"
  IFS=$'\t' read -r RS_SID RS_DAY RS_TIME RS_HOST _ <<<"$line"
  RS_PATHS=(); IFS=$'\t' read -r -a RS_PATHS <<<"$(cut -f5- <<<"$line")"
  RS_INFO="$(rs_restic dump "$RS_SID" "$RS_META/info.txt" 2>/dev/null || true)"
  RS_CFG_PATHS=()
  local kind p
  while IFS=$'\t' read -r kind p; do
    [[ -n "$kind" && "$kind" != root && "$kind" != host ]] && RS_CFG_PATHS+=("$p")
  done <<<"$RS_INFO"
  return 0
}

# The backup may come from another user's home (/home/old/...): move the
# folder settings to this user's home and make this user the owner.
rs_rehome_path() {
  local p="$1"
  if [[ "$p" =~ ^/home/[^/]+ && "${BASH_REMATCH[0]}" != "$HOME" ]]; then p="$HOME${p#"${BASH_REMATCH[0]}"}"; fi
  printf '%s' "$p"
}
rs_rehome_env() {
  local k v n
  env_set "$HOMELAB_ENV" PUID "$(id -u)"
  env_set "$HOMELAB_ENV" PGID "$(id -g)"
  for k in PHOTOS_DIR BOOKS_DIR BOOKS_IMPORT_DIR PAPERLESS_CONSUME_DIR LOCAL_DIR; do
    v="$(env_get "$HOMELAB_ENV" "$k")"; [[ -n "$v" ]] || continue
    n="$(rs_rehome_path "$v")"
    [[ "$n" == "$v" ]] || { env_set "$HOMELAB_ENV" "$k" "$n"; warn "$k: $v -> $n (this machine's home)"; }
  done
  return 0
}

# rs_restore_config: put back the config the snapshot's manifest lists
# (homelab.env, each stack's .env, extras/backup/.env, the private overlay,
# /etc/cloudflared, Syncthing's identity), skipping anything that already
# exists here, except homelab.env when RS_OVERWRITE_ENV=1. Saves the Ollama
# model list to rendered/ollama-models.txt.
rs_restore_config() {
  [[ -n "$RS_INFO" ]] || { warn "snapshot $RS_SID has no config manifest (made by an older backup.sh)"; return 1; }
  info "Restoring config from snapshot $RS_SID ($RS_HOST, $RS_DAY)"
  local kind p dst s owner
  while IFS=$'\t' read -r kind p; do
    case "$kind" in
      root|host|"") continue ;;
      homelab_env) dst="$HOMELAB_ENV" ;;
      stack_env:*) s="${kind#stack_env:}"; [[ -d "$STACKS_DIR/$s" ]] || continue; dst="$STACKS_DIR/$s/.env" ;;
      backup_env) dst="$ROOT/extras/backup/.env" ;;
      local_dir) dst="${LOCAL_DIR:-$(rs_rehome_path "$p")}" ;;
      syncthing) dst="$(rs_rehome_path "$p")" ;;
      cloudflared) dst="$p" ;;
      *) continue ;;
    esac
    if [[ -e "$dst" && ! ( "$kind" == homelab_env && "${RS_OVERWRITE_ENV:-0}" == 1 ) ]]; then
      hint "kept existing $dst"; continue
    fi
    owner="$(id -u):$(id -g)"
    [[ "$kind" == cloudflared ]] && owner="0:0"
    if [[ "$kind" == local_dir || "$kind" == cloudflared ]]; then
      sudo mkdir -p "$dst"
      rs_restic restore "$RS_SID:$p" --target "$dst" >/dev/null
      sudo chown -R "$owner" "$dst"
    else
      sudo mkdir -p "$(dirname "$dst")"
      rs_restic dump "$RS_SID" "$p" | sudo tee "$dst" >/dev/null
      sudo chown "$owner" "$dst"; sudo chmod 600 "$dst"
    fi
    ok "$kind -> $dst"
    if [[ "$kind" == homelab_env ]]; then
      [[ "${RS_OVERWRITE_ENV:-0}" == 1 ]] && rs_rehome_env
      load_config
    fi
  done <<<"$RS_INFO"
  mkdir -p "$RENDER_DIR"
  rs_restic dump "$RS_SID" "$RS_META/ollama-models.txt" 2>/dev/null > "$RENDER_DIR/ollama-models.txt" || rm -f "$RENDER_DIR/ollama-models.txt"
  return 0
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
  local snap="" date="" only="" dry=0 yes=0 cfg_only=0
  RS_MAP=()
  while (($#)); do
    case "$1" in
      --snapshot) snap="$2"; shift ;;
      --date) date="$2"; shift ;;
      --only) only=" ${2//,/ } "; shift ;;
      --map) RS_MAP+=("$2"); shift ;;
      --dry-run) dry=1 ;;
      --yes|-y) yes=1 ;;
      --config) cfg_only=1 ;;
      --from) [[ "$2" == primary || "$2" == offsite ]] || die "--from primary|offsite"; RS_FROM="$2"; shift ;;
      --parallel) UP_MODE_FLAG=parallel ;;
      --serial) UP_MODE_FLAG=serial ;;
      *) die "usage: lab restore [--from primary|offsite] [--snapshot ID] [--date YYYY-MM-DD] [--only a,b] [--map OLD=NEW] [--config] [--dry-run] [--yes] [--parallel|--serial]" ;;
    esac
    shift
  done

  rs_open "$snap"
  local sid="$RS_SID" sday="$RS_DAY" stime="$RS_TIME" shost="$RS_HOST"
  local snap_paths=("${RS_PATHS[@]}")
  if ((cfg_only)); then rs_restore_config; return; fi
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
      f="$(rs_dumps "$(stack_meta "$s" PG_DUMP)" .sql.gz | rs_upto "$date")"
      [[ -n "$f" ]] || f="$(rs_dumps "$(stack_meta "$s" PG_DUMP)" .sql.gz | tail -n1)"
      if [[ -n "$f" ]]; then plan+=("$s|database|$f|$(stack_meta "$s" PG_CONTAINER)"); else plan+=("$s|nodump|$(stack_meta "$s" PG_DUMP)|"); fi
    fi
  done
  if is_enabled actual-budget && [[ -z "$only" || "$only" == *" actual-budget "* ]]; then
    f="$(rs_dumps actual .zip | rs_upto "$date")"
    [[ -n "$f" ]] && plan+=("actual-budget|actual|$f|$ROOT/restore")
  fi

  say ""
  say "  From ${C_B}$(rs_repo)${C_0}: snapshot ${C_B}$sid${C_0} from ${C_B}$shost${C_0}, $sday $stime. Dumps: newest on or before $date."
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
    [[ " ${RS_CFG_PATHS[*]} " == *" $o "* || "$o" == "$RS_META" ]] && continue
    [[ "$used" == *" $o "* ]] || printf '  %-15s %s(in the snapshot, nothing here takes it: %s; use --map %s=/new/path)%s\n' "" "$C_DIM" "$o" "$o" "$C_0"
  done
  say ""
  if ((dry)); then ok "dry run: nothing changed"; return 0; fi
  warn "This replaces the current data of the stacks above with the backup."
  hint "Current database folders are kept as <folder>.pre-restore-<time>; files are overwritten in place."
  if ((yes == 0)); then confirm "Restore now?" n || { say "  cancelled"; return 0; }; fi

  RS_TS="$(date +%Y%m%d-%H%M%S)" RS_PLAN=("${plan[@]}")
  sudo systemctl stop homelab-backup.timer 2>/dev/null || true
  local stopped=" " list=()
  for item in "${plan[@]}"; do
    IFS='|' read -r s k src dst <<<"$item"
    [[ "$k" == files || "$k" == database ]] || continue
    [[ "$stopped" == *" $s "* ]] || { stopped+="$s "; list+=("$s"); }
  done
  local rc=0
  if [[ "$(up_mode "${#list[@]}")" == parallel ]]; then
    # Background jobs can't answer a sudo prompt: ask now, keep it fresh.
    # (sudo -n true first: -v asks for a password whenever any sudo rule
    # for this user wants one, even with NOPASSWD elsewhere.)
    sudo -n true 2>/dev/null || sudo -v
    ( while sleep 50; do sudo -n true 2>/dev/null || exit 0; done ) & local keep=$!
    run_jobs rs_restore_stack "$RENDER_DIR/restore-logs" "${list[@]}" || rc=$?
    kill "$keep" 2>/dev/null || true
  else
    for s in "${list[@]}"; do rs_restore_stack "$s" || rc=$?; done
  fi
  if [[ "$stopped" == *" paperless-ngx "* ]]; then
    info "Rebuilding Paperless's search index (can take a while)"
    rs_wait_healthy paperless_webserver && docker exec paperless_webserver document_index reindex >/dev/null 2>&1 \
      && ok "search index rebuilt" || warn "run later: docker exec paperless_webserver document_index reindex"
  fi
  for item in "${plan[@]}"; do
    IFS='|' read -r s k src dst <<<"$item"
    [[ "$k" == actual ]] || continue
    mkdir -p "$dst"; rs_cat "$src" > "$dst/$(basename "$src")"
    info "Actual Budget"
    say "  Open https://budget.$DOMAIN > (log in / set a password) > Files > Import file >"
    say "  Actual > $dst/$(basename "$src"). Then set its Sync ID: ./lab config actual-budget ACTUAL_BUDGET_SYNC_ID"
  done
  sudo systemctl start homelab-backup.timer 2>/dev/null || true
  say ""
  ((rc == 0)) || die "some stacks were not restored (see above)"
  ok "restore done. Check: ./lab doctor"
}

# rs_restore_stack <stack>: stop it, restore its RS_PLAN items (files, its
# database), start it again. One job of a parallel restore.
rs_restore_stack() {
  local s="$1" item k src dst dir svc c user pwkey pw x
  dir="$STACKS_DIR/$s"
  info "Stopping $s"; dc "$s" stop >/dev/null 2>&1 || true
  for item in "${RS_PLAN[@]}"; do
    IFS='|' read -r x k src dst <<<"$item"
    [[ "$x" == "$s" ]] || continue
    case "$k" in
      files)
        info "Restoring $src -> $dst"
        sudo mkdir -p "$dst"
        rs_restic restore "$RS_SID:$src" --target "$dst" | tail -n 1
        # Your own folders go back to you; stack folders keep the container's owner.
        [[ "$dst" == "$STACKS_DIR/"* ]] || sudo chown -R "$PUID:$PGID" "$dst"
        ;;
      database)
        info "Restoring $s database from $(basename "$src")"
        c="$dst"; svc="$(stack_meta "$s" PG_SERVICE)"; user="$(stack_meta "$s" PG_USER)"
        pwkey="$(stack_meta "$s" PG_PASSWORD_KEY)"
        if sudo test -e "$dir/$(stack_meta "$s" PG_DATA)"; then
          sudo mv "$dir/$(stack_meta "$s" PG_DATA)" "$dir/$(stack_meta "$s" PG_DATA).pre-restore-$RS_TS"
          ok "previous database kept: $(stack_meta "$s" PG_DATA).pre-restore-$RS_TS"
        fi
        dc "$s" up -d "$svc" >/dev/null 2>&1
        rs_wait_healthy "$c" || die "$c did not become healthy: ./lab logs $s $svc"
        # search_path fix from Immich's restore docs; harmless for other dumps.
        rs_cat "$src" | gunzip \
          | sed "s/SELECT pg_catalog.set_config('search_path', '', false);/SELECT pg_catalog.set_config('search_path', 'public, pg_catalog', true);/g" \
          | docker exec -i "$c" psql -q -U "$user" -d postgres >/dev/null 2>"$RENDER_DIR/restore-$s.log" || true
        pw="$(env_get "$dir/.env" "$pwkey")"
        docker exec -i "$c" psql -q -U "$user" -d postgres -v ON_ERROR_STOP=1 >/dev/null <<<"ALTER ROLE \"$user\" WITH PASSWORD '$pw';" \
          || die "couldn't reset the $user password in $c"
        ok "loaded (psql notices: rendered/restore-$s.log)"
        ;;
    esac
  done
  info "Starting $s"; dc "$s" up -d >/dev/null 2>&1
}

# lab backup drill [--from primary|offsite|both] [--files N]: prove the
# backups restore, without touching anything live. For each repository:
# the newest snapshot; N sample files (default 5) restored to a scratch
# folder and compared with the live ones (only files unchanged since the
# snapshot); each stack's newest dump loaded into a throwaway Postgres (the
# stack's own image, no network) and its databases and table counts
# compared with the live ones. Prints what it read and how fast.
run_drill() {
  local from=both nfiles=5 r rc=0 sum=()
  while (($#)); do
    case "$1" in
      --from) from="$2"; shift ;;
      --files) nfiles="$2"; shift ;;
      *) die "usage: lab backup drill [--from primary|offsite|both] [--files N]" ;;
    esac
    shift
  done
  case "$from" in
    both) set -- primary; [[ -n "${BACKUP_OFFSITE:-}" ]] && set -- primary offsite ;;
    primary|offsite) set -- "$from" ;;
    *) die "--from primary|offsite|both" ;;
  esac
  for r in "$@"; do
    RS_FROM="$r"
    drill_one "$nfiles" || rc=1
    sum+=("$DRILL_LINE")
  done
  say ""; info "Drill summary"; printf '  %s\n' "${sum[@]}"
  ((rc == 0)) || die "the drill found problems (see above)"
  ok "backups restore"
}

drill_one() {
  local nfiles="$1" t0=$SECONDS bytes=0 fok=0 ftot=0 dok=0 dtot=0 bad=0
  local scratch s p o f live size mtime sid_epoch img c user dbs db n_live n_rest
  DRILL_LINE="$RS_FROM: not reached"
  rs_open "" || return 1
  info "Drill on $(rs_repo): snapshot $RS_SID ($RS_HOST, $RS_DAY $RS_TIME)"
  sid_epoch="$(date -d "$RS_DAY $RS_TIME" +%s)"
  scratch="$(mktemp -d /var/tmp/homelab-drill.XXXXXX)"; chmod 700 "$scratch"
  # 1. Files: candidates from every stack's backup paths, unchanged since
  # the snapshot (same size, older mtime), a random few.
  local cands=() stack_paths=()
  for s in $(enabled_stacks); do
    IFS='|' read -r -a stack_paths <<<"$(stack_meta "$s" BACKUP_PATHS | render_template)"
    for p in "${stack_paths[@]}"; do
      [[ -n "$p" ]] || continue
      o="$(rs_match "$p" "${RS_PATHS[@]}")"; [[ -n "$o" ]] || continue
      while IFS=$'\t' read -r f size; do
        live="$p${f#"$o"}"
        sudo test -f "$live" || continue
        [[ "$(sudo stat -c %s "$live")" == "$size" ]] || continue
        (( $(sudo stat -c %Y "$live") < sid_epoch )) || continue
        cands+=("$f"$'\t'"$live"$'\t'"$size")
      done < <(rs_restic ls --json "$RS_SID" "$o" --recursive 2>/dev/null | python3 -c '
import json, random, sys
rows = []
for line in sys.stdin:
    try: n = json.loads(line)
    except ValueError: continue
    if n.get("type") == "file" and 0 < n.get("size", 0) <= 50_000_000:
        rows.append((n["path"], n["size"]))
random.shuffle(rows)
for p, s in rows[:40]: print(f"{p}\t{s}")')
    done
  done
  local pick; mapfile -t pick < <(printf '%s\n' "${cands[@]}" | shuf -n "$nfiles" 2>/dev/null || true)
  for f in "${pick[@]}"; do
    [[ -n "$f" ]] || continue
    IFS=$'\t' read -r o live size <<<"$f"
    ftot=$((ftot + 1))
    if rs_restic dump "$RS_SID" "$o" | sudo tee "$scratch/f" >/dev/null \
       && [[ "$(sudo sha256sum "$scratch/f" | cut -c1-64)" == "$(sudo sha256sum "$live" | cut -c1-64)" ]]; then
      fok=$((fok + 1)); bytes=$((bytes + size)); ok "file matches: $live"
    else bad "file differs or can't be read: $live"; bad=1; fi
  done
  ((ftot > 0)) || warn "no unchanged files to compare (all changed since the snapshot?)"
  # 2. Databases: newest dump of each stack, into a throwaway Postgres.
  for s in $(enabled_stacks); do
    c="$(stack_meta "$s" PG_CONTAINER)"; [[ -n "$c" ]] || continue
    f="$(rs_dumps "$(stack_meta "$s" PG_DUMP)" .sql.gz | tail -n1)"
    dtot=$((dtot + 1))
    [[ -n "$f" ]] || { bad "$s: no dump in $(rs_repo)"; bad=1; continue; }
    img="$(docker inspect -f '{{.Config.Image}}' "$c" 2>/dev/null)" || { warn "$s: $c not running, skipped"; dtot=$((dtot - 1)); continue; }
    user="$(stack_meta "$s" PG_USER)"
    docker rm -f "drill-$s" >/dev/null 2>&1 || true
    docker run -d --rm --name "drill-$s" --network none -e POSTGRES_USER="$user" -e POSTGRES_PASSWORD=drill "$img" >/dev/null
    for _ in $(seq 1 60); do docker exec "drill-$s" pg_isready -h 127.0.0.1 -U "$user" >/dev/null 2>&1 && break; sleep 2; done
    size="$(rs_cat "$f" | sudo tee "$scratch/$s.sql.gz" | wc -c)"
    bytes=$((bytes + size))
    sudo cat "$scratch/$s.sql.gz" | gunzip \
      | sed "s/SELECT pg_catalog.set_config('search_path', '', false);/SELECT pg_catalog.set_config('search_path', 'public, pg_catalog', true);/g" \
      | docker exec -i "drill-$s" psql -q -U "$user" -d postgres >/dev/null 2>"$scratch/$s.log" || true
    dbs="$(docker exec "$c" psql -At -U "$user" -d postgres -c "select datname from pg_database where not datistemplate and datname <> 'postgres'" 2>/dev/null)"
    local same=1 report=""
    for db in $dbs; do
      n_live="$(docker exec "$c" psql -At -U "$user" -d "$db" -c "select count(*) from information_schema.tables where table_schema not in ('pg_catalog','information_schema')" 2>/dev/null || echo x)"
      n_rest="$(docker exec "drill-$s" psql -At -U "$user" -d "$db" -c "select count(*) from information_schema.tables where table_schema not in ('pg_catalog','information_schema')" 2>/dev/null || echo missing)"
      report+=" $db $n_rest/$n_live"
      [[ "$n_rest" == "$n_live" && "$n_live" != 0 ]] || same=0
    done
    docker rm -f "drill-$s" >/dev/null 2>&1 || true
    if ((same)) && [[ -n "$dbs" ]]; then dok=$((dok + 1)); ok "$s: $(basename "$f") loads; tables (restored/live):$report"
    else bad "$s: $(basename "$f") differs:$report (psql log: $scratch/$s.log)"; bad=1; fi
  done
  local secs=$((SECONDS - t0)); ((secs > 0)) || secs=1
  DRILL_LINE="$(printf '%-8s snapshot %s (%s %s)  files %d/%d  databases %d/%d  read %s MB in %ss (%s MB/s)' \
    "$RS_FROM" "$RS_SID" "$RS_DAY" "$RS_TIME" "$fok" "$ftot" "$dok" "$dtot" \
    $((bytes / 1048576)) "$secs" "$(awk -v b="$bytes" -v s="$secs" 'BEGIN { printf "%.1f", b / 1048576 / s }')")"
  ((bad)) || sudo rm -rf "$scratch"
  return "$bad"
}
