<!--
  Example content for the topology map (map.<DOMAIN>). Copy it to
  topology.md in the repo root (gitignored) to describe your own setup;
  `./lab render` publishes that one instead of this example.
  index.html fetches and parses this file client-side -- edit this file,
  reload the page, done. No build step, no container restart: Caddy's
  file_server reads straight off disk on every request.

  SCHEMA

  Node:
    ### <category>: <id>
    label: Display Name          (optional, defaults to <id>)
    sub: short subtitle           (optional)
    host: hostname or URL         (optional, shown as a badge)
    radius: 14                    (optional, defaults per category below)
    planned: true                 (optional, dashed outline for "not live yet")

    A paragraph of plain prose describing the node.

    > A blockquote becomes the panel's callout ("gotcha") note. **bold**
    > and `code` spans work. Optional -- most nodes don't need one.

  Categories (fixed set, defined in index.html): device, external, proxy,
  app, data, compute. Default radius by category: device 16, external 12,
  proxy 17, app 15, data 9, compute 14 -- override per-node with `radius:`
  for visual hubs.

  Edge (under "## Edges", one per line):
    - source-id -> target-id [type]

  Edge types (fixed set, defined in index.html): proxy, tunnel, pipeline,
  backup, widget, internal, mesh, planned.

  Both node ids in an edge must exist above it or the page will skip that
  edge silently (check the browser console if something's missing).
-->

## Nodes

### device: server
label: server
sub: Linux + Docker
radius: 24

The always-on machine running every stack in this repo.

### device: phone
label: Phone
sub: Tailscale + apps

Reaches every private hostname over Tailscale: Immich for photo backup, the dashboard in the browser.

### external: tailscale
label: Tailscale
sub: private network

Private network between your devices. `*.home.example.com` points at the server's Tailscale IP, so nothing is reachable from the internet.

### external: cloudflare
label: Cloudflare
sub: DNS + tunnel

Holds the DNS zone (DNS-01 certificates for Caddy) and runs the tunnel for the few public links.

> Public hostnames sit one level under the apex (`share.example.com`), so the free certificate covers them.

### proxy: caddy
label: Caddy
sub: reverse proxy
host: *.home.example.com

One wildcard certificate, one route per enabled stack.

### proxy: cloudflared
label: cloudflared
sub: tunnel

Forwards public hostnames to loopback ports, bypassing Caddy.

### app: immich
label: Immich
host: photos.home.example.com

Photo and video library.

### app: publicproxy
label: immich-public-proxy
host: share.example.com

Serves only Immich shared links to the public.

### app: homepage
label: Homepage
host: dash.home.example.com

Dashboard with a tile per service.

### data: photos
label: Photos folder

The photo library on disk, backed up nightly with restic.

## Edges

- phone -> tailscale [mesh]
- tailscale -> server [mesh]
- server -> caddy [internal]
- caddy -> immich [proxy]
- caddy -> homepage [proxy]
- cloudflare -> cloudflared [tunnel]
- cloudflared -> publicproxy [tunnel]
- publicproxy -> immich [internal]
- immich -> photos [internal]
- homepage -> immich [widget]
