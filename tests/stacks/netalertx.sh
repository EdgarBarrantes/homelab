# Sourced by tests/vm.sh verify when netalertx is installed. Host networking
# would put its UI and API on every interface: the UI must listen only on
# Docker's host gateway (Caddy's way in) and the API only on loopback.
# Through Caddy it must ask for the generated password and let it in; it
# must scan only NET_IFACE's subnet and push with ntfy's token.
ssh_vm 'cd homelab && source <(grep "^NETALERTX_PASSWORD=" stacks/netalertx/.env) && source <(grep -E "^(DOMAIN|NET_IFACE)=" homelab.env)
  gw="$(ip -4 -o addr show dev docker0 | sed -n "s/.* inet \([0-9.]*\)\/.*/\1/p")"
  for _ in $(seq 1 30); do [ "$(docker inspect netalertx --format "{{.State.Health.Status}}")" = healthy ] && break; sleep 4; done
  listen="$(ss -ltnH "( sport = :20211 or sport = :20212 )" | awk "{print \$4}" | sort | tr "\n" " ")"
  [ "$listen" = "127.0.0.1:20212 $gw:20211 " ] || { echo "  netalertx listens on: $listen"; exit 1; }
  ui() { curl -sk -o /dev/null -w "%{http_code} %{redirect_url}" --resolve "devices.$DOMAIN:443:127.0.0.1" "$@"; }
  jar="$(mktemp)"
  case "$(ui "https://devices.$DOMAIN/devices.php")" in 302*index.php*) ;; *) echo "  netalertx UI without login"; exit 1 ;; esac
  case "$(ui -c "$jar" --data-urlencode "loginpassword=$NETALERTX_PASSWORD" "https://devices.$DOMAIN/index.php")" in
    302*devices.php*) ;; *) echo "  netalertx login refused"; exit 1 ;; esac
  [ "$(ui -b "$jar" "https://devices.$DOMAIN/devices.php")" = "200 " ] || { echo "  netalertx session not kept"; exit 1; }
  rm -f "$jar"
  conf="$(docker exec -u 20211 netalertx grep -E "^(SCAN_SUBNETS|NTFY_RUN|NTFY_TOKEN)=" /data/config/app.conf)"
  grep -qx "SCAN_SUBNETS=\[.[0-9./]* --interface=$NET_IFACE.\]" <<<"$conf" || { echo "  netalertx scans more than $NET_IFACE"; exit 1; }
  source <(grep "^NTFY_PUBLISH_TOKEN=" stacks/ntfy/.env)
  grep -qx "NTFY_RUN=.on_notification." <<<"$conf" && grep -qxF "NTFY_TOKEN='"'"'$NTFY_PUBLISH_TOKEN'"'"'" <<<"$conf" ||
    { echo "  netalertx ntfy pushes not set up"; exit 1; }' \
  && echo "  netalertx (login through Caddy, off the LAN, one subnet, ntfy): ok"
