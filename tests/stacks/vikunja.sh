# Sourced by tests/vm.sh verify when vikunja is installed: the generated
# login works through Caddy, a task created with its token comes back, and
# registration is closed.
ssh_vm 'cd homelab && source <(grep -E "^DOMAIN=" homelab.env) && source <(grep "^VIKUNJA_ADMIN_PASSWORD=" stacks/vikunja/.env)
  h="tasks.$DOMAIN"; c="curl -sk --resolve $h:443:127.0.0.1"; api="https://$h/api/v1"
  for _ in $(seq 1 60); do $c -f "$api/info" >/dev/null 2>&1 && break; sleep 5; done
  tok=$($c -H "Content-Type: application/json" -d "{\"username\":\"admin\",\"password\":\"$VIKUNJA_ADMIN_PASSWORD\"}" "$api/login" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)[\"token\"])") || { echo "login failed"; exit 1; }
  a="Authorization: Bearer $tok"
  pid=$($c -H "$a" "$api/projects" | python3 -c "import sys,json; print(json.load(sys.stdin)[0][\"id\"])") || { echo "no project"; exit 1; }
  $c -X PUT -H "$a" -H "Content-Type: application/json" -d "{\"title\":\"vm-check\"}" "$api/projects/$pid/tasks" | grep -q vm-check \
    || { echo "task not created"; exit 1; }
  $c -H "$a" "$api/tasks?s=vm-check" | grep -q vm-check || { echo "task not found"; exit 1; }
  code=$($c -o /dev/null -w "%{http_code}" -H "Content-Type: application/json" \
    -d "{\"username\":\"x\",\"email\":\"x@example.com\",\"password\":\"12345678abc\"}" "$api/register")
  case "$code" in 2*) echo "registration is open"; exit 1 ;; esac' && echo "  vikunja (login, task through Caddy, registration closed): ok"
