#!/usr/bin/env bash
# Runs INSIDE the test VM (tests/vm.sh restore): back up real data, turn the
# VM into a "new machine" (fresh databases, new secrets, photos in another
# folder), reinstall, `lab restore`, and check the data came back.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
source lib/common.sh
load_config

step() { printf '\n\e[1;35m[restore-test]\e[0m %s\n' "$*"; }
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

step "seed data"
wait_healthy immich_server
wait_healthy paperless_webserver
URL_PATH=/api/auth/admin-sign-up https photos -o /dev/null -H 'Content-Type: application/json' \
  -d '{"email":"restore@test.local","password":"RestoreTest123","name":"Restore Test"}' || true
old_pl_pw="$(env_get stacks/paperless-ngx/.env PAPERLESS_ADMIN_PASSWORD)"
URL_PATH=/api/tags/ https docs -o /dev/null -u "admin:$old_pl_pw" -d name=restore-marker
echo "photo marker" | sudo tee "$PHOTOS_DIR/restore-marker.txt" >/dev/null
echo "book marker" > "$BOOKS_DIR/restore-marker.txt"
old_db_sum="$(env_get stacks/immich/.env DB_PASSWORD | sha256sum)"

step "nightly backup, for real"
sudo systemctl start homelab-backup.service
[[ "$(systemctl show homelab-backup.service -p Result --value)" == success ]] || { sudo tail -20 /var/log/homelab-backup.log; fail "backup failed"; }
sudo tail -n 4 /var/log/homelab-backup.log

step "become a new machine: no databases, no data, new secrets, photos elsewhere"
./lab down >/dev/null 2>&1
gone="$HOME/old-machine-$(date +%s)"; mkdir -p "$gone"
for p in stacks/immich/postgres stacks/immich/.env stacks/paperless-ngx/data stacks/paperless-ngx/.env \
         stacks/calibre-web/config "$PHOTOS_DIR" "$BOOKS_DIR"; do
  sudo mv "$p" "$gone/$(echo "$p" | tr '/' '_')"
done
env_set homelab.env PHOTOS_DIR /home/ubuntu/NewPhotos/Immich
./install.sh --yes >/dev/null 2>&1 || true
load_config
[[ "$(env_get stacks/immich/.env DB_PASSWORD | sha256sum)" != "$old_db_sum" ]] || fail "secrets were not regenerated"
wait_healthy immich_server
code="$(URL_PATH=/api/auth/login https photos -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
  -d '{"email":"restore@test.local","password":"RestoreTest123"}')"
[[ "$code" == 401 ]] || fail "fresh Immich already knows the user ($code)"
echo "fresh install: new secrets, empty Immich (login -> $code)"

step "lab restore --dry-run"
./lab restore --dry-run

step "lab restore"
./lab restore --yes

step "check"
wait_healthy immich_server
wait_healthy paperless_webserver
code="$(URL_PATH=/api/auth/login https photos -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
  -d '{"email":"restore@test.local","password":"RestoreTest123"}')"
[[ "$code" == 201 ]] || fail "Immich login after restore: $code"
echo "Immich: restored user logs in ($code), server runs on the new DB password"
tags="$(URL_PATH='/api/tags/?name__iexact=restore-marker' https docs -u "admin:$old_pl_pw")"
[[ "$tags" == *'"count":1'* ]] || fail "Paperless tag missing: $tags"
echo "Paperless: restore-marker tag is back"
[[ "$(sudo cat /home/ubuntu/NewPhotos/Immich/restore-marker.txt)" == "photo marker" ]] || fail "photo marker"
[[ "$(cat "$BOOKS_DIR/restore-marker.txt")" == "book marker" ]] || fail "book marker"
echo "files: photo marker in the NEW photos folder, book marker back"
./lab doctor
step "restore test passed"
