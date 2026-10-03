# Sourced by tests/vm.sh verify when timetagger is installed: the generated
# password logs in, a wrong one doesn't, and the API stores and returns a
# record through the token it hands out.
ssh_vm 'cd homelab && source <(grep "^TIMETAGGER_PASSWORD=" stacks/timetagger/.env)
  docker exec -e PW="$TIMETAGGER_PASSWORD" timetagger python -c "
import base64, json, os, time, urllib.request as u
api = \"http://localhost/timetagger/api/v2/\"
def boot(pw):
    info = base64.b64encode(json.dumps({\"method\": \"usernamepassword\", \"username\": \"me\", \"password\": pw}).encode()).decode()
    try:
        return json.load(u.urlopen(u.Request(api + \"bootstrap_authentication\", data=info.encode(), method=\"POST\")))[\"token\"]
    except Exception:
        return None
assert boot(\"wrong\") is None
tok = boot(os.environ[\"PW\"])
call = lambda path, data=None, method=\"GET\": json.load(u.urlopen(u.Request(api + path, data=data, method=method, headers={\"authtoken\": tok})))
now = int(time.time())
call(\"records\", json.dumps([{\"key\": \"vmtest01\", \"t1\": now - 600, \"t2\": now, \"ds\": \"#test vm\", \"mt\": now, \"st\": 0}]).encode(), \"PUT\")
recs = call(\"records?timerange=%d-%d\" % (now - 3600, now + 60))[\"records\"]
assert any(r[\"key\"] == \"vmtest01\" for r in recs), recs
"' && echo "  timetagger (login, API): ok"
