# Sourced by tests/vm.sh verify when stremio is installed. Through Caddy the
# web player and the streaming server's API answer on one name, the container
# has no DNS search domain, and nothing listens on the host.
ssh_vm 'cd homelab && source <(grep "^DOMAIN=" homelab.env)
  get() { curl -sk -m 10 --resolve "stremio.$DOMAIN:443:127.0.0.1" "https://stremio.$DOMAIN$1"; }
  for _ in $(seq 1 30); do get /settings 2>/dev/null | grep -q "\"cacheSize\"" && break; sleep 2; done
  get / | grep -qi "<!doctype html>" && get /settings | grep -q "\"cacheSize\"" || { echo "  stremio player or server not served"; exit 1; }
  ! docker exec stremio grep -q "^search" /etc/resolv.conf || { echo "  stremio has a DNS search domain"; exit 1; }
  ! curl -s -m 5 -o /dev/null http://127.0.0.1:8080/ && ! curl -s -m 5 -o /dev/null http://127.0.0.1:11470/ \
    || { echo "  stremio listens on the host"; exit 1; }' \
  && echo "  stremio (player and server through Caddy, no search domain, no host ports): ok"
