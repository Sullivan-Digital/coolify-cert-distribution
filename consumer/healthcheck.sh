#!/usr/bin/env bash
#
# Docker healthcheck for the consumer.
#
# Iterates the *expected* cert set (FETCHED_CERTS if set, else every cert in
# the SSM mapping table). Fails if any expected cert's on-disk file is
# missing or expires within WARN_DAYS. Does not glob *.crt — stale files
# from pre-upgrade runs would give false positives.
#
# Catches the silent-failure mode from the consumer side: fetch.sh has been
# broken long enough that the on-disk cert Traefik is serving is about to
# expire.
#
set -euo pipefail

# shellcheck source=lib/common.sh
if [[ -r /usr/local/lib/cert-distribution/common.sh ]]; then
    source /usr/local/lib/cert-distribution/common.sh
else
    source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
fi

STACK_NAME="${STACK_NAME:-CertDistributionStack}"
CERT_OUT_DIR="${CERT_OUT_DIR:-/host-coolify/proxy/certs}"
WARN_DAYS="${HEALTHCHECK_WARN_DAYS:-14}"
WARN_SECONDS=$(( WARN_DAYS * 86400 ))

# Best-effort: resolve AWS_REGION from IMDSv2 if unset, so aws-cli calls
# below don't depend on SDK-level region discovery.
if [[ -z "${AWS_REGION:-}" ]]; then
    if region=$(resolve_region_from_imds); then
        export AWS_REGION="${region}"
    fi
fi

# Determine expected cert set.
EXPECTED=()
if [[ -n "${FETCHED_CERTS:-}" ]]; then
    for raw in $FETCHED_CERTS; do
        c=$(normalize_domain "$raw")
        [[ -z "$c" ]] && continue
        EXPECTED+=("$c")
    done
else
    MAPPINGS_JSON=$(load_ssm_mappings) || {
        echo "UNHEALTHY: could not read /${STACK_NAME}/certMappings from SSM" >&2
        exit 1
    }
    while IFS= read -r c; do
        [[ -z "$c" ]] && continue
        EXPECTED+=("$c")
    done < <(printf '%s' "$MAPPINGS_JSON" | jq -r '
        def norm: ascii_downcase | sub("\\.$"; "");
        .[].cert | norm
    ')
fi

if (( ${#EXPECTED[@]} == 0 )); then
    echo "UNHEALTHY: expected cert set is empty" >&2
    exit 1
fi

FAIL=0
SUMMARY=()

for cert in "${EXPECTED[@]}"; do
    slug=$(slug_for "$cert")
    crt_path="${CERT_OUT_DIR}/${slug}.crt"

    if [[ ! -f "$crt_path" ]]; then
        echo "UNHEALTHY: '${cert}' missing at ${crt_path}" >&2
        FAIL=1
        continue
    fi

    if ! openssl x509 -in "$crt_path" -noout -checkend "$WARN_SECONDS" >/dev/null 2>&1; then
        not_after=$(openssl x509 -in "$crt_path" -noout -enddate 2>/dev/null | cut -d= -f2 || echo "unknown")
        echo "UNHEALTHY: '${cert}' at ${crt_path} expires within ${WARN_DAYS} days (not_after=${not_after})" >&2
        FAIL=1
        SUMMARY+=("${cert}:EXPIRING(${not_after})")
        continue
    fi

    not_after=$(openssl x509 -in "$crt_path" -noout -enddate 2>/dev/null | cut -d= -f2)
    SUMMARY+=("${cert}:ok(${not_after})")
done

if (( FAIL )); then
    echo "Summary: ${SUMMARY[*]}" >&2
    exit 1
fi

echo "OK: ${SUMMARY[*]} (threshold: ${WARN_DAYS}d)"
