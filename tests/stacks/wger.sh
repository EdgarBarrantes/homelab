# Sourced by tests/vm.sh verify when wger is installed: the default
# admin/adminadmin no longer works and the generated password does (the
# app's JWT login, through Caddy), a weight entry posted with it comes back,
# static files are served, and PowerSync answers behind /ps/.
ssh_vm 'cd homelab && source <(grep -E "^DOMAIN=" homelab.env) && source <(grep "^WGER_ADMIN_PASSWORD=" stacks/wger/.env)
  for _ in $(seq 1 90); do [ "$(docker inspect -f "{{.State.Health.Status}}" wger_worker 2>/dev/null)" = healthy ] && break; sleep 10; done
  h="gym.$DOMAIN"; c="curl -sk --resolve $h:443:127.0.0.1"; api="https://$h/api/v2"
  login() { $c -H "Content-Type: application/json" -d "{\"username\":\"admin\",\"password\":\"$1\"}" "https://$h/allauth/app/v1/auth/login"; }
  login adminadmin | grep -q access_token && { echo "default password still works"; exit 1; }
  tok=$(login "$WGER_ADMIN_PASSWORD" | python3 -c "import sys,json; print(json.load(sys.stdin)[\"meta\"][\"access_token\"])") \
    || { echo "login failed"; exit 1; }
  a="Authorization: Bearer $tok"
  $c -H "$a" -H "Content-Type: application/json" -d "{\"date\":\"$(date -u +%FT%TZ)\",\"weight\":\"71.3\"}" "$api/weightentry/" | grep -q "71.3" \
    || { echo "weight entry not saved"; exit 1; }
  $c -H "$a" "$api/weightentry/" | grep -q "71.3" || { echo "weight entry not listed"; exit 1; }
  css=$($c -L "https://$h/" | grep -o "/static/[^\"]*\.css" | head -n1)
  [ -n "$css" ] && [ "$($c -o /dev/null -w "%{http_code}" "https://$h$css")" = 200 ] || { echo "static files not served"; exit 1; }
  code=$($c -o /dev/null -w "%{http_code}" "https://$h/ps/probes/liveness")
  case "$code" in 2*) ;; *) echo "powersync: $code"; exit 1 ;; esac' && echo "  wger (login replaced, weight entry, static files, PowerSync): ok"
