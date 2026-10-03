#!/bin/sh
# Defines ntfy's accounts from the generated secrets on every start
# (declarative auth-users/access/tokens), then serves.
#   phone    reads every topic, logs in with NTFY_PHONE_PASSWORD
#   homelab  publishes to every topic, with the token NTFY_PUBLISH_TOKEN
#            (its password is random and thrown away: token only)
set -eu
hash() { printf '%s\n%s\n' "$1" "$1" | ntfy user hash 2>/dev/null | tail -n 1; }
throwaway="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
NTFY_AUTH_USERS="phone:$(hash "$NTFY_PHONE_PASSWORD"):user,homelab:$(hash "$throwaway"):user"
NTFY_AUTH_ACCESS="phone:*:ro,homelab:*:wo"
NTFY_AUTH_TOKENS="homelab:$NTFY_PUBLISH_TOKEN:homelab services"
export NTFY_AUTH_USERS NTFY_AUTH_ACCESS NTFY_AUTH_TOKENS
unset NTFY_PHONE_PASSWORD
exec ntfy serve
