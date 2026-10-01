# Tests

`tests/vm.sh` installs the whole thing in a throwaway **Ubuntu 24.04 VM**
and checks it from the outside. The host is never touched: everything runs
in the VM, installed through `./install.sh --host`, the same path as a real
remote install.

```bash
tests/vm.sh changed  # test what this branch changed (see below)
tests/vm.sh all      # the full suite: install, verify, rerun, verify, restore, rebuild
tests/vm.sh down     # delete the VM
```

Steps: `up` (VM, 4 CPU / 8 GiB / 40 GiB), `install`, `verify` (`lab doctor`
inside, HTTPS to every installed hostname from the host against Caddy's
internal CA, the overlay, each stack's own checks, one backup run), `rerun`,
`restore` (seed data, real backup, wipe the VM into a "new machine" with
fresh databases, new secrets and the photos in another folder, reinstall,
`lab restore`, then check an Immich login, a Paperless tag and the files
came back), `rebuild` (wipe everything but the backups and the restic
password, `install.sh --from-backup`), `ssh`, `down`.

## Testing only what changed

A change to one stack doesn't need the whole suite. `tests/vm.sh changed`
diffs against `origin/master` (or `tests/vm.sh changed <base>`), including
uncommitted files, and picks one of:

- **nothing**: only docs, READMEs or the example map changed;
- **some stacks**: only files under `stacks/<name>/` (or that stack's checks)
  changed. A fresh VM gets just those stacks, plus `caddy` and `homepage`,
  the stacks they `NEEDS`, the stacks that need them, and their `TEST_WITH`
  (stacks that work together without depending on each other, such as
  `paperless-ngx` and `actual-budget`). Then install and verify;
- **the full suite**: anything shared changed (`lib/`, `lab`, `install.sh`,
  `extras/backup`, the caddy stack, this folder).

`tests/vm.sh scope` prints the choice without running it, and
`tests/vm.sh stacks "immich gokapi"` tests a list you give it. The rerun,
restore and rebuild drills only run in the full suite.

Per-stack checks live in `tests/stacks/<stack>.sh`, sourced by `verify` when
that stack is installed (with `ssh_vm` and the other harness helpers
available; non-zero fails). Example: `calibre-web.sh` copies an EPUB into
the import folder and waits for it to land in the library. When a stack
starts working with another one, add it to `TEST_WITH` in its `stack.conf`.

The test config is `tests/vm.env`: `TLS_MODE=internal`, no Cloudflare, no
Tailscale, no GPU, local-disk backups, the `standard` stacks. The VM starts
without Docker, so the installer's own Docker install is exercised too.

Needs [Incus](https://linuxcontainers.org/incus/) with your user in
`incus-admin`, and KVM. If the VM has no internet while Docker runs on the
host, Docker's firewall rules are dropping the bridge's forwarded traffic:
`sudo iptables -I DOCKER-USER -i incusbr0 -j ACCEPT` and
`sudo iptables -I DOCKER-USER -o incusbr0 -j ACCEPT`.
