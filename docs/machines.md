# Machines: what goes where

Several devices take part in this setup. Only the **server** runs this
repo; the rest need an app or a setting. Everything below is what my own
setup uses; swap parts as you like.

| Machine | Role | Needs |
|---|---|---|
| [Server](#server) | Runs every stack | Debian/Ubuntu, Docker Engine, Tailscale, (NVIDIA driver) |
| [Your laptop/desktop](#laptops-and-desktops) | Uses the web UIs; can install the server remotely | Tailscale, a browser, (git, ssh) |
| [Phone](#phone) | Photo backup, dashboard, dictation | Tailscale, Immich app, (Syncthing, a scanner app, HA app) |
| [Home Assistant box](#home-assistant-box-optional) | Home automation, voice | HAOS, trusted proxy setting |
| [Backup target](#backup-target-optional) | Holds nightly backups | A disk, or an SMB share (NAS, router with USB disk) |
| [Cloudflare](#cloudflare-account) | DNS, certificates, public links | Your domain's zone, an API token, a tunnel |

## Server

Any always-on x86_64 machine. Mine is a laptop with 96 GB RAM and a small
NVIDIA GPU; a mini PC with 16 GB runs the `standard` profile fine.

**Rough sizing** (the installer checks this for the stacks you pick):

| Profile | Stacks | RAM | Disk (images) |
|---|---|---|---|
| minimal | caddy, homepage, glances | 1 GB | 3 GB |
| standard | + immich, paperless, actual, gokapi, calibre-web, backrest | 8 GB | 30 GB |
| full | + ollama, speech, immich-public-proxy | 16 GB+ | 60 GB |

Plus room for your own data (photos, documents, models).

**Install before running `./install.sh`:**

1. **Debian 12+ or Ubuntu 22.04+** (Pop!_OS and Mint count), with systemd
   and a user that can `sudo`.
2. **git** to clone: `sudo apt install git`. (Or use `--host` from another
   machine, then the server needs nothing but SSH.)
3. **Tailscale** (for `TLS_MODE=cloudflare`):
   ```bash
   curl -fsSL https://tailscale.com/install.sh | sh
   sudo tailscale up
   tailscale ip -4        # this is what *.home.example.com points at
   ```
   Turn off key expiry for the server in the Tailscale admin console.
4. **Docker Engine**: the installer installs it from Docker's apt
   repository if missing. Not Docker Desktop: its VM hides the host
   network and GPU. If Desktop is installed, `docker context use default`.
5. **NVIDIA GPU** (optional), [below](#nvidia-gpu).
6. **A static LAN address** (DHCP reservation on the router) if Home
   Assistant or other LAN devices should reach it.

Everything else (packages like curl, restic, cifs-utils) is installed by the
installer when needed.

### NVIDIA GPU

Used by Immich (face and object recognition), Ollama (LLMs) and Glances
(stats). Set `GPU=yes` (the wizard asks when it finds one). Three layers,
each checked by `./install.sh --check`:

1. **Driver**: Ubuntu: `sudo ubuntu-drivers install`, reboot, check
   `nvidia-smi`. Pop!_OS ships it with the NVIDIA ISO.
2. **NVIDIA Container Toolkit**, from NVIDIA's apt repository
   ([official guide](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)):
   ```bash
   curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
     | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
   curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
     | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
     | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
   sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit
   sudo nvidia-ctk runtime configure --runtime=docker
   sudo systemctl restart docker
   ```
3. **CDI spec**: the stacks request the GPU through CDI
   (`driver: cdi`, `nvidia.com/gpu=all`), not `driver: nvidia`, because a
   host `systemctl daemon-reload` silently removes the GPU from
   `driver: nvidia` containers. Toolkit 1.18+ keeps
   `/var/run/cdi/nvidia.yaml` current by itself; check with
   `docker info | grep nvidia.com/gpu`. If it's missing:
   `sudo nvidia-ctk cdi generate --output=/var/run/cdi/nvidia.yaml`.

A 4 GB GPU is enough for Immich ML plus a 3B model; 7B models run partly on
the CPU. Ollama unloads models after 5 idle minutes, so the GPU sits idle
between uses.

## Laptops and desktops

- **Tailscale**, logged in to the same tailnet: that's what makes
  `*.home.example.com` reachable.
- **A browser.** With `TLS_MODE=internal`, import Caddy's root certificate
  (`rendered/caddy-local-ca.crt` on the server, after `lab doctor`) and add
  the hostnames to DNS or `/etc/hosts`.
- **For managing the server**: `ssh`, and optionally a clone of this repo
  to run remote installs (below).
- **Syncthing** (optional), if you sync a scanner inbox or other folders to
  the server. The dashboard's tiles only link to web UIs on the server.

### Remote install

From a machine with this repo and SSH access to the server:

```bash
./install.sh --host you@server                    # interactive, in your terminal
./install.sh --host you@server --check            # just check it
./install.sh --host you@server --config server.env --yes --dir /opt/homelab
```

It copies the repo's tracked files (never your local `.env` files or data)
to `~/homelab` on the server (or `--dir`), then runs `./install.sh` there
with the same options. Re-running updates the code and keeps the server's
config and data. Needs key-based SSH ideally (`ssh-copy-id you@server`);
a password works too and is asked once. Extra ssh options:
`HOMELAB_SSH_OPTS="-p 2222 -i ~/.ssh/other" ./install.sh --host ...`.
The server's user needs `sudo`.

## Phone

- **Tailscale** app, logged in.
- **Immich** app: server URL `https://photos.home.example.com`, enable
  backup.
- The dashboard, Paperless, Actual and the rest work in the browser (add
  them to the home screen).
- Optional document pipeline: a scanner app (I use MakeACopy) saving PDFs
  into a folder that **Syncthing** syncs to `PAPERLESS_CONSUME_DIR` on the
  server. Paperless imports anything that lands there. The same works for
  ebooks: sync a folder to `BOOKS_IMPORT_DIR` and Calibre-Web Automated adds
  each book to the library (and removes it from that folder).
- Optional: the **Home Assistant** companion app, with the internal URL
  set to HA's LAN address so home control works even if the server is off.

## Home Assistant box (optional)

Home Assistant runs on its own machine (a Raspberry Pi with HAOS here), not
in this repo. What connects them:

- Set `HA_URL` (e.g. `http://192.168.1.50:8123`): adds
  `https://ha.home.example.com` and a dashboard tile.
- In HA, allow the server as a reverse proxy: recent versions have it
  under Settings > System > Network (trusted proxies = the server's LAN
  IP). Without it HA answers **400**. An `http:` block in
  `configuration.yaml` is ignored by recent versions.
- Voice and AI: with the `ollama` and `speech` stacks and `LAN_BIND` set to
  the server's LAN IP, add HA's **Ollama** integration
  (`http://<server>:11434`) and **Wyoming** (`<server>:10300`). See
  [extras/homeassistant](../extras/homeassistant/README.md).

## Backup target (optional)

`BACKUP_TARGET=local`: any disk mounted on the server (use a *different*
disk from your data). `BACKUP_TARGET=smb`: a Samba share on a NAS, or a
router with a USB disk. Use its **LAN address**, not a Tailscale name: SMB
through a userspace WireGuard hop stalled under sustained writes in my
setup. The share can hold other files; backups only touch `db-dumps/` and
`restic-repo/` in it. Details in [extras/backup](../extras/backup/README.md).

Keep a copy of `/etc/homelab/restic-password` in your password manager.
Without it the backups can't be restored.

## Cloudflare account

Only for `TLS_MODE=cloudflare` and public links. Your domain's DNS must be
on Cloudflare (free plan).

1. **API token** for certificates: My Profile > API Tokens > Create >
   "Edit zone DNS", limited to your zone. The installer asks for it (or
   `lab config caddy CF_API_TOKEN`).
2. **DNS record**: `*.home` (i.e. `*.home.example.com`), type A, the
   server's Tailscale IP, **DNS only** (grey cloud). New names can look
   broken for up to 30 minutes if your resolver cached the "doesn't exist"
   answer; `dig @1.1.1.1 dash.home.example.com` bypasses that.
3. **Tunnel** for public links, see
   [public-exposure.md](public-exposure.md).
