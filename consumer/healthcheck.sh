#!/usr/bin/env bash
#
# Docker healthcheck for the consumer.
#
# Fails if the local wildcard cert is missing, unreadable, or expires
# within WARN_DAYS. Coolify surfaces the unhealthy state via its
# notification channels.
#
# This catches the silent-failure mode called out in the README from the
# consumer side: fetch.sh has been broken long enough that the on-disk
# cert Traefik is serving is about to expire.
#
set -euo pipefail

CERT_OUT_DIR="${CERT_OUT_DIR:-/host-coolify/proxy/certs}"
CRT_NAME="${CRT_NAME:-wildcard.crt}"
CRT_PATH="${CERT_OUT_DIR}/${CRT_NAME}"

WARN_DAYS="${HEALTHCHECK_WARN_DAYS:-14}"
WARN_SECONDS=$(( WARN_DAYS * 86400 ))

if [[ ! -f "${CRT_PATH}" ]]; then
    echo "UNHEALTHY: cert not present at ${CRT_PATH} (fetch.sh hasn't run successfully yet?)" >&2
    exit 1
fi

if ! openssl x509 -in "${CRT_PATH}" -noout -checkend "${WARN_SECONDS}" >/dev/null 2>&1; then
    NOT_AFTER=$(openssl x509 -in "${CRT_PATH}" -noout -enddate 2>/dev/null | cut -d= -f2)
    echo "UNHEALTHY: cert at ${CRT_PATH} expires within ${WARN_DAYS} days (not_after=${NOT_AFTER})" >&2
    exit 1
fi

NOT_AFTER=$(openssl x509 -in "${CRT_PATH}" -noout -enddate | cut -d= -f2)
echo "OK: cert at ${CRT_PATH} valid beyond ${WARN_DAYS} days (not_after=${NOT_AFTER})"
