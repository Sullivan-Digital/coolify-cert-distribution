#!/usr/bin/env bash
#
# Container entrypoint for cert-consumer.
#
# Runs fetch.sh once at startup so a fresh deploy isn't stuck waiting up to
# 12h for the first Coolify scheduled-task tick before it has a cert. If the
# bootstrap fetch fails (network, IAM, bucket empty) we exit and let Coolify's
# restart policy loop us — better a visible crashloop than a silently
# unhealthy container on day 1.
#
# After a successful bootstrap, exec sleep infinity so the container stays
# up for Coolify's Scheduled Tasks to `docker exec` into.
#
set -euo pipefail

echo "[entrypoint] running bootstrap fetch..."
/usr/local/bin/fetch.sh
echo "[entrypoint] bootstrap fetch complete; sleeping for scheduled-task exec"

exec sleep infinity
