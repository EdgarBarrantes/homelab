# Private overlay

This repo is public and generic. Everything specific to *your* machine that
isn't a secret, and doesn't belong upstream, goes in a **private overlay**:
a folder you point at with `LOCAL_DIR` in `homelab.env`. Keep it in its own
private git repo (mine also holds my personal notes and my real
`homelab.env`, symlinked into the checkout).

```
$LOCAL_DIR/
  topology.md               your real map (instead of the example)
  homepage/<Group>.yaml     extra dashboard tiles, appended to that group
                            (Infrastructure, Photos, Documents, AI, Files,
                            Backups, Home, Finance; any other name becomes
                            a new group at the end)
  caddy/sites/*.conf        extra routes inside the *.$DOMAIN site
  caddy/*.caddy             extra top-level Caddy sites
  stacks/<stack>/*.yml      extra compose files for that stack
  stacks/<stack>/.env.example  keys those files add to the stack's .env
                            (documented for `lab keys`, same format)
  cloudflared.yml           extra tunnel ingress entries
```

Every file is optional. `${VAR}` from `homelab.env` works in all of them
(Caddy files also have Caddy's own `{$DOMAIN}`). `LOCAL_DIR` must be an
absolute path: the nightly backup runs as root, where `~` means `/root`.
After a change: `./lab up` (or `./lab reload caddy` for Caddy-only edits).

The overlay is included in the nightly backup, together with `homelab.env`
and every `.env`, so `./install.sh --from-backup` brings it back.

## Examples

A dashboard tile (`homepage/Finance.yaml`), same format as a stack's
`homepage.yaml`:

```yaml
- Ethereum:
    icon: sh-coinmarketcap
    href: https://coinmarketcap.com/currencies/ethereum/
    widget:
      type: coinmarketcap
      symbols: [ETH]
      key: "{{HOMEPAGE_VAR_CMC_API_KEY}}"   # put the key in stacks/homepage/.env
```

A static site that a tunnel serves publicly, with one path forwarded to an
app. `caddy/public-pages.caddy`:

```caddyfile
:8090 {
	@callback path /oauth/callback
	handle @callback {
		reverse_proxy actual:5006
	}
	handle {
		root * /srv/public-pages
		file_server
	}
}
```

`stacks/caddy/public-pages.yml` publishes the port on loopback and mounts
the pages (compose paths: use `${LOCAL_DIR}`, relative ones resolve
against the stack folder):

```yaml
services:
  caddy:
    ports:
      - "127.0.0.1:8090:8090"
    volumes:
      - ${LOCAL_DIR}/public-pages:/srv/public-pages:ro
```

and `cloudflared.yml` adds the hostname to the tunnel:

```yaml
  - hostname: pages.${PUBLIC_DOMAIN}
    service: http://127.0.0.1:8090
```
