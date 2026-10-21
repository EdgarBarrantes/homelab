#!/bin/sh
# Keeps NetAlertX's UI off the LAN: with host networking it would listen on
# every interface, so it listens only on Docker's host gateway (docker0),
# where Caddy reaches it as host.docker.internal. Then the image's own
# entrypoint, which runs settings.py among its start checks.
# "start.sh addr" only prints that address (for the healthcheck).
set -eu
LISTEN_ADDR="$(ip -4 -o addr show dev docker0 | sed -n 's/.* inet \([0-9.]*\)\/.*/\1/p' | head -n 1)"
[ -n "$LISTEN_ADDR" ] || { echo "netalertx: docker0 has no IPv4 address"; exit 1; }
[ "${1:-}" != addr ] || { echo "$LISTEN_ADDR"; exit 0; }
export LISTEN_ADDR
exec /root-entrypoint.sh
