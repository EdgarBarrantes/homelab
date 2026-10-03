# Sourced by tests/vm.sh verify when ntfy is installed: anonymous publishing
# is refused, the token publishes, the phone account reads, and the watcher
# alerts when Home Assistant doesn't answer (a dead address, 1 s checks).
ssh_vm 'cd homelab && source <(grep "^NTFY_" stacks/ntfy/.env)
  auth="Authorization: Basic $(printf "phone:%s" "$NTFY_PHONE_PASSWORD" | base64)"
  ! docker exec ntfy wget -q -O /dev/null --post-data=x http://localhost/homelab-alerts 2>/dev/null &&
  docker exec ntfy wget -q -O /dev/null --header "Authorization: Bearer $NTFY_PUBLISH_TOKEN" --post-data="vm test" http://localhost/homelab-alerts &&
  docker exec ntfy wget -q -O - --header "$auth" "http://localhost/homelab-alerts/json?poll=1" | grep -q "vm test" &&
  c="$(./lab compose ntfy run -d -e HA_URL=http://127.0.0.1:9 -e WATCH_INTERVAL=1 -e WATCH_DOWN_AFTER=2 ntfy-watch 2>/dev/null | tail -n 1)" &&
  sleep 8 && docker rm -f "$c" >/dev/null &&
  docker exec ntfy wget -q -O - --header "$auth" "http://localhost/homelab-alerts/json?poll=1" | grep -q "Home Assistant is down"' \
  && echo "  ntfy (auth, watcher): ok"
