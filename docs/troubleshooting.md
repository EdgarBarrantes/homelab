# Troubleshooting

Start with `./lab doctor`: it checks containers, every HTTPS route, the GPU
and the backup timer, and prints a hint for each problem. Below are issues
that actually happened on my setup, with their causes.

## HTTPS and routing

**A route answers 502/503.** Caddy is fine, the app isn't answering yet (or
crashed): `./lab logs <stack>`. First starts are slow: Immich ML and
Paperless set up for a minute or two; Calibre-Web installs Calibre; Speech
downloads ~2 GB of models.

**Everything is "no answer / TLS error".** `./lab logs caddy`. With
`TLS_MODE=cloudflare`, look for DNS-01 errors: a wrong or too narrow
`CF_API_TOKEN` (needs Zone > DNS > Edit on your zone). With `internal`,
your client doesn't trust Caddy's CA yet: import
`rendered/caddy-local-ca.crt`.

**Name doesn't resolve.** `dig @1.1.1.1 dash.home.example.com`. If that
works but your machine says NXDOMAIN, a resolver cached the "doesn't exist"
answer from before the record existed; it expires within ~30 minutes. On
the client, `*.home.example.com` must point at the server's Tailscale IP
and Tailscale must be connected.

**Changed a route but Caddy serves the old one.** `./lab reload caddy`.
(Caddy's config is mounted as a directory for exactly this reason: single
bind-mounted files keep the old inode after editors save them atomically,
so a running container never sees the change.)

**Homepage shows a blank page.** Its `HOMEPAGE_ALLOWED_HOSTS` must match
the hostname you use (`dash.$DOMAIN`, set automatically). A tile says
"t.metric is undefined": a Glances widget got the wrong schema (one
`metric:` per tile).

**Home Assistant through `ha.` returns 400.** HA doesn't trust the server as
a proxy. Recent HA keeps this in the UI (Settings > System > Network), and
silently ignores an `http:` block in `configuration.yaml`.

## GPU

**Ollama is suddenly slow; `docker exec ollama nvidia-smi` says "Failed to
initialize NVML: Unknown Error".** A `sudo systemctl daemon-reload` on the
host removed the GPU from containers that got it via `driver: nvidia`.
These stacks use CDI (`driver: cdi`, `nvidia.com/gpu=all`), which survives
reloads; if you see it anyway: `docker restart ollama
immich_machine_learning glances`, and check `docker info | grep nvidia.com/gpu`.

**GPU memory in use but 0% utilisation / ~2 W.** A model is loaded and idle.
Ollama unloads after 5 minutes; nothing is wrong.

## Open WebUI

**A small model loops listing tools, or ignores the question.** Open WebUI
enables its builtin tools (tasks, notes, automations, calendar) for every
model without its own settings entry; their definitions push a prompt past
qwen2.5:3b's 4096-token context, so Ollama truncates it (`truncating input
prompt` in `./lab logs ollama`). Admin Panel > Settings > Models > the model
> turn off Builtin Tools.

## Backups

**Nothing in the backup log / the journal is empty.** The log is
`/var/log/homelab-backup.log` (`./lab backup log`); a busy journal can
rotate a night's run away within hours.

**SMB backup stalls or fails with "Host is down" / "sends on sock stuck"
in `dmesg`.** Mount the share by its LAN address, not a Tailscale name:
SMB through a userspace WireGuard hop (e.g. a travel router's Tailscale)
stalled under sustained writes and fell back to a relay.

**It's slow.** The first restic run reads everything; a USB hard disk behind
a router tops out around 20 MB/s. Later runs only send changes. Don't tune
`--pack-size` or connections for a single HDD: parallel writes make it
worse.

**Backrest shows no snapshots / "__unassociated__".** Backrest only
re-indexes after its own operations: `backup.sh` asks it to at the end of
each run. Snapshots carry the tags `plan:<name>-nightly` and
`created-by:<name>`; create a plan with that id (schedule Disabled) and set
Backrest's instance id to `HOMELAB_NAME` so they show on its dashboard.
Never press "Backup now" on that plan: Backrest doesn't have the sources
mounted.

**Backrest browses an empty repo after the share was remounted.** It can
hold a stale mount: `./lab restart backrest`.

## Install

**"not in the docker group" right after installing Docker.** The installer
continues under `sg docker` for that run. New shells need a fresh login
(`newgrp docker`, or log out and in).

**A stack says a variable is not set.** `./lab render` regenerates every
`.env`; `./lab secret <stack> <KEY>` shows what's there.
