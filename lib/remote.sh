# install.sh --host: copy this repo to another machine over SSH and run the
# installer there, interactively. Sourced after common.sh.

# remote_install <user@host> <dir> <config file or ""> <original args...>
remote_install() {
  local host="$1" dir="$2" config="$3"; shift 3
  local args=() skip=0 a
  # Drop the options that only make sense here.
  for a in "$@"; do
    if ((skip)); then skip=0; continue; fi
    case "$a" in
      --host|--dir) skip=1 ;;
      --config) skip=1 ;;
      *) args+=("$a") ;;
    esac
  done

  local cm; cm="$(mktemp -d)"
  # One connection (and one password prompt at most) for every step below.
  # HOMELAB_SSH_OPTS: extra ssh options, e.g. "-i key -p 2222".
  # shellcheck disable=SC2206
  local ssh=(ssh ${HOMELAB_SSH_OPTS:-} -o ControlMaster=auto -o "ControlPath=$cm/%C" -o ControlPersist=120)
  trap '"${ssh[@]}" -O exit "$host" >/dev/null 2>&1 || true; rm -rf "$cm"' RETURN

  info "Connecting to $host"
  "${ssh[@]}" "$host" true || die "can't ssh to $host (see docs/machines.md#remote-install)"
  local rhome; rhome="$("${ssh[@]}" "$host" 'printf %s "$HOME"')"
  [[ "$dir" == /* ]] || dir="$rhome/$dir"
  ok "$host: $("${ssh[@]}" "$host" '. /etc/os-release; printf "%s, %s" "$PRETTY_NAME" "$(uname -m)"')"

  info "Copying the repo to $host:$dir"
  # Tracked and new (not ignored) files only: never local secrets or data.
  (cd "$ROOT" && if git rev-parse --git-dir >/dev/null 2>&1; then
     git ls-files -z -co --exclude-standard | tar --null -T - -czf -
   else
     tar --exclude='./stacks/*/data' --exclude='./stacks/*/.env' --exclude=./homelab.env \
         --exclude=./rendered -czf - .
   fi) | "${ssh[@]}" "$host" "mkdir -p '$dir' && tar -xzf - -C '$dir'"
  ok "copied (existing config and data on $host are kept)"

  if [[ -n "$config" ]]; then
    "${ssh[@]}" "$host" "umask 077 && cat > '$dir/homelab.env'" < "$config"
    args+=(--config homelab.env)
    ok "sent $config as $dir/homelab.env"
  fi

  info "Running the installer on $host"
  local q; q="$(printf '%q ' "${args[@]}")"
  "${ssh[@]}" -t "$host" "cd '$dir' && ./install.sh $q"
}
