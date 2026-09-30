# Public links

Everything is private (tailnet-only) by default. Two stacks have a part
that's meant for people *outside* the tailnet, and only that part is made
public, through a Cloudflare Tunnel:

| Public hostname | Stack | What's reachable | What isn't |
|---|---|---|---|
| `share.example.com` | `immich-public-proxy` | Immich shared links (albums/photos you shared) | Immich login, upload, library, API |
| `send.example.com` | `gokapi` | Download links you created | Upload and admin (those stay on `files.home.example.com`) |

## Why it's built this way

- **Cloudflare Tunnel, not port forwarding.** `cloudflared` on the server
  dials out to Cloudflare; nothing listens on your public IP and the router
  needs no changes. Cloudflare terminates TLS at its edge.
- **Straight to one loopback port, not through Caddy.** Each public
  hostname maps to exactly one `127.0.0.1:<port>` in
  `/etc/cloudflared/config.yml`. Caddy (and every private route) is never
  reachable from the tunnel.
- **Validate before forwarding.** `immich-public-proxy` checks every request
  against Immich's own shared-link data and only then fetches the content,
  so a bug or a guessed URL can't reach anything else in Immich.
- **Flat hostnames, one level under the apex.** `share.example.com`, not
  `share.home.example.com`: Cloudflare's free Universal SSL certificate
  only covers the apex and one wildcard level. The depth doubles as a
  signal: `*.home.example.com` (two levels) is always private,
  `*.example.com` (one level) is only for things exposed on purpose.

## Setup

Needs `TLS_MODE=cloudflare` (your zone on Cloudflare), and `PUBLIC_DOMAIN`
set to the apex (the wizard asks when you pick either stack).

1. **Install cloudflared** on the server
   ([Cloudflare's packages](https://pkg.cloudflare.com/)):
   ```bash
   sudo mkdir -p --mode=0755 /usr/share/keyrings
   curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
   echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" \
     | sudo tee /etc/apt/sources.list.d/cloudflared.list
   sudo apt-get update && sudo apt-get install -y cloudflared
   ```
2. **Create the tunnel** (once, as your user; opens a browser link to pick
   the zone):
   ```bash
   cloudflared tunnel login
   cloudflared tunnel create homelab     # prints the tunnel id
   ```
3. Put the id in `homelab.env` (`CLOUDFLARED_TUNNEL=<id>`), then:
   ```bash
   ./install.sh --public
   ```
   This renders the ingress rules for the enabled public stacks, installs
   them to `/etc/cloudflared/config.yml` with the tunnel credentials,
   creates the DNS records (`cloudflared tunnel route dns`), installs the
   systemd service if needed and restarts it.
4. **Point the apps at their public names**:
   - Immich: Administration > Settings > Server > External domain =
     `https://share.example.com`, so "copy link" produces public URLs.
   - Gokapi: in its setup, "Public Facing URL" = `https://send.example.com/`.
     Gokapi stamps this onto every link, whichever hostname you logged in on.

Check: `./lab doctor` shows cloudflared, and from a phone *off* Tailscale a
shared link opens while `https://photos.home.example.com` does not.

## Gotchas

- **cloudflared reads only `/etc/cloudflared/config.yml`.**
  `cloudflared service install` copies a config there once; editing
  `~/.cloudflared/config.yml` afterwards does nothing. Always change it via
  `./install.sh --public` (or edit `/etc/cloudflared/config.yml` and
  `sudo systemctl restart cloudflared`).
- **New DNS names can look broken for ~30 minutes**: a resolver that asked
  before the record existed caches the "no such name" answer for the zone's
  SOA minimum TTL. `dig @1.1.1.1 share.example.com` tells you if it's
  really live.
- **Old zone rules can swallow new hostnames.** A legacy Page Rule like
  `*example.com/*` (redirect) also matches `share.example.com`. Scope
  redirects to exact hostnames.

## Adding another public service

Give the stack `PUBLIC=<name>` and `PUBLIC_PORT=<loopback port>` in its
`stack.conf`, publish that port on `127.0.0.1` only in its `compose.yml`,
and run `./install.sh --public`. Only do this for something that is safe
to show to the whole internet (its own authentication, or a
validate-then-forward proxy like `immich-public-proxy`).

For a service that needs just one path public (for example an OAuth
callback), put a small plain-HTTP Caddy site on a loopback port with a
`handle` for exactly that path and `abort` for everything else, and point
the tunnel at it.
