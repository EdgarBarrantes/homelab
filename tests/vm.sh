#!/usr/bin/env bash
# Test the installer end to end in a throwaway Ubuntu 24.04 VM (Incus).
# Nothing touches the host except the VM itself. No Cloudflare, no
# Tailscale: TLS_MODE=internal (Caddy's own CA), config in tests/vm.env.
#
#   tests/vm.sh up        create the VM (4 CPU, 8 GiB, 40 GiB disk)
#   tests/vm.sh install   ./install.sh --host ubuntu@<vm> --config tests/vm.env --yes
#   tests/vm.sh verify    lab doctor + HTTPS from the host + a backup run
#   tests/vm.sh rerun     install again (must be idempotent)
#   tests/vm.sh restore   back up, wipe to a "new machine", lab restore, check
#   tests/vm.sh ssh       shell in the VM
#   tests/vm.sh down      delete the VM
#   tests/vm.sh all       up, install, verify, rerun, verify, restore
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
    incus launch images:ubuntu/24.04/cloud "$VM" --vm \
      -c limits.cpu=4 -c limits.memory=8GiB -d root,size=40GiB \
      -c cloud-init.user-data="#cloud-config
users:
  - name: ubuntu
    shell: /bin/bash
    groups: [sudo]
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys: [\"$(cat "$KEY.pub")\"]
packages: [openssh-server]
"
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
  timeout --foreground 45m "$ROOT/install.sh" --host "ubuntu@$ip" --config "$HERE/vm.env" --yes
}

verify() {
  local ip; ip="$(vm_ip)"
  log "lab doctor in the VM"
  ssh_vm 'cd homelab && ./lab doctor'
  log "HTTPS from the host through the VM's Caddy (internal CA)"
  ssh_vm 'cat homelab/rendered/caddy-local-ca.crt' > "$STATE/ca.crt"
  local h code fails=0
  for h in dash photos docs budget files books backrest glances map; do
    code="$(curl -s -o /dev/null -m 20 -w '%{http_code}' --cacert "$STATE/ca.crt" \
      --resolve "$h.homelab.internal:443:$ip" "https://$h.homelab.internal/" || true)"
    printf '  %-12s %s\n' "$h" "$code"
    [[ "$code" =~ ^(2|3)..$|^40[13]$ ]] || fails=$((fails + 1))
  done
  log "backup run"
  ssh_vm 'sudo systemctl start homelab-backup.service; systemctl show homelab-backup.service -p Result --value; sudo tail -n 8 /var/log/homelab-backup.log; sudo ls /srv/backup /srv/backup/db-dumps'
  ((fails == 0)) || { echo "$fails route(s) failed"; exit 1; }
  log "verify passed"
}

down() { log "deleting $VM"; incus delete -f "$VM" 2>/dev/null || true; }

case "${1:-all}" in
  up) up ;;
  install) install ;;
  verify) verify ;;
  rerun) install ;;
  restore) log "restore test (in the VM)"; ssh_vm -t 'cd homelab && tests/restore-test.sh' ;;
  ssh) ssh_vm -t 'cd homelab 2>/dev/null; exec bash -l' ;;
  down) down ;;
  all) up; install; verify; install; verify; ssh_vm -t 'cd homelab && tests/restore-test.sh' ;;
  *) sed -n '2,16p' "$0"; exit 1 ;;
esac
