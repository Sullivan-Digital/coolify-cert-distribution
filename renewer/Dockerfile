# syntax=docker/dockerfile:1.6
FROM alpine:3.20

# lego version is pinned; bump intentionally when you want to update.
ARG LEGO_VERSION=4.19.2
# Populated by BuildKit from the target platform (e.g. amd64, arm64).
ARG TARGETARCH

RUN apk add --no-cache \
        bash \
        curl \
        ca-certificates \
        aws-cli \
        jq \
        tzdata \
        coreutils \
        openssl \
    && curl -fsSL "https://github.com/go-acme/lego/releases/download/v${LEGO_VERSION}/lego_v${LEGO_VERSION}_linux_${TARGETARCH}.tar.gz" \
        -o /tmp/lego.tar.gz \
    && tar -xzf /tmp/lego.tar.gz -C /usr/local/bin lego \
    && rm /tmp/lego.tar.gz \
    && chmod +x /usr/local/bin/lego

COPY lib/common.sh /usr/local/lib/cert-distribution/common.sh
COPY renew.sh /usr/local/bin/renew.sh
COPY runner.sh /usr/local/bin/runner.sh
COPY healthcheck.sh /usr/local/bin/healthcheck.sh
RUN chmod +x /usr/local/bin/renew.sh /usr/local/bin/runner.sh /usr/local/bin/healthcheck.sh

# Lego writes per-cert state under /data/lego/<slug>/. Mount a persistent
# volume at /data/lego so ACME account keys and cert history survive
# container restarts.
WORKDIR /data/lego

# runner.sh invokes renew.sh every RUN_INTERVAL_SECONDS (default 6h) and
# records each run's outcome to /var/run/cert-renewer.status for the
# healthcheck to read. `docker exec cert-renewer /usr/local/bin/renew.sh`
# still works for ad-hoc / --force runs.
CMD ["/usr/local/bin/runner.sh"]
