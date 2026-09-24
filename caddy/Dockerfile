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
#
# caddy-crowdsec-bouncer (https://github.com/hslatman/caddy-crowdsec-bouncer)
# adds the `crowdsec` global option and handler directive - enforces
# crowdsec-stack's ban decisions right here in Caddy, in memory, instead
# of via a Cloudflare Worker + KV (whose free-tier quota of 1000 writes/
# day ran out within seconds of a normal decision sync, and whose Daemon
# Mode redeploy-on-restart then crash-looped). Compiled in unconditionally
# but inert unless crowdsec.d/*.caddy exists - see the Caddyfile's global
# block. /http is the HTTP-handler-only package.
FROM caddy:2.11-builder AS builder
RUN xcaddy build \
    --with github.com/mholt/caddy-ratelimit \
    --with github.com/caddy-dns/cloudflare \
    --with github.com/hslatman/caddy-crowdsec-bouncer/http

FROM caddy:2.11.4
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
