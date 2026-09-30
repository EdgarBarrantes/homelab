# lab doctor: is everything that should be running actually healthy?
# Sourced after common.sh. Read-only; safe to run any time.

DOC_BAD=0 DOC_WARN=0
_dok()   { ok "$1"; }
_dwarn() { warn "$1"; [[ -n "${2:-}" ]] && hint "$2"; DOC_WARN=$((DOC_WARN + 1)); }
_dbad()  { bad "$1"; [[ -n "${2:-}" ]] && hint "$2"; DOC_BAD=$((DOC_BAD + 1)); }

container_state() {
  docker inspect -f '{{.State.Status}}{{if .State.Health}}/{{.State.Health.Status}}{{end}}' "$1" 2>/dev/null || echo missing
}

# Caddy's internal CA, copied out so curl (and you) can trust it.
local_ca() {
  local ca="$RENDER_DIR/caddy-local-ca.crt"
  docker exec caddy cat /data/caddy/pki/authorities/local/root.crt > "$ca" 2>/dev/null || { rm -f "$ca"; return 1; }
  echo "$ca"
}

# https_status <host>: HTTP status through our own Caddy, resolved locally so
# it works before (or without) DNS.
https_status() {
  local args=(-s -o /dev/null -m 15 -w '%{http_code}' --resolve "$1:443:127.0.0.1")
  [[ -n "${CA_FILE:-}" ]] && args+=(--cacert "$CA_FILE")
  curl "${args[@]}" "https://$1/" 2>/dev/null || true
}

run_doctor() {
  local s c st host code hosts=()
  DOC_BAD=0 DOC_WARN=0

  info "Containers"
  for s in $(enabled_stacks); do
    for c in $(stack_meta "$s" CONTAINERS); do
      st="$(container_state "$c")"
      case "$st" in
        running|running/healthy) _dok "$s: $c $st" ;;
        running/starting) _dwarn "$s: $c still starting" "First starts can take minutes (image setup, model downloads)." ;;
        missing) _dbad "$s: $c does not exist" "./lab up $s" ;;
        *) _dbad "$s: $c is $st" "./lab logs $s" ;;
      esac
    done
  done

  info "HTTPS routes (through Caddy, TLS_MODE=$TLS_MODE)"
  CA_FILE=""
  if [[ "$TLS_MODE" == internal ]]; then
    if CA_FILE="$(local_ca)"; then _dok "internal CA: $CA_FILE (import it in browsers/phones to trust these sites)"
    else _dwarn "couldn't read Caddy's internal CA yet"; fi
  fi
  for s in $(enabled_stacks); do
    host="$(stack_meta "$s" HOST)"; [[ -n "$host" ]] && hosts+=("$host")
  done
  hosts+=(map)
  [[ -n "${HA_URL:-}" ]] && hosts+=(ha)
  for host in "${hosts[@]}"; do
    code="$(https_status "$host.$DOMAIN")"
    case "$code" in
      2??|3??|401|403) _dok "https://$host.$DOMAIN -> $code" ;;
      502|503|504) _dbad "https://$host.$DOMAIN -> $code (Caddy up, app not answering)" ;;
      000|"") _dbad "https://$host.$DOMAIN -> no answer / TLS error" "./lab logs caddy" ;;
      *) _dwarn "https://$host.$DOMAIN -> $code" ;;
    esac
  done

  if is_yes "${GPU:-no}"; then
    info "GPU"
    for c in ollama immich_machine_learning glances; do
      [[ "$(container_state "$c")" == running* ]] || continue
      if docker exec "$c" nvidia-smi -L >/dev/null 2>&1; then _dok "$c sees the GPU"
      else _dbad "$c lost the GPU" "docker restart $c (see docs/troubleshooting.md)"; fi
    done
  fi

  if [[ -n "${PUBLIC_DOMAIN:-}" ]]; then
    info "Public links"
    if systemctl is-active --quiet cloudflared 2>/dev/null; then _dok "cloudflared running"
    else _dwarn "cloudflared not running" "See docs/public-exposure.md"; fi
  fi

  if [[ "${BACKUP_TARGET:-none}" != none ]]; then
    info "Backups"
    if systemctl is-active --quiet homelab-backup.timer 2>/dev/null; then
      _dok "timer active, next: $(systemctl show homelab-backup.timer -p NextElapseUSecRealtime --value 2>/dev/null)"
    else _dbad "homelab-backup.timer not active" "./install.sh --backup"; fi
    local res
    res="$(systemctl show homelab-backup.service -p Result --value 2>/dev/null)"
    [[ -z "$(systemctl show homelab-backup.service -p ExecMainStartTimestamp --value 2>/dev/null)" ]] && res=never
    case "$res" in
      never) _dok "no run yet (first one tonight, or: ./lab backup now)" ;;
      success) _dok "last run: success" ;;
      "") ;;
      *) _dbad "last run: $res" "./lab backup log" ;;
    esac
  fi

  echo
  if ((DOC_BAD)); then say "${C_RED}${DOC_BAD} problem(s)${C_0}, ${DOC_WARN} warning(s)."; return 1
  else say "${C_GRN}All good.${C_0} ${DOC_WARN} warning(s)."; fi
}
