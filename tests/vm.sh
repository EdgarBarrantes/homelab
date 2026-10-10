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
#   tests/vm.sh suite     the same without the restore and rebuild drills
#   tests/vm.sh check     host-only checks (tests/check.sh), seconds, no VM
#
# Which one a change needs: `tests/vm.sh changed` (rules in tests/scope.sh):
#   none     docs, setup texts, the map
#   check    a tile, a description, env docs, an image bump in the same
#            major version, the HA/remote-pause extras
#   stacks   a stack's runtime (compose services, Dockerfile, scripts,
#            route), a major image bump, a new stack: scoped VM run
#   install  shared code (lab, lib/, install.sh, Caddy, the harness):
#            `suite`
#   full     backup/restore code, the drills, PG_*/BACKUP_PATHS: `all`
#
# Scoped runs, for a change to one or a few stacks (fresh VM, install,
# verify; the rerun, restore and rebuild drills belong to the full suite):
#   tests/vm.sh changed [base]   test what changed since base (origin/master):
#                                full suite, only some stacks, or nothing
#   tests/vm.sh stacks "a b"     only these stacks (plus what they need)
#   tests/vm.sh scope [base]     just print what `changed` would test
# Scope rules are in tests/scope.sh; per-stack checks in tests/stacks/<s>.sh.
#
# Speed: images from earlier runs are kept in an image cache on the host
# ($HOMELAB_TEST_CACHE, default ~/.cache/homelab-test/images) and loaded into
# the fresh VM before the install, so nothing is pulled twice. That means
# Docker is installed before install.sh runs (with install.sh's own
# fix_docker); HOMELAB_TEST_CACHE=off tests the installer's Docker step and
# real pulls (digest-pinned images, e.g. image:tag@sha256:..., are loaded
# but compose still fetches them: two small ones today). Locally built
# images (stacks with a Dockerfile) keep their
# BuildKit cache next to it (.../build/<stack>), imported before the
# install so `lab up --build` finds every step done; a changed Dockerfile
# only misses the steps it changed, and a cache older than 7 days is
# dropped so unpinned builds (Caddy's plugins) are redone weekly. A passed
# run deletes the VM (KEEP_VM=1 keeps it); a failed one leaves it for
# `tests/vm.sh ssh`. Every run ends with the time each phase took.
#
# Cache invalidation: an image saved under an exact version (x.y.z or a
# digest) is dropped 60 days after it was saved, any other tag (v3, 2,
# 17-alpine, latest: tags that move) after 7 days, so new upstream builds
# come in weekly; build caches also after 7 days. By hand:
#   tests/vm.sh cache                     list entries, age and size
#   tests/vm.sh cache clear [what]        delete: all (default), images,
#                                         build, or names matching <what>
#   HOMELAB_TEST_CACHE=off tests/vm.sh …  one run without the cache
#
# Needs: incus (user in incus-admin), KVM. VM name: $VM (default homelab-test).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
VM="${VM:-homelab-test}"
STATE="$HERE/.vm"
KEY="$STATE/id_ed25519"
export HOMELAB_SSH_OPTS="-i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=10"

CACHE="${HOMELAB_TEST_CACHE:-$HOME/.cache/homelab-test/images}"
BCACHE="$(dirname "$CACHE")/build"
# The image names in the compose files of the stacks under test (all of
# tests/vm.env, or TEST_STACKS), with ${VAR:-default} reduced to the default.
stacks_images() {
  local st="${TEST_STACKS:-$(sed -n 's/^STACKS="\(.*\)"/\1/p' "$HERE/vm.env")}" s
  for s in $st; do cat "$ROOT/stacks/$s"/*.yml 2>/dev/null; done \
    | sed -n -E 's/^ *image: *"?([^" ]+)"?.*/\1/p' | sed -E 's/\$\{[A-Z_]+:-([^}]*)\}/\1/g'
}

# context_sum <stack>: a checksum of the stack's build files (as sent to the
# build: everything but data/ and .env).
context_sum() {
  (cd "$ROOT/stacks/$1" && find . -type f ! -path './data/*' ! -name .env -print0 | sort -z \
    | xargs -0 sha256sum | sha256sum | cut -c1-16)
}

# Stacks that build their own image.
build_stacks() { local d; for d in "$ROOT"/stacks/*/Dockerfile; do basename "$(dirname "$d")"; done; }

T0=$SECONDS
PHASES=()
dur() { printf '%dm%02ds' $(($1 / 60)) $(($1 % 60)); }
log() { printf '\n\e[1;34m[vm %s +%s]\e[0m %s\n' "$(date +%T)" "$(dur $((SECONDS - T0)))" "$*"; }
# timed <name> <command...>: run it and remember how long it took.
timed() {
  local name="$1" t=$SECONDS; shift
  "$@"
  PHASES+=("$(printf '%-9s %s' "$name" "$(dur $((SECONDS - t)))")")
}
summary() {
  ((${#PHASES[@]})) || return 0
  printf '\n\e[1;34m[vm]\e[0m time per phase (total %s):\n' "$(dur $((SECONDS - T0)))"
  printf '  %s\n' "${PHASES[@]}"
}
trap summary EXIT

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
    local try img=homelab-test-ubuntu
    # Launch from a local copy of the image: the client sometimes hangs
    # talking to the image server (the daemon never sees an operation).
    # Refreshed weekly; a failed refresh keeps the old copy.
    if ! incus image info "$img" >/dev/null 2>&1 || [[ -n "$(find "$STATE/image-stamp" -mtime +7 2>/dev/null)" ]] \
       || [[ ! -f "$STATE/image-stamp" ]]; then
      log "refreshing the local Ubuntu 24.04 image"
      if timeout 600 incus image copy images:ubuntu/24.04/cloud local: --vm --alias "$img.new" >/dev/null; then
        incus image delete "$img" >/dev/null 2>&1 || true
        incus image alias rename "$img.new" "$img" && touch "$STATE/image-stamp"
      else
        incus image alias delete "$img.new" >/dev/null 2>&1 || true
        incus image info "$img" >/dev/null 2>&1 || { echo "no local image and the image server didn't answer"; exit 1; }
        log "image server didn't answer: using the local copy"
      fi
    fi
    # Still a timeout and one retry, for anything else that hangs.
    for try in 1 2; do
      timeout 300 incus launch "$img" "$VM" --vm \
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

# preload: Docker (install.sh's own fix_docker) and the cached images into
# the VM, so `lab up` finds them instead of pulling.
preload() {
  [[ "$CACHE" != off ]] || { log "image cache off: install.sh installs Docker and pulls"; return 0; }
  expire_cache
  local files=("$CACHE"/*.tar) f n=0
  [[ -e "${files[0]}" ]] || { log "image cache empty: this run pulls, then fills it"; return 0; }
  log "Docker and ${#files[@]} cached image(s) into the VM"
  { cat "$ROOT/lib/common.sh" "$ROOT/lib/checks.sh"; echo 'APT_LOG=/tmp/apt.log; fix_docker'; } \
    | ssh_vm 'ROOT=/tmp bash -s' >/dev/null
  # Only the images the tested stacks name (by repository, any tag), four
  # loads at a time.
  local want=() repos r
  repos="$(stacks_images | sed -E 's/[:@].*//; s|^docker\.io/||; s|^library/||' | sort -u)"
  for f in "${files[@]}"; do
    for r in $repos; do
      [[ "$(basename "$f")" == "$(tr '/:@' '___' <<<"$r")_"* ]] && { want+=("$f"); break; }
    done
  done
  export -f ssh_vm vm_ip; export VM HOMELAB_SSH_OPTS
  printf '%s\0' "${want[@]}" | xargs -0 -r -P4 -I{} bash -c 'ssh_vm "sudo docker load -q >/dev/null" < "$1"' _ {}
  n=${#want[@]}
  echo "  loaded $n of ${#files[@]} cached image(s)"
  # Warm BuildKit with each local build's saved cache (a cache-only build of
  # the same context), so lab's own build later is all cache hits.
  local s
  for s in $(build_stacks); do
    [[ -d "$BCACHE/$s" ]] || continue
    tar -C "$ROOT/stacks/$s" --exclude=./data --exclude=./.env -cf - . \
      | ssh_vm "rm -rf /tmp/build/$s && mkdir -p /tmp/build/$s/ctx /tmp/build/$s/cache && tar -xf - -C /tmp/build/$s/ctx"
    tar -C "$BCACHE/$s" -cf - . | ssh_vm "tar -xf - -C /tmp/build/$s/cache"
    ssh_vm "sudo docker buildx build -q --cache-from type=local,src=/tmp/build/$s/cache --output type=cacheonly /tmp/build/$s/ctx" \
      >/dev/null 2>&1 && echo "  build cache: $s" || echo "  build cache: $s not usable, it will be rebuilt"
  done
}

# save_cache: every pulled image of a passed install into the cache (once
# per image; tag, or digest for digest-pinned ones). Entries unused for 30
# days are dropped.
save_cache() {
  [[ "$CACHE" != off ]] || return 0
  mkdir -p "$CACHE"
  local ref f n=0
  # RepoTags, not `image ls`: with the containerd image store, ls leaves the
  # digest empty for digest-pinned images, while RepoTags has repo@sha256:...
  while read -r ref; do
    [[ -z "$ref" || "$ref" == local/* ]] && continue
    f="$CACHE/$(tr '/:@' '___' <<<"$ref").tar"
    [[ -f "$f" ]] && continue
    # </dev/null: ssh would otherwise eat the rest of the image list.
    ssh_vm "sudo docker save '$ref'" < /dev/null > "$f.part" && mv "$f.part" "$f" && n=$((n + 1))
  done < <(ssh_vm 'sudo docker image inspect -f "{{range .RepoTags}}{{println .}}{{end}}" $(sudo docker image ls -q)' | sort -u)
  rm -f "$CACHE"/*.part
  # BuildKit cache of each local build this install did (a cache-only
  # rebuild in the warm VM, exported), replacing the previous one. Kept
  # dates: a cache only gets a new mtime when it is rebuilt from scratch.
  local s t img sum
  for s in $(build_stacks); do
    # Only builds this install did: their image exists in the VM.
    img="$(sed -n 's/^ *image: *\(local\/[^ ]*\).*/\1/p' "$ROOT/stacks/$s/compose.yml" | head -n1)"
    [[ -n "$img" ]] && ssh_vm "sudo docker image inspect '$img' >/dev/null 2>&1" < /dev/null || continue
    # Export only when there is no cache yet or the build files changed:
    # re-exporting a build that was all cache hits loses the earlier
    # stages' layers (the next run would compile Caddy again).
    sum="$(context_sum "$s")"
    [[ -f "$BCACHE/$s/.context-sum" && "$(cat "$BCACHE/$s/.context-sum")" == "$sum" ]] && continue
    ssh_vm "cd homelab/stacks/$s && sudo rm -rf /tmp/bcx/$s && sudo docker buildx build -q --cache-to type=local,dest=/tmp/bcx/$s,mode=max --output type=cacheonly ." \
      < /dev/null >/dev/null 2>&1 || { echo "  build cache: $s not exported"; continue; }
    t="$(stat -c %y "$BCACHE/$s" 2>/dev/null || true)"
    mkdir -p "$BCACHE/$s.part"
    ssh_vm "sudo tar -C /tmp/bcx/$s -cf - ." < /dev/null | tar -xf - -C "$BCACHE/$s.part" \
      && echo "$sum" > "$BCACHE/$s.part/.context-sum" \
      && rm -rf "$BCACHE/$s" && mv "$BCACHE/$s.part" "$BCACHE/$s" \
      && { [[ -z "$t" ]] || touch -d "$t" "$BCACHE/$s"; }
  done
  rm -rf "$BCACHE"/*.part
  log "image cache: $n new image(s), $(du -sh "$CACHE" | cut -f1) in $CACHE; build cache $(du -sh "$BCACHE" 2>/dev/null | cut -f1)"
}

# expire_cache: drop entries past their age (see the header). Pinned =
# a digest, or a tag with an x.y.z version in it.
expire_cache() {
  local f days
  for f in "$CACHE"/*.tar; do
    [[ -e "$f" ]] || continue
    if [[ "$(basename "$f")" =~ sha256_|[0-9]+\.[0-9]+\.[0-9]+ ]]; then days=60; else days=7; fi
    [[ -n "$(find "$f" -mtime +"$days")" ]] && rm -f "$f" && echo "  expired: $(basename "$f")"
  done
  find "$BCACHE" -mindepth 1 -maxdepth 1 -type d -mtime +7 -print -exec rm -rf {} + 2>/dev/null \
    | sed 's|.*/|  expired build cache: |' || true
}

cache_cmd() {
  case "${1:-ls}" in
    ls)
      local f
      for f in "$CACHE"/*.tar "$BCACHE"/*; do
        [[ -e "$f" ]] || continue
        printf '  %-70s %6s  %s days\n' "${f#"$(dirname "$CACHE")"/}" "$(du -sh "$f" | cut -f1)" \
          $(( ($(date +%s) - $(stat -c %Y "$f")) / 86400 ))
      done
      echo "  total $(du -sh "$(dirname "$CACHE")" 2>/dev/null | cut -f1) in $(dirname "$CACHE")" ;;
    clear)
      case "${2:-all}" in
        all) rm -rf "$CACHE" "$BCACHE" ;;
        images) rm -rf "$CACHE" ;;
        build) rm -rf "$BCACHE" ;;
        *) find "$CACHE" "$BCACHE" -mindepth 1 -maxdepth 1 -name "*$2*" -print -exec rm -rf {} + 2>/dev/null || true ;;
      esac
      echo "cleared: ${2:-all}" ;;
    *) echo "usage: tests/vm.sh cache [ls | clear [all|images|build|<name>]]"; exit 1 ;;
  esac
}

# finish: a passed run deletes its VM unless KEEP_VM is set.
finish() { if [[ -n "${KEEP_VM:-}" ]]; then log "keeping $VM (KEEP_VM)"; else down; fi; }

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
  timed check "$HERE/check.sh"
  # Fresh VM: a scoped run's leftover config would narrow the stacks.
  down
  timed up up
  timed preload preload
  timed install install
  timed cache save_cache
  timed verify verify
  timed rerun install
  timed verify2 verify
  timed restore ssh_vm -t 'cd homelab && tests/restore-test.sh'
  timed rebuild ssh_vm -t 'bash homelab/tests/rebuild-test.sh'
  finish
}

# suite: every stack, install + verify + re-install + verify; no drills.
suite() {
  timed check "$HERE/check.sh"
  down
  timed up up
  timed preload preload
  timed install install
  timed cache save_cache
  timed verify verify
  timed rerun install
  timed verify2 verify
  finish
}

# scoped <scope.sh output>: what that level needs (see the header).
scoped() {
  case "$1" in
    none) log "docs only: nothing to run" ;;
    check) log "host-only checks"; "$HERE/check.sh" ;;
    install) log "shared code: install suite, no drills"; suite ;;
    full) log "backup/restore code: full suite"; full ;;
    stacks\ *)
      export TEST_STACKS="${1#stacks }"
      log "scoped run: $TEST_STACKS"
      timed check "$HERE/check.sh"
      down
      timed up up
      timed preload preload
      timed install install
      timed cache save_cache
      timed verify verify
      log "scoped run passed: $TEST_STACKS"
      finish ;;
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
  cache) cache_cmd "${@:2}" ;;
  ssh) ssh_vm -t 'cd homelab 2>/dev/null; exec bash -l' ;;
  down) down ;;
  all) full ;;
  suite) suite ;;
  check) "$HERE/check.sh" ;;
  scope) "$HERE/scope.sh" "${2:-origin/master}" ;;
  changed) scoped "$("$HERE/scope.sh" "${2:-origin/master}")" ;;
  stacks) [[ -n "${2:-}" ]] || { echo 'usage: tests/vm.sh stacks "a b"'; exit 1; }
          scoped "$("$HERE/scope.sh" --stacks "$2")" ;;
  *) sed -n '2,64p' "$0"; exit 1 ;;
esac
