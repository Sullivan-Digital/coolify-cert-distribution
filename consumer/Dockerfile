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
COPY runner.sh /usr/local/bin/runner.sh
COPY healthcheck.sh /usr/local/bin/healthcheck.sh
RUN chmod +x /usr/local/bin/fetch.sh /usr/local/bin/runner.sh /usr/local/bin/healthcheck.sh

# runner.sh invokes fetch.sh immediately (bootstrap) and then every
# RUN_INTERVAL_SECONDS (default 6h) for the life of the container. A
# failed bootstrap exits the container so Coolify's restart policy can
# surface day-1 config errors as a visible crashloop. Each run's outcome
# is recorded to /var/run/cert-consumer.status for the healthcheck.
CMD ["/usr/local/bin/runner.sh"]
