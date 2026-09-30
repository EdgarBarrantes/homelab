#!/usr/bin/env bash
# install.sh: set up (or update) this homelab on this machine, or on another
# one over SSH. Safe to re-run: keeps homelab.env, every generated secret
# and all data.
#
#   ./install.sh                    guided setup: questions, checks, start
#   ./install.sh --check            only check this machine, change nothing
#   ./install.sh --host user@box    do all of this on another machine over SSH
#
# Options:
#   --profile minimal|standard|full   preselect stacks (default: standard)
#   --stacks a,b,c                    exactly these stacks (caddy is implied)
#   --config FILE                     use FILE as homelab.env
#   --yes                             no questions: defaults / --config values
#   --reconfigure                     ask the setup questions again
#   --dry-run                         check and generate config, start nothing
#   --no-start                        everything except starting containers
#   --backup                          only (re)install the backup timer
#   --public                          only (re)install the tunnel config
#   --uninstall                       stop containers, remove timers (keeps data)
#   --from-backup SOURCE              rebuild a machine from its backups: SOURCE
#                                     is a folder or //server/share (mounted at
#                                     --mount, default /mnt/backup); restores
#                                     config, installs, restores data
#   --snapshot ID                     with --from-backup: that snapshot
#   --force                           continue even if checks fail
#   --host USER@HOST [--dir PATH]     remote install (default dir: ~/homelab)
#   -h, --help
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
trap on_exit EXIT
source "$ROOT/lib/checks.sh"
source "$ROOT/lib/render.sh"
source "$ROOT/lib/wizard.sh"
source "$ROOT/lib/doctor.sh"
source "$ROOT/lib/restore.sh"

ORIG_ARGS=("$@")
MODE=install PROFILE="" STACK_LIST="" CONFIG="" RECONF=0 DRY=0 NOSTART=0 FORCE=0
HOST="" RDIR="homelab" FROM="" MOUNT=/mnt/backup SNAP=""
ASSUME_YES=0
while (($#)); do
  case "$1" in
    --check) MODE=check ;;
    --profile) PROFILE="$2"; shift ;;
    --stacks) STACK_LIST="${2//,/ }"; shift ;;
    --config) CONFIG="$2"; shift ;;
    --yes|-y) ASSUME_YES=1 ;;
    --reconfigure) RECONF=1 ;;
    --dry-run) DRY=1 ;;
    --no-start) NOSTART=1 ;;
    --backup) MODE=backup ;;
    --public) MODE=public ;;
    --uninstall) MODE=uninstall ;;
    --from-backup) MODE=from_backup; FROM="$2"; shift ;;
    --mount) MOUNT="$2"; shift ;;
    --snapshot) SNAP="$2"; shift ;;
    --force) FORCE=1 ;;
    --host) HOST="$2"; shift ;;
    --dir) RDIR="$2"; shift ;;
    -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
  shift
done
export ASSUME_YES

# --- remote: ship the repo over SSH and run this script there --------------
if [[ -n "$HOST" ]]; then
  source "$ROOT/lib/remote.sh"
  remote_install "$HOST" "$RDIR" "$CONFIG" "${ORIG_ARGS[@]}"
  exit $?
fi

banner() {
  say ""
  say "${C_B}homelab${C_0} ${C_DIM}· a personal self-hosting setup · $(hostname)${C_0}"
  say ""
}

# --- config ---------------------------------------------------------------
prepare_config() {
  if [[ -n "$CONFIG" && "$(readlink -f "$CONFIG")" != "$(readlink -f "$HOMELAB_ENV")" ]]; then
    [[ -f "$CONFIG" ]] || die "no such file: $CONFIG"
    cp "$CONFIG" "$HOMELAB_ENV"; chmod 600 "$HOMELAB_ENV"
    ok "using $CONFIG"
  fi
  if [[ ! -f "$HOMELAB_ENV" || $RECONF == 1 ]]; then
    if [[ $ASSUME_YES == 1 || ! -t 0 ]]; then
      [[ -f "$HOMELAB_ENV" ]] || { cp "$ROOT/homelab.env.example" "$HOMELAB_ENV"; chmod 600 "$HOMELAB_ENV"; }
      warn "no questions asked (--yes): using homelab.env as it is"
    else
      run_wizard "${PROFILE:-standard}"
    fi
  fi
  load_config
  if [[ -n "$STACK_LIST" ]]; then
    env_set "$HOMELAB_ENV" STACKS "caddy $STACK_LIST"
  elif [[ -n "$PROFILE" && $RECONF == 0 && -z "$CONFIG" ]]; then
    env_set "$HOMELAB_ENV" STACKS "$(echo caddy $(profile_stacks "$PROFILE"))"
  fi
  load_config
}

# --- checks, with fixes offered -------------------------------------------
checks_and_fixes() {
  run_checks
  if ((${#FIXABLE[@]})) && [[ $MODE != check && $DRY == 0 ]]; then
    say ""
    if confirm "Fix automatically (${FIXABLE[*]}, uses sudo)?" y; then
      for f in "${FIXABLE[@]}"; do
        case "$f" in
          packages) fix_packages ;;
          docker) fix_docker ;;
          docker-group) fix_docker_group ;;
        esac
      done
      # A fresh docker group membership isn't active in this session yet:
      # continue under `sg docker` instead of asking for a new login.
      if ! docker info >/dev/null 2>&1 && getent group docker | grep -qw "$USER" && [[ -z "${HOMELAB_SG:-}" ]]; then
        info "Continuing with the new docker group membership"
        export HOMELAB_SG=1
        exec sg docker -c "$(printf '%q ' "$0" "${ORIG_ARGS[@]}")"
      fi
      say ""; run_checks
    fi
  fi
  if ((CHECK_BAD)) && [[ $MODE != check ]]; then
    ((FORCE)) && warn "continuing despite problems (--force)" \
      || die "fix the problems above and run ./install.sh again (or --force)"
  fi
}

# --- backups: root-owned secrets + systemd units ----------------------------
install_backup() {
  [[ "${BACKUP_TARGET:-none}" != none ]] || { ok "backups: off (BACKUP_TARGET=none)"; return; }
  info "Backups -> $BACKUP_DIR ($BACKUP_TARGET)"
  render_backup
  sudo install -d -m 700 /etc/homelab
  if [[ $BACKUP_TARGET == smb ]] && ! sudo test -s /etc/homelab/smb-credentials; then
    if [[ $ASSUME_YES == 1 ]]; then
      warn "SMB credentials missing and --yes given: create /etc/homelab/smb-credentials"
      hint "(lines username=... and password=..., mode 600), then ./install.sh --backup"
      return 0
    fi
    local u p d
    u="$(ask "SMB username for $BACKUP_SMB_SHARE" "$USER")"
    read -r -s -p "  SMB password: " p </dev/tty; echo
    d="$(ask "SMB domain/workgroup (usually empty)" "")"
    printf 'username=%s\npassword=%s\n%s' "$u" "$p" "${d:+domain=$d$'\n'}" \
      | sudo tee /etc/homelab/smb-credentials >/dev/null
    sudo chmod 600 /etc/homelab/smb-credentials
  fi
  [[ $BACKUP_TARGET == local ]] && sudo mkdir -p "$BACKUP_DIR"
  sudo install -m 644 "$RENDER_DIR"/backup/* /etc/systemd/system/
  sudo systemctl daemon-reload
  if [[ $BACKUP_TARGET == smb ]]; then
    sudo systemctl enable --now "$(systemd-escape -p "$BACKUP_DIR").automount"
    sudo stat "$BACKUP_DIR" >/dev/null 2>&1 || true   # triggers the mount
    mountpoint -q "$BACKUP_DIR" && ok "mounted $BACKUP_SMB_SHARE" \
      || warn "$BACKUP_SMB_SHARE did not mount yet (sudo journalctl -u '$(systemd-escape -p "$BACKUP_DIR").mount')"
  fi
  restic_password || return 0
  # --from-backup enables the timer only after the data is back.
  [[ "${NO_TIMER:-0}" == 1 ]] && return 0
  sudo systemctl enable --now homelab-backup.timer
  ok "timer enabled ($BACKUP_SCHEDULE). Run one now: ./lab backup now"
}

# The restic password: kept if present; for an existing repository (a new
# machine pointed at old backups) ask for its password; otherwise generate.
restic_password() {
  local pw=/etc/homelab/restic-password repo="$BACKUP_DIR/restic-repo" p n
  if sudo test -s "$pw"; then return 0; fi
  if sudo test -f "$repo/config"; then
    ok "found an existing backup repository: $repo"
    if [[ $ASSUME_YES == 1 ]]; then
      warn "it needs its restic password: put it in $pw (mode 600), then ./install.sh --backup"
      return 1
    fi
    for n in 1 2 3; do
      read -r -s -p "  Its restic password (from your password manager): " p </dev/tty; echo
      printf '%s' "$p" | sudo tee "$pw" >/dev/null; sudo chmod 600 "$pw"
      if sudo env RESTIC_PASSWORD_FILE="$pw" HOME=/root restic -r "$repo" cat config >/dev/null 2>&1; then
        ok "password accepted. Restore your data with: ./lab restore"
        return 0
      fi
      bad "wrong password ($n/3)"
    done
    sudo rm -f "$pw"
    warn "backups not enabled; re-run ./install.sh --backup with the right password"
    return 1
  fi
  openssl rand -base64 36 | sudo tee "$pw" >/dev/null
  sudo chmod 600 "$pw"
  ok "restic password generated: $pw"
  warn "store a copy in your password manager (sudo cat $pw): without it the backups can't be restored"
}

# --- public links: cloudflared ---------------------------------------------
install_public() {
  [[ -n "${PUBLIC_DOMAIN:-}" ]] || return 0
  info "Public links on $PUBLIC_DOMAIN (Cloudflare Tunnel)"
  render_cloudflared
  if ! command -v cloudflared >/dev/null; then
    warn "cloudflared is not installed: follow docs/public-exposure.md, then ./install.sh --public"; return
  fi
  if [[ -z "${CLOUDFLARED_TUNNEL:-}" ]] || ! ls ~/.cloudflared/"${CLOUDFLARED_TUNNEL}".json >/dev/null 2>&1 \
     && ! sudo test -f "/etc/cloudflared/${CLOUDFLARED_TUNNEL:-x}.json"; then
    warn "no tunnel yet. Once, as yourself:"
    hint "cloudflared tunnel login"
    hint "cloudflared tunnel create $HOMELAB_NAME   # prints the tunnel id"
    hint "then set CLOUDFLARED_TUNNEL=<id> in homelab.env and run ./install.sh --public"
    return
  fi
  sudo install -d /etc/cloudflared
  [[ -f ~/.cloudflared/"$CLOUDFLARED_TUNNEL".json ]] && \
    sudo install -m 600 ~/.cloudflared/"$CLOUDFLARED_TUNNEL".json /etc/cloudflared/
  # The service only ever reads /etc/cloudflared/config.yml.
  sudo install -m 644 "$RENDER_DIR/cloudflared/config.yml" /etc/cloudflared/config.yml
  local h
  for h in $(sed -n 's/^  - hostname: //p' "$RENDER_DIR/cloudflared/config.yml"); do
    cloudflared tunnel route dns "$CLOUDFLARED_TUNNEL" "$h" 2>&1 | sed 's/^/    /' || true
  done
  if ! systemctl list-unit-files cloudflared.service >/dev/null 2>&1 || ! systemctl cat cloudflared >/dev/null 2>&1; then
    sudo cloudflared service install
  fi
  sudo systemctl restart cloudflared
  ok "cloudflared running with $(grep -c 'hostname:' "$RENDER_DIR/cloudflared/config.yml") public hostname(s)"
}

# --- final summary -----------------------------------------------------------
summary() {
  local s host f
  say ""
  info "Your services"
  for s in $(enabled_stacks); do
    host="$(stack_meta "$s" HOST)"
    [[ -n "$host" ]] && printf '  %-16s https://%s.%s\n' "$s" "$host" "$DOMAIN"
    host="$(stack_meta "$s" PUBLIC)"
    [[ -n "$host" && -n "${PUBLIC_DOMAIN:-}" ]] && printf '  %-16s https://%s.%s  %s(public)%s\n' "" "$host" "$PUBLIC_DOMAIN" "$C_YLW" "$C_0"
  done
  printf '  %-16s https://map.%s\n' "map" "$DOMAIN"
  say ""
  info "First steps"
  for s in $(enabled_stacks); do
    f="$STACKS_DIR/$s/setup.txt"
    [[ -f "$f" ]] && render_template < "$f" | sed 's/^/  /'
  done
  if [[ "$TLS_MODE" == internal ]]; then
    say "  HTTPS uses Caddy's own CA: trust $RENDER_DIR/caddy-local-ca.crt on your devices,"
    say "  and point *.$DOMAIN at this machine (DNS or /etc/hosts)."
  else
    say "  DNS: *.$DOMAIN -> this machine's Tailscale IP ($(tailscale ip -4 2>/dev/null | head -n1 || echo '?')), DNS only."
  fi
  say ""
  say "  Day to day: ./lab help · health: ./lab doctor · change setup: ./install.sh --reconfigure"
}

link_lab() {
  local bin="$HOME/.local/bin"
  [[ -e "$bin/lab" ]] && return
  if confirm "Add 'lab' to your PATH (~/.local/bin/lab)?" y; then
    mkdir -p "$bin"; ln -s "$ROOT/lab" "$bin/lab"; ok "linked $bin/lab"
  fi
}

# --- main ---------------------------------------------------------------------
banner
case "$MODE" in
  check)
    [[ -f "$HOMELAB_ENV" || -n "$CONFIG" ]] || { cp "$ROOT/homelab.env.example" "$ROOT/.check.env"; CONFIG="$ROOT/.check.env"; }
    if [[ -n "$CONFIG" && ! -f "$HOMELAB_ENV" ]]; then HOMELAB_ENV="$CONFIG"; fi
    load_config
    [[ -n "$STACK_LIST" ]] && STACKS="caddy $STACK_LIST"
    [[ -n "$PROFILE" ]] && STACKS="caddy $(profile_stacks "$PROFILE")"
    run_checks; rm -f "$ROOT/.check.env"
    ((CHECK_BAD == 0)) || { HOMELAB_DIED=1; exit 1; } ;;
  uninstall)
    load_config || die "nothing installed here (no homelab.env)"
    confirm "Stop and remove all containers and the backup timer? Data and config stay." n || exit 0
    "$ROOT/lab" down || true
    if systemctl cat homelab-backup.timer >/dev/null 2>&1; then
      sudo systemctl disable --now homelab-backup.timer "$(systemd-escape -p "$BACKUP_DIR").automount" 2>/dev/null || true
      sudo rm -f /etc/systemd/system/homelab-backup* "/etc/systemd/system/$(systemd-escape -p "$BACKUP_DIR")."{mount,automount}
      sudo systemctl daemon-reload
    fi
    ok "removed. Kept: homelab.env, stacks/*/.env, stacks/*/data, your folders, /etc/homelab, backups." ;;
  backup)
    load_config || die "run ./install.sh first"; install_backup ;;
  from_backup)
    [[ -n "$FROM" ]] || die "usage: ./install.sh --from-backup <folder or //server/share>"
    [[ ! -f "$HOMELAB_ENV" || $FORCE == 1 ]] || die "homelab.env exists: --from-backup is for a fresh machine (--force replaces it)"
    info "Rebuilding from the backups in $FROM"
    # Docker first: installing it re-runs this script under the new group,
    # which must happen before homelab.env exists.
    if ! docker info >/dev/null 2>&1; then
      command -v docker >/dev/null || { confirm "Docker Engine is needed. Install it (sudo)?" y && fix_docker; }
      fix_docker_group
      if [[ -z "${HOMELAB_SG:-}" ]]; then
        export HOMELAB_SG=1
        exec sg docker -c "$(printf '%q ' "$0" "${ORIG_ARGS[@]}")"
      fi
    fi
    cp "$ROOT/homelab.env.example" "$HOMELAB_ENV"; chmod 600 "$HOMELAB_ENV"
    if [[ "$FROM" == //* ]]; then
      env_set "$HOMELAB_ENV" BACKUP_TARGET smb
      env_set "$HOMELAB_ENV" BACKUP_SMB_SHARE "$FROM"
      env_set "$HOMELAB_ENV" BACKUP_DIR "$MOUNT"
    else
      env_set "$HOMELAB_ENV" BACKUP_TARGET local
      env_set "$HOMELAB_ENV" BACKUP_DIR "$(readlink -f "$FROM")"
    fi
    env_set "$HOMELAB_ENV" PUID "$(id -u)"; env_set "$HOMELAB_ENV" PGID "$(id -g)"
    load_config
    fix_packages
    NO_TIMER=1 install_backup
    sudo test -s /etc/homelab/restic-password || die "the backups can't be read without their restic password"
    RS_OVERWRITE_ENV=1 rs_open "$SNAP"
    RS_OVERWRITE_ENV=1 rs_restore_config || die "no config in that snapshot: install normally, then ./lab restore"
    SID="$RS_SID"
    load_config
    ok "settings restored: $(echo $STACKS | wc -w) stacks, $DOMAIN (review homelab.env; --reconfigure to change)"
    checks_and_fixes
    info "Generating config"; render_all
    info "Starting stacks (first run pulls images: this can take a while)"
    "$ROOT/lab" up
    info "Restoring data from snapshot $SID"
    "$ROOT/lab" restore --yes --snapshot "$SID"
    if is_enabled ollama && [[ -s "$RENDER_DIR/ollama-models.txt" ]]; then
      info "Pulling Ollama models again"
      while read -r m; do [[ -n "$m" ]] && docker exec ollama ollama pull "$m" >/dev/null && ok "$m"; done < "$RENDER_DIR/ollama-models.txt"
    fi
    install_backup
    install_public
    link_lab
    run_doctor || warn "some checks failed: ./lab doctor again in a few minutes"
    summary ;;
  public)
    load_config || die "run ./install.sh first"; install_public ;;
  install)
    prepare_config
    checks_and_fixes
    info "Generating config"
    render_all
    ok "rendered: Caddy routes, dashboard, secrets in stacks/*/.env (mode 600)"
    if ((DRY)); then
      ok "dry run: nothing started. Look at rendered/ and stacks/*/.env, then run without --dry-run."
      exit 0
    fi
    if ((NOSTART == 0)); then
      info "Starting stacks (first run pulls images: this can take a while)"
      "$ROOT/lab" up
    fi
    install_backup
    install_public
    link_lab
    if ((NOSTART == 0)); then
      info "Waiting for containers to become healthy"
      for _ in $(seq 1 30); do
        docker ps --format '{{.Status}}' | grep -q 'health: starting' || break
        sleep 10
      done
      run_doctor || warn "some checks failed: ./lab doctor again in a few minutes (first starts are slow)"
    fi
    summary ;;
esac
