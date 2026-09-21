# Custom Caddy build with the caddy-ratelimit and caddy-dns/cloudflare plugins.
#
# The stock caddy:2.11.4 image does not include third-party Caddy modules.
# Rate limiting (the `rate_limit` directive used in ./Caddyfile) requires
# https://github.com/mholt/caddy-ratelimit, which must be compiled in via
# xcaddy. Verified locally with `docker build` before committing:
#   xcaddy build --with github.com/mholt/caddy-ratelimit
# succeeds against Caddy 2.11.x (it fails against 2.7.x — caddy-ratelimit
# requires caddy/v2 >= 2.8.0).
#
# caddy-dns/cloudflare (https://github.com/caddy-dns/cloudflare) adds the
# `acme_dns cloudflare` directive used in ./Caddyfile - lets Caddy prove
# domain ownership via a DNS TXT record instead of an inbound port-80/443
# request, which is what makes real Let's Encrypt certs possible at all
# once this server is behind Cloudflare Tunnel with no port forwarding.
FROM caddy:2.11-builder AS builder
RUN xcaddy build \
    --with github.com/mholt/caddy-ratelimit \
    --with github.com/caddy-dns/cloudflare

FROM caddy:2.11.4
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
