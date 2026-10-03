# Sourced by tests/vm.sh verify when glances is installed. Its API is on
# every interface (host networking), so it must refuse requests without the
# generated password and answer with it (/api/4/status is open by design:
# a liveness check with no data).
ssh_vm 'source <(grep "^GLANCES_PASSWORD=" homelab/stacks/glances/.env)
  [ "$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:61208/api/4/cpu)" = 401 ] &&
  [ "$(curl -s -o /dev/null -w "%{http_code}" -u "glances:$GLANCES_PASSWORD" http://127.0.0.1:61208/api/4/cpu)" = 200 ] &&
  grep -q "HOMEPAGE_VAR_GLANCES_PASSWORD=$GLANCES_PASSWORD" homelab/stacks/homepage/.env &&
  source <(grep "^DOMAIN=" homelab/homelab.env) &&
  [ "$(curl -sk -o /dev/null -w "%{http_code}" --resolve "glances.$DOMAIN:443:127.0.0.1" "https://glances.$DOMAIN/api/4/cpu")" = 200 ]' \
  && echo "  glances password: ok"
