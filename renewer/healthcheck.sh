#!/usr/bin/env bash
#
# Docker healthcheck for the renewer.
#
# Reads metadata.json from S3 and fails if not_after is less than WARN_DAYS
# away, or if the object is missing/unreadable. Coolify surfaces the
# unhealthy state via its notification channels.
#
# This catches the silent-failure mode called out in the README: renewer
# scheduled task has been broken long enough that the cert in S3 is about
# to expire.
#
set -euo pipefail

: "${S3_BUCKET:?S3_BUCKET must be set}"

S3_PREFIX="${S3_PREFIX:-certs/wildcard}"
WARN_DAYS="${HEALTHCHECK_WARN_DAYS:-14}"

META=$(aws s3 cp "s3://${S3_BUCKET}/${S3_PREFIX}/metadata.json" - \
    2>/dev/null) || {
    echo "UNHEALTHY: could not fetch metadata.json from s3://${S3_BUCKET}/${S3_PREFIX}/" >&2
    exit 1
}

NOT_AFTER=$(echo "${META}" | jq -r '.not_after // empty')
if [[ -z "${NOT_AFTER}" ]]; then
    echo "UNHEALTHY: metadata.json missing not_after field" >&2
    exit 1
fi

EXPIRY_EPOCH=$(date -u -d "${NOT_AFTER}" +%s 2>/dev/null) || {
    echo "UNHEALTHY: could not parse not_after='${NOT_AFTER}'" >&2
    exit 1
}

NOW_EPOCH=$(date -u +%s)
DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))

if (( DAYS_LEFT < WARN_DAYS )); then
    echo "UNHEALTHY: cert in S3 expires in ${DAYS_LEFT} days (threshold: ${WARN_DAYS})" >&2
    exit 1
fi

echo "OK: cert in S3 expires in ${DAYS_LEFT} days"
