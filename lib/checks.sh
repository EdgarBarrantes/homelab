# Preflight: is this machine ready for the selected stacks? Sourced after
# common.sh. Each check prints ok/warn/bad plus the fix. run_checks sets
# CHECK_BAD / CHECK_WARN and FIXABLE (names of fixes install.sh can apply).

CHECK_BAD=0 CHECK_WARN=0 FIXABLE=()
APT_LOG=/tmp/homelab-apt.log

# Quiet apt: output goes to $APT_LOG, shown only if it fails.
apt_install() {
  printf '    apt: %s ... ' "$*"
  if { sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive \
       apt-get install -y -qq --no-install-recommends "$@"; } >>"$APT_LOG" 2>&1; then
    echo done
  else
    echo failed; tail -n 20 "$APT_LOG"; die "apt failed (full log: $APT_LOG)"
  fi
}

_ok()   { ok "$1"; }
_warn() { warn "$1"; shift; for h in "$@"; do hint "$h"; done; CHECK_WARN=$((CHECK_WARN + 1)); }
_bad()  { bad "$1"; shift; for h in "$@"; do hint "$h"; done; CHECK_BAD=$((CHECK_BAD + 1)); }
fixable() { [[ " ${FIXABLE[*]} " == *" $1 "* ]] || FIXABLE+=("$1"); }

# Sum a numeric stack.conf field over the selected stacks.
sum_meta() {
  local s total=0
  for s in $(enabled_stacks); do
    total="$(awk -v a="$total" -v b="$(stack_meta "$s" "$1")" 'BEGIN { print a + (b ? b : 0) }')"
  done
  echo "$total"
}

version_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]; }

check_system() {
  info "System"
  local id like
  id="$(. /etc/os-release && echo "${ID:-?} ${VERSION_ID:-}")"
  like="$(. /etc/os-release && echo "${ID:-} ${ID_LIKE:-}")"
  if [[ "$like" =~ (debian|ubuntu) ]]; then _ok "OS: $id"
  else _warn "OS: $id (only tested on Debian/Ubuntu; package installs won't work)"; fi

  case "$(uname -m)" in
    x86_64) _ok "CPU: x86_64, $(nproc) cores" ;;
    aarch64) _warn "CPU: arm64 (most images support it; GPU features won't)" ;;
    *) _bad "CPU: $(uname -m) is not supported" ;;
  esac

  if [[ -d /run/systemd/system ]]; then _ok "systemd"
  else _bad "systemd not running" "Backups and the tunnel need systemd."; fi

  if [[ $EUID -eq 0 ]]; then _warn "running as root" "Run as your normal user; sudo is used only where needed."
  elif sudo -n true 2>/dev/null; then _ok "sudo available (passwordless)"
  elif id -nG | grep -qwE 'sudo|wheel|admin'; then _ok "sudo available (will ask for your password)"
  else _warn "no sudo" "Needed to install Docker, packages and systemd units."; fi

  local missing=() c
  for c in curl openssl perl awk python3; do command -v "$c" >/dev/null || missing+=("$c"); done
  if ((${#missing[@]})); then
    _bad "missing tools: ${missing[*]}" "sudo apt-get install -y ${missing[*]/python3/python3}"
    fixable packages
  else _ok "tools: curl openssl perl awk python3"; fi

  if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == yes ]]; then _ok "clock synchronised"
  else _warn "clock not NTP-synchronised" "Certificates fail on a wrong clock: sudo timedatectl set-ntp true"; fi
}

check_docker() {
  info "Docker"
  if ! command -v docker >/dev/null; then
    _bad "Docker is not installed" "The installer can install Docker Engine from Docker's apt repository."
    fixable docker; return
  fi
  if docker info --format '{{.OperatingSystem}}' 2>/dev/null | grep -q 'Docker Desktop' \
     || [[ "$(docker context show 2>/dev/null)" == desktop-linux ]]; then
    _bad "Docker Desktop context is active" "Use Docker Engine: docker context use default"
  fi
  if ! docker info >/dev/null 2>&1; then
    if id -nG | grep -qw docker || getent group docker | grep -qw "$USER"; then
      _bad "Docker daemon unreachable" "sudo systemctl enable --now docker"
    else
      _bad "$USER is not in the docker group" "sudo usermod -aG docker $USER (then log in again)"
      fixable docker-group
    fi
    return
  fi
  _ok "Docker Engine $(docker version --format '{{.Server.Version}}' 2>/dev/null)"
  local cv
  cv="$(docker compose version --short 2>/dev/null | sed 's/^v//; s/-.*//')"
  if [[ -z "$cv" ]]; then _bad "docker compose plugin missing" "sudo apt-get install -y docker-compose-plugin"; fixable docker
  elif version_ge "$cv" 2.24.4; then _ok "Docker Compose $cv"
  else _bad "Docker Compose $cv is too old (need 2.24.4+)" "sudo apt-get install -y docker-compose-plugin"; fixable docker; fi
}

check_resources() {
  info "Resources for: $(enabled_stacks | tr '\n' ' ')"
  local need_ram need_disk mem_gb free_gb
  need_ram="$(sum_meta RAM_GB)"; need_disk="$(sum_meta DISK_GB)"
  mem_gb="$(awk '/MemTotal/ { printf "%.1f", $2 / 1048576 }' /proc/meminfo)"
  free_gb="$(df -Pk "$ROOT" | awk 'NR == 2 { printf "%.0f", $4 / 1048576 }')"
  if awk -v m="$mem_gb" -v n="$need_ram" 'BEGIN { exit !(m >= n * 1.5) }'; then _ok "RAM: ${mem_gb} GB (stacks need ~${need_ram} GB)"
  elif awk -v m="$mem_gb" -v n="$need_ram" 'BEGIN { exit !(m >= n) }'; then _warn "RAM: ${mem_gb} GB is tight for ~${need_ram} GB of stacks"
  else _bad "RAM: ${mem_gb} GB, stacks need ~${need_ram} GB" "Pick fewer stacks (./install.sh --reconfigure)."; fi
  if awk -v f="$free_gb" -v n="$need_disk" 'BEGIN { exit !(f >= n + 10) }'; then _ok "Disk: ${free_gb} GB free (images need ~${need_disk} GB, plus your data)"
  else _warn "Disk: ${free_gb} GB free, images alone need ~${need_disk} GB"; fi

  if ss -Hltn 'sport = :443' 2>/dev/null | grep -q . && \
     [[ "$(docker inspect -f '{{.State.Running}}' caddy 2>/dev/null)" != true ]]; then
    _bad "port 443 is already in use" "sudo ss -ltnp 'sport = :443' shows what holds it."
  else _ok "port 443 free (or used by our Caddy)"; fi
}

check_gpu() {
  info "GPU"
  local has_nv=0
  command -v nvidia-smi >/dev/null && nvidia-smi -L >/dev/null 2>&1 && has_nv=1
  if ! is_yes "${GPU:-no}"; then
    if ((has_nv)); then _warn "NVIDIA GPU found but GPU=no" "Set GPU=yes to use it for Immich ML and Ollama."
    else _ok "GPU not used (CPU only)"; fi
    return
  fi
  if ((has_nv)); then _ok "driver: $(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader | head -n1)"
  else _bad "GPU=yes but nvidia-smi fails" "Install the NVIDIA driver first (Ubuntu: sudo ubuntu-drivers install), reboot."; return; fi
  if command -v nvidia-ctk >/dev/null; then _ok "NVIDIA Container Toolkit $(nvidia-ctk --version 2>/dev/null | head -n1 | awk '{print $NF}')"
  else _bad "NVIDIA Container Toolkit missing" "See docs/machines.md#nvidia-gpu (apt repo + nvidia-container-toolkit)."; return; fi
  if docker info 2>/dev/null | grep -q 'nvidia.com/gpu'; then _ok "CDI spec: nvidia.com/gpu=all visible to Docker"
  else _bad "Docker doesn't see a CDI GPU spec" "sudo nvidia-ctk cdi generate --output=/var/run/cdi/nvidia.yaml && sudo systemctl restart docker"; fi
}

check_network() {
  info "Network and HTTPS ($TLS_MODE)"
  if command -v tailscale >/dev/null && tailscale status >/dev/null 2>&1; then
    _ok "Tailscale up: $(tailscale ip -4 2>/dev/null | head -n1)"
  elif [[ "$TLS_MODE" == cloudflare ]]; then
    _warn "Tailscale not running" "Private hostnames are meant to resolve to this machine's Tailscale IP." \
      "curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up"
  else _ok "Tailscale not used (internal TLS mode)"; fi

  if [[ "$TLS_MODE" == cloudflare ]]; then
    if [[ -n "$(env_get "$STACKS_DIR/caddy/.env" CF_API_TOKEN)" ]]; then _ok "Cloudflare API token set"
    else _bad "CF_API_TOKEN empty in stacks/caddy/.env" "./lab config caddy CF_API_TOKEN"; fi
    local ip
    ip="$(getent ahostsv4 "dash.$DOMAIN" 2>/dev/null | awk 'NR == 1 { print $1 }')"
    if [[ -n "$ip" ]]; then _ok "dash.$DOMAIN resolves to $ip"
    else _warn "dash.$DOMAIN doesn't resolve yet" "Add a DNS record: *.$DOMAIN A <this machine's Tailscale IP> (DNS only)."; fi
  else
    _ok "internal CA: browsers need its root cert (./lab doctor prints where)"
  fi

  if [[ -n "${PUBLIC_DOMAIN:-}" ]]; then
    if command -v cloudflared >/dev/null; then _ok "cloudflared installed"
    else _warn "cloudflared not installed (needed for public links)" "See docs/public-exposure.md"; fi
  fi

  if [[ "${LAN_BIND:-127.0.0.1}" != 127.0.0.1 ]] && ! ip -4 addr | grep -q "inet ${LAN_BIND}/"; then
    _bad "LAN_BIND=$LAN_BIND is not an address of this machine" "ip -4 addr lists them; or use 127.0.0.1."
  fi
}

check_features() {
  info "Stacks and features"
  local s n bad=0
  for s in $(enabled_stacks); do
    for n in $(stack_meta "$s" NEEDS); do
      is_enabled "$n" || { _bad "$s needs the $n stack" "Add $n to STACKS."; bad=1; }
    done
  done
  if is_enabled immich-public-proxy && [[ -z "${PUBLIC_DOMAIN:-}" ]]; then
    _warn "immich-public-proxy without PUBLIC_DOMAIN does nothing useful"
  fi
  if is_yes "${PAPERLESS_AI:-no}"; then
    for n in paperless-ngx ollama actual-budget; do
      is_enabled "$n" || { _bad "PAPERLESS_AI=yes needs the $n stack"; bad=1; }
    done
  fi
  if [[ -n "${LOCAL_DIR:-}" ]]; then
    if [[ "$LOCAL_DIR" != /* ]]; then _bad "LOCAL_DIR must be an absolute path (no ~): $LOCAL_DIR"
    elif [[ -d "$LOCAL_DIR" ]]; then _ok "private overlay: $LOCAL_DIR"
    else _warn "LOCAL_DIR doesn't exist yet: $LOCAL_DIR"; fi
  fi
  if is_enabled backrest && [[ "${BACKUP_TARGET:-none}" == none ]]; then
    _warn "backrest is enabled but BACKUP_TARGET=none (nothing to browse)"
  fi
  case "${BACKUP_TARGET:-none}" in
    none) _ok "backups: off" ;;
    local|smb)
      command -v restic >/dev/null && _ok "restic $(restic version | awk '{print $2}')" \
        || { _bad "restic missing" "sudo apt-get install -y restic"; fixable packages; }
      if [[ "$BACKUP_TARGET" == smb ]]; then
        command -v mount.cifs >/dev/null && _ok "cifs-utils" \
          || { _bad "cifs-utils missing (SMB backups)" "sudo apt-get install -y cifs-utils"; fixable packages; }
      fi ;;
    *) _bad "BACKUP_TARGET must be none, local or smb" ;;
  esac
  ((bad)) || _ok "stack dependencies satisfied"
}

run_checks() {
  CHECK_BAD=0 CHECK_WARN=0 FIXABLE=()
  check_system
  check_docker
  check_resources
  check_gpu
  check_network
  check_features
  echo
  if ((CHECK_BAD)); then say "${C_RED}${CHECK_BAD} problem(s)${C_0}, ${CHECK_WARN} warning(s)."
  else say "${C_GRN}Ready.${C_0} ${CHECK_WARN} warning(s)."; fi
}

# Packages the checks may ask for.
needed_packages() {
  local p=()
  for c in curl openssl perl python3; do command -v "$c" >/dev/null || p+=("$c"); done
  command -v awk >/dev/null || p+=(gawk)
  if [[ "${BACKUP_TARGET:-none}" != none ]]; then
    command -v restic >/dev/null || p+=(restic)
    [[ "$BACKUP_TARGET" == smb ]] && ! command -v mount.cifs >/dev/null && p+=(cifs-utils)
  fi
  echo "${p[*]}"
}

fix_packages() {
  local p; p="$(needed_packages)"
  [[ -n "$p" ]] || return 0
  info "Installing packages"
  # shellcheck disable=SC2086
  apt_install $p
}

# Docker Engine from Docker's own apt repository (docs.docker.com/engine/install).
fix_docker() {
  info "Installing Docker Engine"
  local id; id="$(. /etc/os-release && echo "$ID")"
  [[ "$id" == ubuntu || "$id" == debian ]] || id="$( . /etc/os-release && [[ "${ID_LIKE:-}" == *ubuntu* ]] && echo ubuntu || echo debian)"
  local codename; codename="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"
  apt_install ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL "https://download.docker.com/linux/$id/gpg" -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$id $codename stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo systemctl enable --now docker >/dev/null 2>&1
  ok "Docker Engine installed"
  fix_docker_group
}

fix_docker_group() {
  id -nG "$USER" | grep -qw docker || sudo usermod -aG docker "$USER"
}
