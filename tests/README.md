# Tests

`tests/vm.sh` installs the whole thing in a throwaway **Ubuntu 24.04 VM**
and checks it from the outside. The host is never touched: everything runs
in the VM, installed through `./install.sh --host`, the same path as a real
remote install.

```bash
tests/vm.sh all      # create VM, install, verify, install again (idempotent), verify, restore
tests/vm.sh down     # delete the VM
```

Steps: `up` (VM, 4 CPU / 8 GiB / 40 GiB), `install`, `verify` (`lab doctor`
inside, HTTPS to every hostname from the host against Caddy's internal CA,
one backup run), `rerun`, `restore` (seed data, real backup, wipe the VM
into a "new machine" with fresh databases, new secrets and the photos in
another folder, reinstall, `lab restore`, then check an Immich login, a
Paperless tag and the files came back), `ssh`, `down`.

The test config is `tests/vm.env`: `TLS_MODE=internal`, no Cloudflare, no
Tailscale, no GPU, local-disk backups, the `standard` stacks. The VM starts
without Docker, so the installer's own Docker install is exercised too.

Needs [Incus](https://linuxcontainers.org/incus/) with your user in
`incus-admin`, and KVM. If the VM has no internet while Docker runs on the
host, Docker's firewall rules are dropping the bridge's forwarded traffic:
`sudo iptables -I DOCKER-USER -i incusbr0 -j ACCEPT` and
`sudo iptables -I DOCKER-USER -o incusbr0 -j ACCEPT`.
