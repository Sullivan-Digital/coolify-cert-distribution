# syntax=docker/dockerfile:1.6
FROM alpine:3.20

RUN apk add --no-cache \
        bash \
        curl \
        ca-certificates \
        aws-cli \
        jq \
        tzdata \
        coreutils \
        openssl \
        docker-cli

COPY lib/common.sh /usr/local/lib/cert-distribution/common.sh
COPY fetch.sh /usr/local/bin/fetch.sh
COPY healthcheck.sh /usr/local/bin/healthcheck.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/fetch.sh /usr/local/bin/healthcheck.sh /usr/local/bin/entrypoint.sh

# Entrypoint runs fetch.sh once at startup (so a fresh deploy isn't stuck
# waiting up to 12h for the first Coolify scheduled-task tick) and then
# sleeps forever so Coolify's Scheduled Tasks can `docker exec` into it.
# If the bootstrap fetch fails, the container exits and Coolify's restart
# policy kicks in.
CMD ["/usr/local/bin/entrypoint.sh"]
