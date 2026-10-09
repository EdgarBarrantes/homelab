# homelab (public repo)

Generic, templated version of a personal self-hosting setup, installed with
`./install.sh` and managed with `./lab`. Machine-specific values live only
in `homelab.env` and `stacks/*/.env` (both gitignored). This repo is
public: never commit real domains, IPs, names, paths or secrets.

## Layout and rules

- `stacks/<name>/`: `compose.yml` (or Immich's untouched upstream
  `docker-compose.yml` + `docker-compose.override.yml`), `stack.conf`
  (metadata read by lib/), `caddy.conf`, `homepage.yaml`, `setup.txt`,
  optional overlays (`gpu.yml`, `ai.yml`) switched by a homelab.env value.
- `lib/`: bash only (common, checks, wizard, render, doctor, remote).
  `render_all` must stay idempotent and never overwrite existing secrets.
- Compose files use `${VAR}` from `homelab.env`; Caddy snippets use Caddy's
  `{$DOMAIN}`; homepage/setup/unit templates use `${VAR}` and are filled by
  `render_template`.
- Conventions: `restart: unless-stopped`; `lab.tier: heavy` on GPU/CPU
  heavy services; pinned image versions; `container_name` for anything
  Caddy proxies; web UIs on the external `proxy` network; no ports on
  0.0.0.0 except Caddy's 443 (host ports on 127.0.0.1, LAN ports on
  `${LAN_BIND}`); GPU only via CDI in a `gpu.yml` overlay.
- Functions under `set -Eeuo pipefail`: end with `return 0` when the last
  statement is a `[[ ... ]] && ...` test.
- Docs: no em dashes; vim, not nano, in instructions.

## Safety

- Never read or print `.env` files or `homelab.env`; don't run
  `docker compose config` unfiltered (it expands secrets): use `--quiet`.
- Never `docker compose down -v`, `docker volume rm`, or delete `data/`.

## Testing

Only in a VM (Incus, Ubuntu 24.04, internal TLS, no Cloudflare); never run
the installer on a real server to test it. Test in proportion:
`tests/vm.sh changed` classifies the diff (rules in `tests/scope.sh`,
table in tests/README.md) and runs what it needs: nothing for docs,
`tests/check.sh` (host, seconds) for tiles, env docs and same-major image
bumps, a scoped VM run for a stack's runtime, `suite` (no drills) for
shared code, `all` (with the restore and rebuild drills) for backup and
restore code. When adding a kind of file or a rule, add a case to the
self-test in `tests/check.sh`. Images and builds are cached between runs
(`tests/vm.sh cache`, `HOMELAB_TEST_CACHE=off` for a run as on a new
machine).
