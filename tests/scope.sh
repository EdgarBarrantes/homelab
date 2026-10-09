#!/usr/bin/env bash
# How much testing does a change need? Prints one line, the highest level
# any changed file asks for:
#   none              docs, setup texts, the map: nothing to run
#   check             host-only checks, seconds (tests/check.sh): a tile, a
#                     description, documented env keys, an image bump within
#                     the same major version, the HA/remote-pause extras
#   stacks <a b ...>  a scoped VM run of these stacks (with what they need,
#                     what needs them, and their TEST_WITH): a stack's runtime
#                     (compose services, Dockerfile, scripts, its route), a
#                     major image bump, a new stack
#   install           every stack: install, verify, re-install, verify; no
#                     drills: shared code (lab, lib/, install.sh, Caddy, the
#                     test harness)
#   full              install + the restore and rebuild drills: backup and
#                     restore code, the drills, a stack's PG_*/BACKUP_PATHS,
#                     and shared code whose diff mentions backups/restores
#
#   tests/scope.sh [base]            changes since base (default origin/master),
#                                    committed or not
#   tests/scope.sh --stacks "a b"    expand an explicit list
#   tests/scope.sh --classify FILE   level for one file, its diff on stdin
#                                    (used by tests/check.sh's self-test)
#
# A stack pulls in its NEEDS, the stacks whose NEEDS name it, and its
# TEST_WITH (stacks that interact with it without needing it, e.g.
# paperless-ngx and actual-budget). caddy and homepage are always in.
# Unknown paths count as install: when in doubt, test more.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
STACKS_DIR="$ROOT/stacks"
source lib/common.sh

expand() {
  local want=" caddy homepage $* " s n changed=1
  while ((changed)); do
    changed=0
    for s in $(all_stacks); do
      [[ "$want" == *" $s "* ]] || continue
      for n in $(stack_meta "$s" NEEDS) $(stack_meta "$s" TEST_WITH); do
        [[ "$want" == *" $n "* ]] || { want+="$n "; changed=1; }
      done
    done
    for s in $(all_stacks); do # reverse NEEDS: what depends on a wanted stack
      [[ "$want" == *" $s "* ]] && continue
      for n in $(stack_meta "$s" NEEDS); do
        [[ "$want" == *" $n "* ]] && { want+="$s "; changed=1; break; }
      done
    done
  done
  # In start order, as all_stacks lists them.
  local out=()
  for s in $(all_stacks); do [[ "$want" == *" $s "* ]] && out+=("$s"); done
  echo "stacks ${out[*]}"
}

if [[ "${1:-}" == --stacks ]]; then
  for s in ${2:-}; do [[ -f "$STACKS_DIR/$s/stack.conf" ]] || die "no such stack: $s"; done
  expand ${2:-}
  exit 0
fi

LEVELS=(none check stacks install full)

# classify <file> <changed lines>: prints "<level> [stack]".
classify() {
  local f="$1" lines="$2" s=""
  case "$f" in
    stacks/*/*|tests/stacks/*) s="${f#stacks/}"; s="${s#tests/}"; s="${s#stacks/}"; s="${s%%/*}"; s="${s%.sh}" ;;
  esac
  case "$f" in
    *.md|docs/*|LICENSE|.gitignore|extras/topology/*|stacks/*/setup.txt) echo none ;;
    tests/scope.sh|tests/check.sh|homelab.env.example|stacks/*/homepage.yaml|stacks/*/.env.example \
      |extras/remote-pause/*|extras/homeassistant/*) echo check ;;
    stacks/*/stack.conf)
      if grep -qE '^[+-](PG_[A-Z_]*|BACKUP_PATHS)=' <<<"$lines"; then echo full
      elif grep -vE '^[+-](DESCRIPTION|GROUP|RAM_GB|DISK_GB)=' <<<"$lines" | grep -q .; then echo "stacks $s"
      else echo check; fi ;;
    stacks/caddy/*) echo install ;;
    stacks/*/*.yml)
      if image_bump_only "$lines"; then echo check; else echo "stacks $s"; fi ;;
    stacks/*/*|tests/stacks/*) echo "stacks $s" ;;
    tests/fixtures/import-test.epub) echo "stacks calibre-web" ;;
    extras/paperless-ai/*) echo "stacks paperless-ngx" ;;
    lib/restore.sh|extras/backup/*|tests/restore-test.sh|tests/rebuild-test.sh) echo full ;;
    lib/*|lab|install.sh|tests/vm.sh|tests/vm.env|tests/fixtures/*)
      if grep -qiE 'backup|restore|restic|PG_' <<<"$lines"; then echo full; else echo install; fi ;;
    *) echo install ;;
  esac
}

# image_bump_only <changed lines>: only `image:` lines changed, pairwise,
# and each keeps its major version (26.9.0 -> 26.10.1 yes, 2.x -> 3.x no).
image_bump_only() {
  local old=() new=() l i major
  [[ -n "$1" ]] || return 1
  major() { sed -E 's/.*:([^:@]*)(@.*)?$/\1/; s/^[^0-9]*([0-9]+).*/\1/' <<<"$1"; }
  while IFS= read -r l; do
    case "$l" in
      -*image:*) old+=("$l") ;;
      +*image:*) new+=("$l") ;;
      *) return 1 ;;
    esac
  done <<<"$1"
  ((${#old[@]} == ${#new[@]})) || return 1
  for i in "${!old[@]}"; do
    [[ "$(sed -E 's/^-\s*image:\s*([^:@]*).*/\1/' <<<"${old[$i]}")" == "$(sed -E 's/^\+\s*image:\s*([^:@]*).*/\1/' <<<"${new[$i]}")" ]] || return 1
    [[ "$(major "${old[$i]}")" == "$(major "${new[$i]}")" ]] || return 1
  done
}

if [[ "${1:-}" == --classify ]]; then classify "$2" "$(cat)"; exit 0; fi

base="${1:-origin/master}"
files="$( { git diff --name-only "$base"...HEAD; git diff --name-only HEAD; git ls-files --others --exclude-standard; } | sort -u)"
[[ -n "$files" ]] || { echo none; exit 0; }

level=0 stacks=()
while IFS= read -r f; do
  if git ls-files --error-unmatch -- "$f" >/dev/null 2>&1 || git cat-file -e "$base:$f" 2>/dev/null; then
    lines="$( { git diff "$base"...HEAD -- "$f"; git diff HEAD -- "$f"; } | grep -E '^[+-]' | grep -vE '^(\+\+\+|---) ' || true)"
  else
    lines="$( [[ -f "$f" ]] && sed 's/^/+/' "$f" || true)"
  fi
  read -r lv s <<<"$(classify "$f" "$lines")"
  for i in "${!LEVELS[@]}"; do [[ "${LEVELS[$i]}" == "$lv" ]] && n=$i; done
  ((n > level)) && level=$n
  [[ -n "${s:-}" ]] && stacks+=("$s")
done <<<"$files"

case "${LEVELS[$level]}" in
  stacks) expand "$(printf '%s\n' "${stacks[@]}" | sort -u | tr '\n' ' ')" ;;
  *) echo "${LEVELS[$level]}" ;;
esac
