# Tests

`tests/vm.sh` installs the whole thing in a throwaway **Ubuntu 24.04 VM**
and checks it from the outside. The host is never touched: everything runs
in the VM, installed through `./install.sh --host`, the same path as a real
remote install.

```bash
tests/vm.sh changed  # run what this branch's changes need (see below)
tests/vm.sh check    # host-only checks, seconds, no VM
tests/vm.sh all      # the full suite: install, verify, rerun, verify, restore, rebuild
tests/vm.sh suite    # the same without the restore and rebuild drills
tests/vm.sh down     # delete the VM
```

Steps: `up` (VM, 4 CPU / 12 GiB / 40 GiB), `preload` (cached images, see
below), `install`, `verify` (`lab doctor` inside, HTTPS to every installed
hostname from the host against Caddy's internal CA, the overlay, each
stack's own checks, one backup run), `rerun`, `restore` (seed data, real
backup, wipe the VM into a "new machine" with fresh databases, new secrets
and the photos in another folder, reinstall, `lab restore`, then check an
Immich login, a Paperless tag and the files came back), `rebuild` (wipe
everything but the backups and the restic password, `install.sh
--from-backup`), `ssh`, `down`. Every run ends with the time each phase
took; a passed run deletes its VM (`KEEP_VM=1` keeps it), a failed one is
left for `tests/vm.sh ssh`.

## How much to test

Test in proportion to what can break: a VM only for things that run
together (a stack's services, its route, how stacks work with each other)
or shared code. `tests/vm.sh changed` diffs against `origin/master` (or
`tests/vm.sh changed <base>`), including uncommitted files, classifies
every changed file and runs the highest level any of them needs:

| Level | Runs | For |
|---|---|---|
| `none` | nothing | docs, READMEs, setup texts, the example map |
| `check` | `tests/check.sh` on the host, seconds | a dashboard tile, a description, env-key docs, an image bump within the same major version, the Home Assistant and remote-pause extras |
| `stacks` | check + a scoped VM run: install, verify | a stack's runtime: compose services, Dockerfile, scripts, its route, a major image bump, a new stack, its VM checks |
| `install` | check + `suite`: every stack, install, verify, re-install, verify | shared code: `lab`, `lib/`, `install.sh`, the caddy stack, the test harness |
| `full` | check + `all`: the suite plus the restore and rebuild drills | backup and restore code, the drills, a stack's `PG_*`/`BACKUP_PATHS`, and shared code whose diff mentions backups or restores |

A scoped run installs the changed stacks plus `caddy` and `homepage`, the
stacks they `NEEDS`, the stacks that need them, and their `TEST_WITH`
(stacks that work together without depending on each other, such as
`paperless-ngx` and `actual-budget`). Unknown paths count as `install`:
when in doubt, test more. The rules are in `tests/scope.sh`;
`tests/check.sh` checks them against a table of known cases, so a rule
change that misclassifies something fails the check.

`tests/vm.sh scope` prints the choice without running it, and
`tests/vm.sh stacks "immich gokapi"` tests a list you give it.

`tests/check.sh` (also the first step of every VM run): shell syntax,
every stack's compose files (with the example env), YAML, every
`.env.example` key documented, and the scope rules.

## Image and build cache

Downloads were most of a run's time, so images from earlier runs are
kept in `~/.cache/homelab-test/images` (`HOMELAB_TEST_CACHE` moves it) and
loaded into the fresh VM before the install: Docker is installed first,
with the installer's own `fix_docker`, then the tested stacks' images, four
at a time. Stacks with their own `Dockerfile` keep their BuildKit cache in
`~/.cache/homelab-test/build/<stack>`, imported before the install, so
`lab up --build` finds every step done; a changed Dockerfile only redoes
the steps it changed. A passed install saves what is new.

Invalidation:
- automatic: an image saved under an exact version (x.y.z, or a digest) is
  dropped 60 days after it was saved; any other tag (`v3`, `2`,
  `17-alpine`, `latest`: tags that move) and the build caches after 7 days,
  so new upstream builds come in weekly;
- `tests/vm.sh cache` lists the entries with age and size;
  `tests/vm.sh cache clear [all|images|build|<name>]` deletes them;
- `HOMELAB_TEST_CACHE=off tests/vm.sh ...` runs without the cache: the
  installer installs Docker and pulls everything, as on a new machine. Do
  that after changing the installer's Docker step, and now and then.

Per-stack checks live in `tests/stacks/<stack>.sh`, sourced by `verify` when
that stack is installed (with `ssh_vm` and the other harness helpers
available; non-zero fails). Example: `calibre-web.sh` copies an EPUB into
the import folder and waits for it to land in the library. When a stack
starts working with another one, add it to `TEST_WITH` in its `stack.conf`.

The test config is `tests/vm.env`: `TLS_MODE=internal`, no Cloudflare, no
Tailscale, no GPU, local-disk backups, the `standard` stacks. With the
cache off, the VM starts without Docker, so the installer's own Docker
install is exercised too.

Needs [Incus](https://linuxcontainers.org/incus/) with your user in
`incus-admin`, and KVM. If the VM has no internet while Docker runs on the
host, Docker's firewall rules are dropping the bridge's forwarded traffic:
`sudo iptables -I DOCKER-USER -i incusbr0 -j ACCEPT` and
`sudo iptables -I DOCKER-USER -o incusbr0 -j ACCEPT`.
