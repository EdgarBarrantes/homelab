#!/usr/bin/env bash
# Host-only checks, seconds, no VM: the "check" level of tests/scope.sh, and
# the first step of every VM run.
#   - shell syntax of lab, install.sh, lib/, tests/, extras/, stack scripts
#   - every stack's compose files validate (with the example env files)
#   - YAML parses (compose, homepage tiles)
#   - every key in a stack's .env.example is documented (the lab keys rule:
#     a comment right above it, or listed in SECRETS)
#   - tests/scope.sh still classifies a set of known changes as expected
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
fails=0
pass() { printf '  \e[32m✔\e[0m %s\n' "$*"; }
fail() { printf '  \e[31m✘\e[0m %s\n' "$*"; fails=$((fails + 1)); }

# Shell syntax.
n=0
while IFS= read -r f; do
  bash -n "$f" 2>/dev/null || fail "syntax: $f"; n=$((n + 1))
done < <({ echo lab; echo install.sh; ls lib/*.sh tests/*.sh; find extras stacks -name '*.sh'; } | sort -u)
pass "shell syntax ($n files)"

# Compose: each stack's files, as lab would combine them, in a scratch copy
# with the test config as homelab.env and each .env.example as .env (empty
# keys get a dummy value; render fills them for real).
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cp -r stacks "$tmp/"; cp tests/vm.env "$tmp/homelab.env"
for ex in "$tmp"/stacks/*/.env.example; do sed 's/^\([A-Za-z_][A-Za-z0-9_]*\)=$/\1=\/tmp\/check/' "$ex" > "${ex%.example}"; done
for d in "$tmp"/stacks/*/; do [[ -f "$d.env" ]] || : > "$d.env"; done
n=0 before=$fails
for d in "$tmp"/stacks/*/; do
  s="$(basename "$d")" files=()
  for f in compose.yml docker-compose.yml docker-compose.override.yml; do [[ -f "$d$f" ]] && files+=(-f "$d$f"); done
  ((${#files[@]})) || continue
  out="$(cd "$d" && docker compose --env-file "$tmp/homelab.env" --env-file .env "${files[@]}" config --quiet 2>&1)" \
    || fail "compose: $s: ${out%%$'\n'*}"
  n=$((n + 1))
done
((fails > before)) || pass "compose config ($n stacks)"

# YAML.
if python3 - <<'PY'; then pass "yaml"; else fail "yaml (see above)"; fi
import glob, sys, yaml
# Compose's !override/!reset and PowerSync's !env: accept any tag.
yaml.SafeLoader.add_multi_constructor("!", lambda loader, suffix, node: None)
bad = 0
for f in sorted(glob.glob("stacks/*/*.yml") + glob.glob("stacks/*/*.yaml") + glob.glob("stacks/*/powersync/*.yaml")):
    try:
        yaml.safe_load(open(f))
    except Exception as e:
        print(f"    {f}: {e}"); bad += 1
sys.exit(1 if bad else 0)
PY

# .env.example: every key documented.
n=0
for ex in stacks/*/.env.example; do
  s="$(basename "$(dirname "$ex")")"
  gen=" $(sed -n 's/^SECRETS="\{0,1\}\([^"]*\)"\{0,1\}/\1/p' "stacks/$s/stack.conf") "
  prev=""
  while IFS= read -r line; do
    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]]; then
      k="${BASH_REMATCH[1]}"
      [[ "$prev" == \#* || "$gen" == *" $k "* ]] || fail "undocumented: $s $k (a comment right above it, in $ex)"
      n=$((n + 1))
    fi
    prev="$line"
  done < "$ex"
done
pass "documented env keys ($n)"

# scope.sh: known changes, expected levels.
t=0
expect() { # expect <level...> <file> <diff lines>
  local want="$1" got; got="$(printf '%s' "$3" | tests/scope.sh --classify "$2")"
  [[ "$got" == "$want" ]] || fail "scope: $2 -> '$got', expected '$want'"
  t=$((t + 1))
}
expect none        README.md ""
expect none        stacks/wger/setup.txt "+text"
expect check       stacks/wger/homepage.yaml "+    description: x"
expect check       stacks/wger/.env.example "+# doc"
expect check       stacks/wger/stack.conf "-DESCRIPTION=\"a\"
+DESCRIPTION=\"b\""
expect "stacks wger" stacks/wger/stack.conf "+HOST=fit"
expect full        stacks/wger/stack.conf "+BACKUP_PATHS='x'"
expect check       stacks/wger/compose.yml "-    image: wger/server:2.7.0
+    image: wger/server:2.8.1"
expect "stacks wger" stacks/wger/compose.yml "-    image: wger/server:2.7.0
+    image: wger/server:3.0.0"
expect "stacks wger" stacks/wger/compose.yml "-    image: wger/server:2.7.0
+    image: other/server:2.7.1"
expect "stacks wger" stacks/wger/compose.yml "+      TZ: x"
expect "stacks vikunja" stacks/vikunja/start.sh "+echo"
expect "stacks dawarich" tests/stacks/dawarich.sh "+echo"
expect install     stacks/caddy/Dockerfile "+RUN x"
expect install     lab "+  up_mode() {"
expect full        lab "+  restore) x"
expect full        extras/backup/backup.sh "+x"
expect full        tests/restore-test.sh "+x"
expect check       extras/remote-pause/lab-remote.sh "+x"
expect install     something/new "+x"
pass "scope rules ($t cases)"

((fails == 0)) || { echo "$fails check(s) failed"; exit 1; }
echo "checks passed"
