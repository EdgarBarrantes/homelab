#!/usr/bin/env bash
# Which stacks does a change need tested? Prints one line:
#   full              shared code changed: run the whole suite
#   none              docs only: no VM needed
#   stacks <a b ...>  only these (with what they need and what needs them)
#
#   tests/scope.sh [base]            changes since base (default origin/master),
#                                    committed or not
#   tests/scope.sh --stacks "a b"    expand an explicit list
#
# A stack pulls in its NEEDS, the stacks whose NEEDS name it, and its
# TEST_WITH (stacks that interact with it without needing it, e.g.
# paperless-ngx and actual-budget). caddy and homepage are always in.
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

base="${1:-origin/master}"
files="$( { git diff --name-only "$base"...HEAD; git diff --name-only HEAD; git ls-files --others --exclude-standard; } | sort -u)"
[[ -n "$files" ]] || { echo none; exit 0; }

stacks=() full=0
while IFS= read -r f; do
  case "$f" in
    stacks/caddy/*) full=1 ;;          # every route goes through it
    stacks/*/*) s="${f#stacks/}"; stacks+=("${s%%/*}") ;;
    tests/stacks/*) s="${f#tests/stacks/}"; stacks+=("${s%.sh}") ;;
    tests/fixtures/import-test.epub) stacks+=(calibre-web) ;;
    *.md|docs/*|extras/topology/*|LICENSE|.gitignore) ;;
    *) full=1 ;;                        # lib/, lab, install.sh, extras/backup, tests/, ...
  esac
done <<<"$files"

if ((full)); then echo full
elif ((${#stacks[@]} == 0)); then echo none
else expand "$(printf '%s\n' "${stacks[@]}" | sort -u | tr '\n' ' ')"
fi
