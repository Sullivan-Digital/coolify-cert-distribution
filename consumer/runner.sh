#!/usr/bin/env bash
#
# Consumer supervisor loop.
#
# Runs fetch.sh every RUN_INTERVAL_SECONDS (default 6h) for the life of the
# container. Writes the outcome of each iteration to /var/run/cert-consumer.status
# as JSON so healthcheck.sh can flag a broken loop long before the on-disk
# cert approaches expiry.
#
# Failure policy:
# - First iteration acts as the bootstrap: on failure we exit non-zero so
#   Coolify's restart policy loops the container. Day-1 misconfiguration
#   (IAM, bucket, network, missing SSM mappings) becomes a visible crashloop
#   rather than a silently unhealthy container serving no certs.
# - Subsequent failures are recorded in the status file but don't kill the
#   loop — a transient S3 blip shouldn't drop the cert Traefik is already
#   serving.
#
set -uo pipefail

SCRIPT="/usr/local/bin/fetch.sh"
STATUS_FILE="/var/run/cert-consumer.status"
INTERVAL="${RUN_INTERVAL_SECONDS:-21600}"

log() {
    echo "[runner] [$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"
}

write_status() {
    local status="$1" exit_code="$2"
    local tmp
    tmp=$(mktemp) || return
    cat > "$tmp" <<EOF
{"status":"${status}","ran_at":"$(date -u +'%Y-%m-%dT%H:%M:%SZ')","exit_code":${exit_code}}
EOF
    mv -f "$tmp" "$STATUS_FILE"
}

SLEEP_PID=0
on_term() {
    log "received SIGTERM; exiting"
    if (( SLEEP_PID > 0 )); then
        kill "$SLEEP_PID" 2>/dev/null || true
    fi
    exit 0
}
trap on_term TERM INT

log "starting; interval=${INTERVAL}s; script=${SCRIPT}"

first=1
while true; do
    log "invoking ${SCRIPT}"
    if "$SCRIPT"; then
        rc=0
        log "run succeeded"
        write_status "ok" 0
    else
        rc=$?
        if (( first )); then
            log "bootstrap run failed (exit ${rc}); exiting so restart policy can retry"
            write_status "fail" "$rc"
            exit "$rc"
        fi
        log "run failed (exit ${rc}); loop continues"
        write_status "fail" "$rc"
    fi
    first=0

    log "sleeping ${INTERVAL}s"
    sleep "$INTERVAL" &
    SLEEP_PID=$!
    wait "$SLEEP_PID" || true
    SLEEP_PID=0
done
