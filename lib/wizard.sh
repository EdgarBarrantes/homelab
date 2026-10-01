# Interactive setup: writes homelab.env. Sourced after common.sh.
# Uses whiptail menus when available, plain prompts otherwise.

WIZ_TITLE="homelab setup"
if command -v whiptail >/dev/null && [[ -t 0 && -t 1 && "${HOMELAB_PLAIN:-0}" != 1 ]]; then WIZ_UI=whiptail; else WIZ_UI=plain; fi

w_input() { # <prompt> <default>
  if [[ $WIZ_UI == whiptail ]]; then
    whiptail --title "$WIZ_TITLE" --inputbox "$1" 12 74 "$2" 3>&1 1>&2 2>&3 || exit 130
  else ask "$(printf '%b' "$1")" "$2"; fi
}

w_secret() { # <prompt>
  if [[ $WIZ_UI == whiptail ]]; then
    whiptail --title "$WIZ_TITLE" --passwordbox "$1" 12 74 3>&1 1>&2 2>&3 || exit 130
  else local v; read -r -s -p "  $1: " v </dev/tty; echo >&2; printf '%s' "$v"; fi
}

w_yesno() { # <prompt> <default y|n>
  if [[ $WIZ_UI == whiptail ]]; then
    local def=(); [[ "${2:-y}" == n ]] && def=(--defaultno)
    whiptail --title "$WIZ_TITLE" "${def[@]}" --yesno "$1" 14 74
  else confirm "$(printf '%b' "$1")" "${2:-y}"; fi
}

w_menu() { # <prompt> <default> <tag> <item> [<tag> <item>...]
  local prompt="$1" def="$2"; shift 2
  if [[ $WIZ_UI == whiptail ]]; then
    whiptail --title "$WIZ_TITLE" --default-item "$def" --menu "$prompt" 18 78 $(($# / 2)) "$@" 3>&1 1>&2 2>&3 || exit 130
  else
    local i=0 tags=() reply
    say "  $prompt" >&2
    while (($#)); do tags+=("$1"); printf '    %s) %s\n' "$1" "$2" >&2; shift 2; done
    while :; do
      reply="$(ask "choose" "$def")"
      [[ " ${tags[*]} " == *" $reply "* ]] && { printf '%s' "$reply"; return; }
      say "  pick one of: ${tags[*]}" >&2
    done
  fi
}

# w_stacks <preselected list>: pick stacks, prints the chosen list.
w_stacks() {
  local pre=" $1 " s args=() on
  if [[ $WIZ_UI == whiptail ]]; then
    for s in $(all_stacks); do
      [[ $s == caddy ]] && continue
      on=OFF; [[ "$pre" == *" $s "* ]] && on=ON
      args+=("$s" "$(stack_meta "$s" DESCRIPTION)" "$on")
    done
    whiptail --title "$WIZ_TITLE" --separate-output --checklist \
      "Stacks to run (space toggles). Caddy is always on." 22 100 13 "${args[@]}" 3>&1 1>&2 2>&3 | tr '\n' ' ' || exit 130
  else
    local chosen=""
    say "  Stacks (Caddy is always on):" >&2
    for s in $(all_stacks); do
      [[ $s == caddy ]] && continue
      on=n; [[ "$pre" == *" $s "* ]] && on=y
      confirm "$(printf '%-20s %s' "$s" "$(stack_meta "$s" DESCRIPTION)")" "$on" && chosen+="$s "
    done
    printf '%s' "$chosen"
  fi
}

profile_stacks() { # <profile>
  local s out=""
  for s in $(all_stacks); do
    [[ " $(stack_meta "$s" PROFILES) " == *" $1 "* ]] && out+="$s "
  done
  printf '%s' "$out"
}

detect_tz()    { timedatectl show -p Timezone --value 2>/dev/null || echo Etc/UTC; }
detect_iface() { ip route get 1.1.1.1 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }'; }
detect_lan_ip(){ ip route get 1.1.1.1 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit } }'; }
has_gpu()      { command -v nvidia-smi >/dev/null && nvidia-smi -L >/dev/null 2>&1; }

# run_wizard [profile]: asks everything and writes homelab.env.
run_wizard() {
  local profile="${1:-standard}" v stacks name tls domain
  [[ -f "$HOMELAB_ENV" ]] || { cp "$ROOT/homelab.env.example" "$HOMELAB_ENV"; chmod 600 "$HOMELAB_ENV"; }
  load_config || true
  set_() { env_set "$HOMELAB_ENV" "$1" "$2"; }

  if [[ $WIZ_UI == whiptail ]]; then
    whiptail --title "$WIZ_TITLE" --msgbox "This sets up the homelab on $(hostname).\n\nA personal setup shared as-is: it asks a few questions, writes homelab.env (re-run with --reconfigure any time) and generates every password itself.\n\nNothing is started until the checks pass." 14 74
  else
    info "Setup for $(hostname): a few questions, then checks. Enter keeps the [default]."
  fi

  name="$(w_input "Short name for this server (dashboard title, backup tags):" "$(
    [[ "${HOMELAB_NAME:-homelab}" == homelab ]] && hostname -s || echo "$HOMELAB_NAME")")"
  set_ HOMELAB_NAME "$name"

  local pre="${STACKS:-}"
  [[ -z "$pre" || "$pre" == "caddy homepage glances" ]] && pre="$(profile_stacks "$profile")"
  stacks="caddy $(w_stacks "$pre")"
  set_ STACKS "$(echo $stacks)"
  STACKS="$(echo $stacks)"

  tls="$(w_menu "How should HTTPS work?" "${TLS_MODE:-cloudflare}" \
    cloudflare "Real certificates: a domain on Cloudflare + Tailscale (recommended)" \
    internal   "Caddy's own CA: no accounts needed (testing, or LAN only)")"
  set_ TLS_MODE "$tls"
  if [[ $tls == cloudflare ]]; then
    domain="$(w_input "Private domain. Services become <name>.<this>, e.g. photos.home.example.com.
Point *.<this> at this machine's Tailscale IP in Cloudflare DNS." "${DOMAIN:-home.example.com}")"
    set_ ACME_EMAIL "$(w_input "Email for Let's Encrypt (expiry notices):" "${ACME_EMAIL:-you@example.com}")"
    stack_env caddy
    if [[ -z "$(env_get "$STACKS_DIR/caddy/.env" CF_API_TOKEN)" ]]; then
      v="$(w_secret "Cloudflare API token (Zone > DNS > Edit for your zone). Empty = add later with: ./lab config caddy CF_API_TOKEN")"
      [[ -n "$v" ]] && env_set "$STACKS_DIR/caddy/.env" CF_API_TOKEN "$v"
    fi
  else
    domain="$(w_input "Domain for the internal certificates (not public), e.g. homelab.internal:" \
      "$([[ "${DOMAIN:-home.example.com}" == home.example.com ]] && echo "$name.internal" || echo "$DOMAIN")")"
  fi
  set_ DOMAIN "$domain"

  set_ TZ "$(w_input "Timezone:" "$( [[ "${TZ:-Etc/UTC}" == Etc/UTC ]] && detect_tz || echo "$TZ")")"
  set_ PUID "$(id -u)"; set_ PGID "$(id -g)"
  set_ NET_IFACE "$(detect_iface || echo eth0)"

  if has_gpu; then
    w_yesno "NVIDIA GPU found: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -n1).\nUse it for Immich ML and Ollama?" y && set_ GPU yes || set_ GPU no
  else set_ GPU no; fi

  if [[ " $STACKS " == *" ollama "* || " $STACKS " == *" speech "* ]]; then
    if w_yesno "Let other LAN devices (e.g. Home Assistant) use Ollama and the speech bridge?\nThey have no authentication: anything on your LAN could use them." n; then
      set_ LAN_BIND "$(w_input "This machine's LAN address:" "$(detect_lan_ip)")"
    else set_ LAN_BIND 127.0.0.1; fi
  fi

  [[ " $STACKS " == *" immich "* ]] && set_ PHOTOS_DIR "$(w_input "Photo library folder (Immich stores uploads here):" \
    "$( [[ "${PHOTOS_DIR:-}" == /home/you/* || -z "${PHOTOS_DIR:-}" ]] && echo "$HOME/Pictures/Immich" || echo "$PHOTOS_DIR")")"
  [[ " $STACKS " == *" calibre-web "* ]] && set_ BOOKS_DIR "$(w_input "Calibre library folder:" \
    "$( [[ "${BOOKS_DIR:-}" == /home/you/* || -z "${BOOKS_DIR:-}" ]] && echo "$HOME/Calibre Library" || echo "$BOOKS_DIR")")"
  [[ " $STACKS " == *" calibre-web "* ]] && set_ BOOKS_IMPORT_DIR "$(w_input "Book import folder (books copied here are added to the library, then removed):" \
    "$( [[ "${BOOKS_IMPORT_DIR:-}" == /home/you/* || -z "${BOOKS_IMPORT_DIR:-}" ]] && echo "$HOME/Books/import" || echo "$BOOKS_IMPORT_DIR")")"
  [[ " $STACKS " == *" paperless-ngx "* ]] && set_ PAPERLESS_CONSUME_DIR "$(w_input "Paperless inbox folder (files dropped here get imported):" \
    "$( [[ "${PAPERLESS_CONSUME_DIR:-}" == /home/you/* || -z "${PAPERLESS_CONSUME_DIR:-}" ]] && echo "$HOME/Documents/Paperless" || echo "$PAPERLESS_CONSUME_DIR")")"

  if [[ " $STACKS " == *" immich-public-proxy "* || " $STACKS " == *" gokapi "* ]] && [[ $tls == cloudflare ]]; then
    set_ PUBLIC_DOMAIN "$(w_input "Public links through a Cloudflare Tunnel (Immich shares at share.<this>, Gokapi downloads at send.<this>).
Your apex domain, e.g. example.com. Empty = keep everything private." "${PUBLIC_DOMAIN:-}")"
  fi

  if [[ " $STACKS " == *" paperless-ngx "* && " $STACKS " == *" ollama "* && " $STACKS " == *" actual-budget "* ]]; then
    w_yesno "Paperless AI: English summaries and titles for every document, and receipts become Actual Budget transactions (via Ollama, tuned for EUR)?" n \
      && set_ PAPERLESS_AI yes || set_ PAPERLESS_AI no
  fi

  set_ HA_URL "$(w_input "Home Assistant URL on your LAN, e.g. http://192.168.1.50:8123 (adds ha.$domain). Empty = skip." "${HA_URL:-}")"

  v="$(w_menu "Nightly backups (restic + database dumps)?" "${BACKUP_TARGET:-none}" \
    none  "No backups for now" \
    local "A disk or folder on this machine" \
    smb   "A Samba/Windows share on your network (NAS, router with a USB disk)")"
  set_ BACKUP_TARGET "$v"
  if [[ $v != none ]]; then
    set_ BACKUP_DIR "$(w_input "$([[ $v == smb ]] && echo "Where to mount the share:" || echo "Backup folder:")" "${BACKUP_DIR:-/mnt/backup}")"
    [[ $v == smb ]] && set_ BACKUP_SMB_SHARE "$(w_input "Share, e.g. //192.168.1.1/Backup (prefer the LAN address):" "${BACKUP_SMB_SHARE:-}")"
    local notify
    notify="$(w_input "URL to POST failure alerts to (e.g. a Home Assistant webhook). Empty = none." \
      "$(env_get "$ROOT/extras/backup/.env" BACKUP_NOTIFY_URL)")"
    [[ -f "$ROOT/extras/backup/.env" ]] || { cp "$ROOT/extras/backup/.env.example" "$ROOT/extras/backup/.env"; chmod 600 "$ROOT/extras/backup/.env"; }
    env_set "$ROOT/extras/backup/.env" BACKUP_NOTIFY_URL "$notify"
  fi

  load_config
  say ""; ok "saved $HOMELAB_ENV"
}
