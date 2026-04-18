# syntax=docker/dockerfile:1.6
FROM alpine:3.20

# lego version is pinned; bump intentionally when you want to update.
ARG LEGO_VERSION=4.19.2

RUN apk add --no-cache \
        bash \
        curl \
        ca-certificates \
        aws-cli \
        jq \
        tzdata \
        coreutils \
    && curl -fsSL "https://github.com/go-acme/lego/releases/download/v${LEGO_VERSION}/lego_v${LEGO_VERSION}_linux_amd64.tar.gz" \
        -o /tmp/lego.tar.gz \
    && tar -xzf /tmp/lego.tar.gz -C /usr/local/bin lego \
    && rm /tmp/lego.tar.gz \
    && chmod +x /usr/local/bin/lego

COPY renew.sh /usr/local/bin/renew.sh
RUN chmod +x /usr/local/bin/renew.sh

# Lego writes its account state and cert files here. Mount a persistent volume
# at /data/lego so the ACME account key and cert history survive container
# restarts.
WORKDIR /data/lego

# Container stays running so Coolify's Scheduled Tasks can `docker exec` into
# it. The actual work is triggered by invoking /usr/local/bin/renew.sh via
# Scheduled Tasks, not by the container's own lifecycle.
CMD ["sleep", "infinity"]
