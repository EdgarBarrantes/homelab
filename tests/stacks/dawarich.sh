# Sourced by tests/vm.sh verify when dawarich is installed: the default demo
# login was replaced by the generated one, and a point posted the way a phone
# app does (OwnTracks format, through Caddy) comes back from the points API.
ssh_vm 'cd homelab && source <(grep -E "^DOMAIN=" homelab.env) && source <(grep "^DAWARICH_ADMIN_PASSWORD=" stacks/dawarich/.env)
  for _ in $(seq 1 60); do docker exec dawarich_app true 2>/dev/null && \
    [ "$(docker inspect -f "{{.State.Health.Status}}" dawarich_sidekiq)" = healthy ] && break; sleep 5; done
  key="$(docker exec -e EMAIL="admin@$DOMAIN" -e PW="$DAWARICH_ADMIN_PASSWORD" dawarich_app bin/rails runner "
    abort \"demo login still works\" if User.find_by(email: \"demo@dawarich.app\")&.valid_password?(\"safepassword\")
    u = User.find_by(email: ENV[\"EMAIL\"]) or abort \"no admin user\"
    abort \"admin password wrong\" unless u.valid_password?(ENV[\"PW\"])
    print u.api_key" 2>/dev/null | tail -n1)"
  [ -n "$key" ] || { echo "no API key"; exit 1; }
  h="timeline.$DOMAIN"; c="curl -sk --resolve $h:443:127.0.0.1"
  t=$(date +%s)
  code=$($c -o /dev/null -w "%{http_code}" -H "Content-Type: application/json" \
    -d "{\"_type\":\"location\",\"lat\":42.6977,\"lon\":23.3219,\"tst\":$t,\"tid\":\"vm\",\"acc\":5}" \
    "https://$h/api/v1/owntracks/points?api_key=$key")
  case "$code" in 2*) ;; *) echo "owntracks post: $code"; exit 1 ;; esac
  for _ in $(seq 1 30); do
    $c "https://$h/api/v1/points?api_key=$key&start_at=$(date -u -d @$((t-60)) +%FT%TZ)&end_at=$(date -u -d @$((t+60)) +%FT%TZ)" \
      | grep -q "42.6977" && exit 0
    sleep 2
  done
  echo "point not stored"; exit 1' && echo "  dawarich (login replaced, phone point stored): ok"
