# Sourced by tests/vm.sh verify when kismet is installed. The VM has no
# Wi-Fi, so Kismet runs without a capture source: through Caddy it must
# refuse requests without the generated password and answer with it,
# nothing may listen on the host (it has its own network namespace), and
# kismet-radio must refuse the interface the VM is online through (not on
# USB), leaving it with the host.
ssh_vm 'cd homelab && source <(grep "^KISMET_PASSWORD=" stacks/kismet/.env) && source <(grep "^DOMAIN=" homelab.env)
  dev="$(ip route get 1.1.1.1 | awk "{ for (i = 1; i < NF; i++) if (\$i == \"dev\") print \$(i + 1) }")"
  api() { curl -sk -o /dev/null -w "%{http_code}" --resolve "kismet.$DOMAIN:443:127.0.0.1" "$@" "https://kismet.$DOMAIN/system/status.json"; }
  for _ in $(seq 1 30); do [ "$(api)" = 401 ] && break; sleep 2; done
  [ "$(api)" = 401 ] && [ "$(api -u "kismet:$KISMET_PASSWORD")" = 200 ] &&
  ! curl -s -m 5 -o /dev/null http://127.0.0.1:2501/ || { echo "  kismet login or listen address wrong"; exit 1; }
  source lib/common.sh
  env_set stacks/kismet/.env KISMET_SOURCE "$dev"
  ./lab up kismet >/dev/null 2>&1
  refused=no
  for _ in $(seq 1 15); do docker logs kismet-radio 2>&1 | grep -q "refusing $dev: not a USB adapter" && { refused=yes; break; }; sleep 2; done
  inside="$(docker exec kismet ls /sys/class/net)"
  env_set stacks/kismet/.env KISMET_SOURCE ""
  ./lab up kismet >/dev/null 2>&1
  [ $refused = yes ] || { echo "  kismet-radio did not refuse $dev"; exit 1; }
  ! grep -qx "$dev" <<<"$inside" && [ -e "/sys/class/net/$dev" ] || { echo "  $dev was handed to Kismet"; exit 1; }' \
  && echo "  kismet (password through Caddy, own namespace, built-in card refused): ok"
