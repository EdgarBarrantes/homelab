#!/usr/bin/env bash
# Runs INSIDE the test VM (tests/vm.sh rebuild): the "disk died" drill.
# Back up, then destroy everything except the backup target and the restic
# password (which would come from a password manager): the repo checkout
# with every .env and homelab.env, the private overlay, the photo and book
# folders, /etc/homelab and the systemd units. Then a fresh copy of the code
# and one command, ./install.sh --from-backup, must bring it all back.
set -euo pipefail
cd "$HOME/homelab"
ROOT="$PWD"
source lib/common.sh
load_config

step() { printf '\n\e[1;35m[rebuild-test]\e[0m %s\n' "$*"; }
fail() { printf '\e[31mFAIL:\e[0m %s\n' "$*"; exit 1; }
https() { # <host> <curl args...>
  local h="$1.$DOMAIN"; shift
  curl -sk --resolve "$h:443:127.0.0.1" "$@" "https://$h${URL_PATH:-/}"
}
wait_healthy() {
  for _ in $(seq 1 90); do
    [[ "$(docker inspect -f '{{.State.Health.Status}}' "$1" 2>/dev/null)" == healthy ]] && return 0
    sleep 4
  done
  fail "$1 not healthy"
}

step "seed data and back up"
wait_healthy paperless_webserver
pl_pw="$(env_get stacks/paperless-ngx/.env PAPERLESS_ADMIN_PASSWORD)"
URL_PATH=/api/tags/ https docs -o /dev/null -u "admin:$pl_pw" -d name=rebuild-marker
echo "rebuild marker" | sudo tee "$PHOTOS_DIR/rebuild-marker.txt" >/dev/null
env_sums="$(cat stacks/*/.env | sha256sum)"
stacks_before="$STACKS"
sudo systemctl start homelab-backup.service
[[ "$(systemctl show homelab-backup.service -p Result --value)" == success ]] || { sudo tail -20 /var/log/homelab-backup.log; fail "backup failed"; }

step "the disk dies: only $BACKUP_DIR and the restic password survive"
cp_pw="$HOME/restic-password-from-password-manager"
sudo cat /etc/homelab/restic-password > "$cp_pw"; chmod 600 "$cp_pw"
./install.sh --uninstall --yes >/dev/null
gone="$HOME/dead-disk-$(date +%s)"; mkdir -p "$gone"
sudo mv "$HOME/homelab" "$gone/homelab"
sudo mv "$LOCAL_DIR" "$gone/overlay"
sudo mv "$PHOTOS_DIR" "$gone/photos"
sudo mv "$BOOKS_DIR" "$gone/books"
sudo rm -f /etc/homelab/restic-password /etc/homelab/smb-credentials
# A fresh copy of the code only (what `git clone` would give): no .env,
# no homelab.env, no data, nothing rendered.
mkdir -p "$HOME/homelab"
tar -C "$gone/homelab" --exclude='./stacks/*/data' --exclude='./stacks/*/config' \
  --exclude='./stacks/*/cache' --exclude='./stacks/*/tmp' --exclude='./stacks/*/postgres' \
  --exclude='./stacks/*/.env' --exclude='./stacks/*/postgres.pre-restore-*' \
  --exclude='./stacks/*/data.pre-restore-*' --exclude=./homelab.env --exclude=./rendered \
  --exclude=./restore --exclude=./extras/backup/.env -cf - . | tar -xf - -C "$HOME/homelab"
cd "$HOME/homelab"
ls homelab.env stacks/*/.env 2>/dev/null && fail "fresh copy still has config"
echo "fresh code, no config; password back from the 'password manager'"
sudo install -d -m 700 /etc/homelab
sudo install -m 600 "$cp_pw" /etc/homelab/restic-password

step "./install.sh --from-backup $BACKUP_DIR --yes"
./install.sh --from-backup "$BACKUP_DIR" --yes

step "check"
load_config
[[ "$STACKS" == "$stacks_before" ]] || fail "stacks differ: $STACKS"
[[ "$(cat stacks/*/.env | sha256sum)" == "$env_sums" ]] || fail "stack .env files differ from before"
echo "config: homelab.env and every .env are back, identical"
[[ -f "$LOCAL_DIR/topology.md" ]] || fail "overlay not restored"
[[ "$(https hello)" == "overlay route ok" ]] || fail "overlay route"
echo "overlay: restored and serving"
wait_healthy immich_server
wait_healthy paperless_webserver
code="$(URL_PATH=/api/auth/login https photos -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
  -d '{"email":"restore@test.local","password":"RestoreTest123"}')"
[[ "$code" == 201 ]] || fail "Immich login: $code"
tags="$(URL_PATH='/api/tags/?name__iexact=rebuild-marker' https docs -u "admin:$pl_pw")"
[[ "$tags" == *'"count":1'* ]] || fail "Paperless tag missing"
[[ "$(sudo cat "$PHOTOS_DIR/rebuild-marker.txt")" == "rebuild marker" ]] || fail "photo marker"
echo "data: Immich user, Paperless tag and photos are back"
systemctl is-active --quiet homelab-backup.timer || fail "backup timer not re-enabled"
./lab doctor
step "rebuild test passed"
