# Caddy with the Cloudflare DNS module, for DNS-01 certificates (the
# services are only reachable over Tailscale, so HTTP-01 can't work). With
# TLS_MODE=internal the module is simply unused.
FROM caddy:2-builder AS builder
RUN xcaddy build --with github.com/caddy-dns/cloudflare

FROM caddy:2
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
