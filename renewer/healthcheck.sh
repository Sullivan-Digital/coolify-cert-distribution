#!/usr/bin/env bash
#
# Docker healthcheck for the renewer.
#
# For each cert in MANAGED_CERTS, reads metadata.json from S3 and fails if
# any cert's not_after is less than WARN_DAYS away, or if any metadata is
# missing/unreadable. Coolify surfaces the unhealthy state via its
# notification channels.
#
# Catches the silent-failure mode: the renewer's scheduled task has been
# broken long enough that a cert in S3 is about to expire.
#
set -euo pipefail

# shellcheck source=lib/common.sh
if [[ -r /usr/local/lib/cert-distribution/common.sh ]]; then
    source /usr/local/lib/cert-distribution/common.sh
else
    source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
fi

: "${MANAGED_CERTS:?MANAGED_CERTS must be set}"

STACK_NAME="${STACK_NAME:-CertDistributionStack}"
WARN_DAYS="${HEALTHCHECK_WARN_DAYS:-14}"
STATUS_FILE="${RUNNER_STATUS_FILE:-/var/run/cert-renewer.status}"

# Runner status: fail fast if the last renew.sh invocation failed. The file is
# absent during start_period on a fresh container; that's fine — compose's
# start_period covers the window before the first loop iteration completes.
if [[ -f "$STATUS_FILE" ]]; then
    status=$(jq -r '.status // "unknown"' "$STATUS_FILE" 2>/dev/null || echo "unreadable")
    if [[ "$status" == "fail" ]]; then
        ran_at=$(jq -r '.ran_at // "?"' "$STATUS_FILE" 2>/dev/null || echo "?")
        exit_code=$(jq -r '.exit_code // "?"' "$STATUS_FILE" 2>/dev/null || echo "?")
        echo "UNHEALTHY: last renew.sh run failed (exit ${exit_code}, at ${ran_at})" >&2
        exit 1
    fi
    if [[ "$status" == "unreadable" ]]; then
        echo "UNHEALTHY: ${STATUS_FILE} is unreadable" >&2
        exit 1
    fi
fi

# Best-effort: resolve AWS_REGION from IMDSv2 if unset, so aws-cli calls
# below don't depend on SDK-level region discovery.
if [[ -z "${AWS_REGION:-}" ]]; then
    if region=$(resolve_region_from_imds); then
        export AWS_REGION="${region}"
    fi
fi

if [[ -z "${S3_BUCKET:-}" ]]; then
    S3_BUCKET=$(load_ssm_bucket_name) || {
        echo "UNHEALTHY: S3_BUCKET unset and /${STACK_NAME}/bucketName lookup failed" >&2
        exit 1
    }
fi

NOW_EPOCH=$(date -u +%s)
FAIL=0
SUMMARY=()

for raw_cert in $MANAGED_CERTS; do
    cert=$(normalize_domain "$raw_cert")
    [[ -z "$cert" ]] && continue

    slug=$(slug_for "$cert")
    meta=$(aws s3 cp "s3://${S3_BUCKET}/certs/${slug}/metadata.json" - 2>/dev/null) || {
        echo "UNHEALTHY: could not fetch metadata for '${cert}' (s3://${S3_BUCKET}/certs/${slug}/metadata.json)" >&2
        FAIL=1
        continue
    }

    not_after=$(echo "$meta" | jq -r '.not_after // empty')
    if [[ -z "$not_after" ]]; then
        echo "UNHEALTHY: metadata for '${cert}' missing not_after field" >&2
        FAIL=1
        continue
    fi

    expiry_epoch=$(date -u -d "$not_after" +%s 2>/dev/null) || {
        echo "UNHEALTHY: could not parse not_after='${not_after}' for '${cert}'" >&2
        FAIL=1
        continue
    }

    days_left=$(( (expiry_epoch - NOW_EPOCH) / 86400 ))
    SUMMARY+=("${cert}: ${days_left}d")

    if (( days_left < WARN_DAYS )); then
        echo "UNHEALTHY: '${cert}' expires in ${days_left} days (threshold: ${WARN_DAYS})" >&2
        FAIL=1
    fi
done

if (( FAIL )); then
    echo "Summary: ${SUMMARY[*]}" >&2
    exit 1
fi

echo "OK: ${SUMMARY[*]} (threshold: ${WARN_DAYS}d)"
