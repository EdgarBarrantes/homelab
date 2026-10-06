# Shared helpers for install.sh and lab. Sourced, not executed.
# Expects ROOT to be set to the repo root.

HOMELAB_ENV="$ROOT/homelab.env"
STACKS_DIR="$ROOT/stacks"
RENDER_DIR="$ROOT/rendered"   # generated config, gitignored

if [[ -t 1 ]]; then
  C_RED=$'\e[31m' C_GRN=$'\e[32m' C_YLW=$'\e[33m' C_BLU=$'\e[34m'
  C_DIM=$'\e[2m' C_B=$'\e[1m' C_0=$'\e[0m'
else
  C_RED='' C_GRN='' C_YLW='' C_BLU='' C_DIM='' C_B='' C_0=''
fi

say()  { printf '%s\n' "$*"; }
info() { HOMELAB_STEP="$*"; printf '%s==>%s %s\n' "$C_BLU" "$C_0" "$*"; }
ok()   { printf '  %s✔%s %s\n' "$C_GRN" "$C_0" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_YLW" "$C_0" "$*"; }
bad()  { printf '  %s✘%s %s\n' "$C_RED" "$C_0" "$*"; }
hint() { printf '    %s%s%s\n' "$C_DIM" "$*" "$C_0"; }
die()  { HOMELAB_DIED=1; printf '%serror:%s %s\n' "$C_RED" "$C_0" "$*" >&2; exit 1; }

# EXIT trap for install.sh and lab: a set -e stop would otherwise be silent.
on_exit() {
  local rc=$?
  if ((rc != 0 && rc != 130)) && [[ -z "${HOMELAB_DIED:-}" ]]; then
    printf '%serror:%s stopped unexpectedly (exit %s)%s. Nothing was rolled back; re-run once fixed.\n' \
      "$C_RED" "$C_0" "$rc" "${HOMELAB_STEP:+ during: $HOMELAB_STEP}" >&2
  fi
}

# ask <prompt> <default>: prints the answer. Non-interactive returns default.
ask() {
  local reply
  if [[ "${ASSUME_YES:-0}" == 1 || ! -t 0 ]]; then printf '%s' "$2"; return; fi
  read -r -p "  $1 [${2}]: " reply </dev/tty
  printf '%s' "${reply:-$2}"
}

# confirm <prompt> [default y|n]
confirm() {
  local def="${2:-y}" reply
  [[ "${ASSUME_YES:-0}" == 1 ]] && return 0
  [[ -t 0 ]] || { [[ "$def" == y ]]; return; }
  read -r -p "  $1 [$([[ $def == y ]] && echo Y/n || echo y/N)]: " reply </dev/tty
  reply="${reply:-$def}"
  [[ "$reply" =~ ^[Yy] ]]
}

# --- env files (KEY=value, one per line, no quoting magic) ---------------

# env_get <file> <key>: value of the last KEY= line, empty if absent.
env_get() {
  [[ -f "$1" ]] || return 0
  sed -n "s/^$2=//p" "$1" | tail -n 1 | sed -e "s/^\"\(.*\)\"$/\1/; s/^'\(.*\)'$/\1/"
}

# env_set <file> <key> <value>: replace or append, keeping everything else.
env_set() {
  local file="$1" key="$2" val="$3" tmp
  # Single quotes are literal in both bash and Compose env files.
  [[ "$val" =~ [^A-Za-z0-9_./:@,+=%-] ]] && val="'$val'"
  touch "$file"
  tmp="$(mktemp)"
  awk -v k="$key" -v v="$val" '
    BEGIN { done = 0 }
    $0 ~ "^" k "=" { if (!done) { print k "=" v; done = 1 }; next }
    { print }
    END { if (!done) print k "=" v }
  ' "$file" > "$tmp"
  cat "$tmp" > "$file"   # keep the original inode and mode
  rm -f "$tmp"
}

# Load homelab.env into the environment (exported, for templating).
load_config() {
  [[ -f "$HOMELAB_ENV" ]] || return 1
  set -a
  # shellcheck disable=SC1090
  source "$HOMELAB_ENV"
  set +a
}

# is_yes <value>
is_yes() { [[ "${1,,}" =~ ^(y|yes|true|1|on)$ ]]; }

# --- stacks --------------------------------------------------------------

# Every stack folder, caddy first, the rest alphabetical.
all_stacks() {
  local d s
  [[ -d "$STACKS_DIR/caddy" ]] && echo caddy
  for d in "$STACKS_DIR"/*/; do
    s="$(basename "$d")"
    [[ "$s" == caddy ]] && continue
    [[ -f "$d/stack.conf" ]] && echo "$s"
  done
}

# Stacks listed in STACKS= in homelab.env, in start order.
enabled_stacks() {
  local s
  for s in $(all_stacks); do
    [[ " ${STACKS:-} " == *" $s "* ]] && echo "$s"
  done
  return 0  # not the last test's status: callers may run under set -e
}

is_enabled() { [[ " ${STACKS:-} " == *" $1 "* ]]; }

# stack_meta <stack> <KEY>: a value from stacks/<stack>/stack.conf.
stack_meta() {
  ( # subshell: stack.conf variables must not leak
    DESCRIPTION='' GROUP='' HOST='' PUBLIC='' PUBLIC_PORT='' NEEDS='' GPU=''
    HEAVY='' RAM_GB=0 DISK_GB=0 SECRETS='' OVERLAYS='' DIRS='' PROFILES='' TEST_WITH=''
    CONTAINERS='' BACKUP_PATHS=''
    PG_CONTAINER='' PG_SERVICE='' PG_USER='' PG_DUMP='' PG_PASSWORD_KEY='' PG_DATA=''
    # shellcheck disable=SC1090
    source "$STACKS_DIR/$1/stack.conf"
    printf '%s' "${!2}"
  )
}

# --- templating ----------------------------------------------------------

# render_template: stdin -> stdout, replacing ${VAR} for VAR in homelab.env
# (plus a few derived ones). Other ${...} are left alone, so Caddy's
# {$DOMAIN} and Compose-style defaults survive untouched.
render_template() {
  local keys k
  keys="$(sed -n 's/^\([A-Z_][A-Z0-9_]*\)=.*/\1/p' "$HOMELAB_ENV" 2>/dev/null | sort -u)"
  keys+=$'\n'"ROOT"
  local perl_args=()
  for k in $keys; do perl_args+=("$k"); done
  ROOT="$ROOT" perl -pe '
    BEGIN { %ok = map { $_ => 1 } @ARGV; @ARGV = (); }
    s/\$\{([A-Z_][A-Z0-9_]*)\}/exists $ok{$1} ? ($ENV{$1} \/\/ "") : "\${$1}"/ge
  ' "${perl_args[@]}"
}
