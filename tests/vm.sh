#!/usr/bin/env bash
# Test the installer end to end in a throwaway Ubuntu 24.04 VM (Incus).
# Nothing touches the host except the VM itself. No Cloudflare, no
# Tailscale: TLS_MODE=internal (Caddy's own CA), config in tests/vm.env.
#
#   tests/vm.sh up        create the VM (4 CPU, 12 GiB, 40 GiB disk)
#   tests/vm.sh install   ./install.sh --host ubuntu@<vm> --config tests/vm.env --yes
#   tests/vm.sh verify    lab doctor + HTTPS from the host + a backup run
#   tests/vm.sh rerun     install again (must be idempotent)
#   tests/vm.sh restore   back up, wipe to a "new machine", lab restore, check
#   tests/vm.sh rebuild   wipe everything but the backups, install.sh --from-backup
#   tests/vm.sh ssh       shell in the VM
#   tests/vm.sh down      delete the VM
#   tests/vm.sh all       up, install, verify, rerun, verify, restore, rebuild
#
# Scoped runs, for a change to one or a few stacks (fresh VM, install,
# verify; the rerun, restore and rebuild drills belong to the full suite):
#   tests/vm.sh changed [base]   test what changed since base (origin/master):
#                                full suite, only some stacks, or nothing
#   tests/vm.sh stacks "a b"     only these stacks (plus what they need)
#   tests/vm.sh scope [base]     just print what `changed` would test
# Scope rules are in tests/scope.sh; per-stack checks in tests/stacks/<s>.sh.
#
# Needs: incus (user in incus-admin), KVM. VM name: $VM (default homelab-test).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
VM="${VM:-homelab-test}"
STATE="$HERE/.vm"
KEY="$STATE/id_ed25519"
export HOMELAB_SSH_OPTS="-i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=10"

log() { printf '\n\e[1;34m[vm]\e[0m %s\n' "$*"; }

# The VM's own address: once Docker runs inside, incus also lists docker0
# and br-* bridge addresses, so skip those.
vm_ip() {
  incus list "$VM" -c 4 -f csv | tr -d '"' | grep -v -E '\((docker|br-|veth)' \
    | awk '{ print $1 }' | grep -E '^[0-9.]+$' | head -n1
}

ssh_vm() { # shellcheck disable=SC2086
  ssh $HOMELAB_SSH_OPTS "ubuntu@$(vm_ip)" "$@"
}

up() {
  mkdir -p "$STATE"
  [[ -f "$KEY" ]] || ssh-keygen -q -t ed25519 -N '' -C homelab-vm-test -f "$KEY"
  if incus info "$VM" >/dev/null 2>&1; then log "$VM already exists"; else
    log "creating $VM"
    local try
    # The client sometimes hangs talking to the image server (the daemon
    # never sees an operation): give up after 5 minutes and try once more.
    for try in 1 2; do
      timeout 300 incus launch images:ubuntu/24.04/cloud "$VM" --vm \
        -c limits.cpu=4 -c limits.memory=12GiB -d root,size=40GiB \
        -c cloud-init.user-data="#cloud-config
users:
  - name: ubuntu
    shell: /bin/bash
    groups: [sudo]
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys: [\"$(cat "$KEY.pub")\"]
packages: [openssh-server]
" && break
      ((try == 1)) || { echo "incus launch failed twice"; exit 1; }
      log "incus launch stuck or failed; retrying"
      incus delete -f "$VM" >/dev/null 2>&1 || true
    done
  fi
  log "waiting for SSH"
  for _ in $(seq 1 90); do
    ip="$(vm_ip || true)"
    if [[ -n "$ip" ]] && ssh_vm true 2>/dev/null; then break; fi
    sleep 5
  done
  ssh_vm 'cloud-init status --wait >/dev/null; echo "ready: $(hostname) $(. /etc/os-release; echo $PRETTY_NAME)"'
  ssh_vm 'curl -fsS -o /dev/null -m 10 https://download.docker.com && echo "internet: ok"' \
    || { echo "VM has no internet access (see tests/README.md)"; exit 1; }
}

install() {
  log "installing via ./install.sh --host"
  local ip; ip="$(vm_ip)"; [[ -n "$ip" ]] || { echo "no VM address"; exit 1; }
  # The private overlay fixture lives outside the repo, like a real one.
  tar -C "$HERE/fixtures/overlay" -cf - . | ssh_vm 'mkdir -p ~/overlay && tar -xf - -C ~/overlay'
  # The test config only on the first install: later tests change it on
  # purpose (restore-test moves the photos), and a rerun must keep that.
  # TEST_STACKS (scoped runs) replaces the stack list in the test config.
  local env="$HERE/vm.env"
  if [[ -n "${TEST_STACKS:-}" ]]; then
    mkdir -p "$STATE"; env="$STATE/vm.env"
    sed "s|^STACKS=.*|STACKS=\"$TEST_STACKS\"|" "$HERE/vm.env" > "$env"
  fi
  local cfg=(--config "$env")
  ssh_vm 'test -f homelab/homelab.env' && cfg=()
  timeout --foreground 45m "$ROOT/install.sh" --host "ubuntu@$ip" "${cfg[@]}" --yes
}

verify() {
  local ip; ip="$(vm_ip)"
  log "lab doctor in the VM"
  ssh_vm 'cd homelab && ./lab doctor'
  log "HTTPS from the host through the VM's Caddy (internal CA)"
  ssh_vm 'cat homelab/rendered/caddy-local-ca.crt' > "$STATE/ca.crt"
  # Hostnames of the installed stacks, plus the map and the overlay's route.
  local stacks s h code fails=0 hosts="map hello"
  # lab keys: every key documented, and no value ever printed.
  if ssh_vm 'cd homelab && out="$(./lab keys)" && ! grep -q undocumented <<<"$out" || exit 1
      for f in stacks/*/.env extras/backup/.env; do [[ -f "$f" ]] || continue
        while IFS== read -r k v; do v="${v#[\"'\'']}"; v="${v%[\"'\'']}"
          ((${#v} < 8)) || ! grep -qF -- "$v" <<<"$out" || { echo "value of $k printed"; exit 1; }
        done < <(grep "^[A-Za-z_]" "$f")
      done'; then echo "  lab keys (all documented, no values): ok"
  else echo "  lab keys: FAIL"; fails=$((fails + 1)); fi
  stacks="$(ssh_vm 'source <(grep "^STACKS=" homelab/homelab.env); echo $STACKS')"
  for s in $stacks; do
    h="$(sed -n 's/^HOST=//p' "$ROOT/stacks/$s/stack.conf" | tr -d '"')" # none for caddy
    if [[ -n "$h" ]]; then hosts+=" $h"; fi
  done
  for h in $hosts; do
    code="$(curl -s -o /dev/null -m 20 -w '%{http_code}' --cacert "$STATE/ca.crt" \
      --resolve "$h.homelab.internal:443:$ip" "https://$h.homelab.internal/" || true)"
    printf '  %-12s %s\n' "$h" "$code"
    [[ "$code" =~ ^(2|3)..$|^40[13]$ ]] || fails=$((fails + 1))
  done
  log "private overlay"
  local body
  body="$(curl -s -m 10 --cacert "$STATE/ca.crt" --resolve "hello.homelab.internal:443:$ip" https://hello.homelab.internal/)"
  [[ "$body" == "overlay route ok" ]] && echo "  route: ok" || { echo "  route: '$body'"; fails=$((fails + 1)); }
  ssh_vm 'curl -s -m 5 http://127.0.0.1:8091/' | grep -q 'overlay site ok' && echo "  top-level site + compose override: ok" || { echo "  top-level site: FAIL"; fails=$((fails + 1)); }
  ssh_vm 'grep -q "Overlay Tile" homelab/stacks/homepage/config/services.yaml && grep -q "^- Custom:" homelab/stacks/homepage/config/services.yaml' \
    && echo "  dashboard tiles: ok" || { echo "  dashboard tiles: FAIL"; fails=$((fails + 1)); }
  curl -s -m 10 --cacert "$STATE/ca.crt" --resolve "map.homelab.internal:443:$ip" https://map.homelab.internal/topology.md | grep -q overlay-marker \
    && echo "  map: ok" || { echo "  map: FAIL"; fails=$((fails + 1)); }
  ssh_vm 'grep -q "extra.example.test" homelab/rendered/cloudflared/config.yml' && echo "  tunnel entry: ok" || { echo "  tunnel entry: FAIL"; fails=$((fails + 1)); }
  log "per-stack checks"
  for s in $stacks; do
    [[ -f "$HERE/stacks/$s.sh" ]] || continue
    # shellcheck disable=SC1090
    ( source "$HERE/stacks/$s.sh" ) || { echo "  $s: FAIL"; fails=$((fails + 1)); }
  done
  log "backup run (heartbeat to a listener in the VM)"
  ssh_vm 'cat > /tmp/hb.py' <<'PY'
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        open("/tmp/heartbeat.json", "wb").write(body)
        self.send_response(200); self.end_headers()
http.server.HTTPServer(("127.0.0.1", 8098), H).handle_request()
PY
  ssh_vm 'rm -f /tmp/heartbeat.json; setsid nohup timeout 1800 python3 /tmp/hb.py >/dev/null 2>&1 < /dev/null &
    cd homelab && touch extras/backup/.env && source lib/common.sh && env_set extras/backup/.env BACKUP_HEARTBEAT_URL http://127.0.0.1:8098/'
  # Off-site copy through rclone, with a local folder standing in for the cloud.
  ssh_vm 'command -v rclone >/dev/null || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq rclone >/dev/null
    printf "[offsite]\ntype = local\n" | sudo install -m 600 /dev/stdin /etc/homelab/rclone.conf
    cd homelab && source lib/common.sh && env_set homelab.env BACKUP_OFFSITE rclone:offsite:/srv/offsite/restic'
  ssh_vm 'sudo systemctl start homelab-backup.service; systemctl show homelab-backup.service -p Result --value; sudo tail -n 8 /var/log/homelab-backup.log; sudo ls /srv/backup /srv/backup/db-dumps'
  if ssh_vm 'grep -q "\"status\": \"ok\"" /tmp/heartbeat.json && cat /tmp/heartbeat.json'; then echo "  heartbeat: ok"
  else echo "  heartbeat: FAIL"; fails=$((fails + 1)); fi
  if ssh_vm 'grep -q "\"offsite\": \"ok\"" /tmp/heartbeat.json \
      && sudo RCLONE_CONFIG=/etc/homelab/rclone.conf restic -r rclone:offsite:/srv/offsite/restic \
           --password-file /etc/homelab/restic-password snapshots --compact | tail -n 3'; then echo "  off-site copy: ok"
  else echo "  off-site copy: FAIL"; fails=$((fails + 1)); fi
  ((fails == 0)) || { echo "$fails check(s) failed"; exit 1; }
  log "verify passed"
}

down() { log "deleting $VM"; incus delete -f "$VM" 2>/dev/null || true; }

full() {
  # Fresh VM: a scoped run's leftover config would narrow the stacks.
  down; up; install; verify; install; verify
  ssh_vm -t 'cd homelab && tests/restore-test.sh'
  ssh_vm -t 'bash homelab/tests/rebuild-test.sh'
}

# scoped <scope.sh output>: a fresh VM with only those stacks.
scoped() {
  case "$1" in
    none) log "docs-only change: nothing to test in a VM" ;;
    full) log "shared code changed: full suite"; full ;;
    stacks\ *)
      export TEST_STACKS="${1#stacks }"
      log "scoped run: $TEST_STACKS"
      down; up; install; verify
      log "scoped run passed: $TEST_STACKS" ;;
    *) echo "unexpected scope: $1"; exit 1 ;;
  esac
}

case "${1:-all}" in
  up) up ;;
  install) install ;;
  verify) verify ;;
  rerun) install ;;
  restore) log "restore test (in the VM)"; ssh_vm -t 'cd homelab && tests/restore-test.sh' ;;
  rebuild) log "rebuild from backups (in the VM)"; ssh_vm -t 'bash homelab/tests/rebuild-test.sh' ;;
  ssh) ssh_vm -t 'cd homelab 2>/dev/null; exec bash -l' ;;
  down) down ;;
  all) full ;;
  scope) "$HERE/scope.sh" "${2:-origin/master}" ;;
  changed) scoped "$("$HERE/scope.sh" "${2:-origin/master}")" ;;
  stacks) [[ -n "${2:-}" ]] || { echo 'usage: tests/vm.sh stacks "a b"'; exit 1; }
          scoped "$("$HERE/scope.sh" --stacks "$2")" ;;
  *) sed -n '2,26p' "$0"; exit 1 ;;
esac
