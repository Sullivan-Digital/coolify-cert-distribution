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

COPY fetch.sh /usr/local/bin/fetch.sh
RUN chmod +x /usr/local/bin/fetch.sh

# Container stays running so Coolify's Scheduled Tasks can `docker exec` into
# it on a cron. The actual work is triggered by invoking fetch.sh via
# Scheduled Tasks, not by the container's own lifecycle.
CMD ["sleep", "infinity"]
