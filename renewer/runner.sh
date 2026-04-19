#!/usr/bin/env bash
#
# Renewer supervisor loop.
#
# Runs renew.sh every RUN_INTERVAL_SECONDS (default 6h) for the life of the
# container. Writes the outcome of each iteration to /var/run/cert-renewer.status
# as JSON so healthcheck.sh can flag a broken loop long before certs approach
# expiry.
#
# Failure policy: the loop NEVER exits on a failed renewal. A bad run gets
# recorded in the status file (picked up by the healthcheck) and we sleep
# until the next tick. That way a transient DNS/ACME/IMDS blip doesn't
# crashloop the container and lose the log history Coolify is watching.
#
set -uo pipefail

SCRIPT="/usr/local/bin/renew.sh"
STATUS_FILE="/var/run/cert-renewer.status"
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

# Wake instantly on SIGTERM so `docker stop` doesn't wait out the sleep.
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

while true; do
    log "invoking ${SCRIPT}"
    if "$SCRIPT"; then
        rc=0
        log "run succeeded"
        write_status "ok" 0
    else
        rc=$?
        log "run failed (exit ${rc}); loop continues"
        write_status "fail" "$rc"
    fi

    log "sleeping ${INTERVAL}s"
    sleep "$INTERVAL" &
    SLEEP_PID=$!
    wait "$SLEEP_PID" || true
    SLEEP_PID=0
done
