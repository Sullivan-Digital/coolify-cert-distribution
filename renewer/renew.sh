#!/usr/bin/env bash
#
# Cert renewer: obtains/renews a wildcard cert via ACME DNS-01 (Route 53)
# and pushes it to an S3 bucket for consumer VPSes to fetch.
#
# Runs once and exits. Schedule via Coolify's Scheduled Tasks (daily is fine
# since lego is idempotent and only actually renews within 30 days of expiry).
#
set -euo pipefail

# --- Arguments --------------------------------------------------------------
# --force: re-issue the cert from LE regardless of expiry, and upload to S3
# regardless of whether the fingerprint matches. Useful for end-to-end testing.
# Pair with USE_STAGING=true to avoid burning prod LE rate limits.
FORCE=0
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done

# --- Required environment ---------------------------------------------------
: "${CERT_DOMAIN:?CERT_DOMAIN must be set (e.g. internal.example.com)}"
: "${ACME_EMAIL:?ACME_EMAIL must be set}"
: "${AWS_HOSTED_ZONE_ID:?AWS_HOSTED_ZONE_ID must be set (Route 53 zone id)}"
: "${S3_BUCKET:?S3_BUCKET must be set (e.g. my-certs-bucket)}"

# --- Optional environment ---------------------------------------------------
# AWS credentials and region are optional on EC2: if unset, both lego and the
# AWS CLI fall back to their default chain, which picks up the instance
# profile / IAM role and the region from IMDS. Set AWS_ACCESS_KEY_ID,
# AWS_SECRET_ACCESS_KEY, and AWS_REGION explicitly only if you're running
# somewhere without IMDS. (Route 53 itself is a global service, so the region
# only matters for the S3 uploads here.)

# Key prefix inside the bucket. Cert lands at s3://${S3_BUCKET}/${S3_PREFIX}/
S3_PREFIX="${S3_PREFIX:-certs/wildcard}"

# Use Let's Encrypt staging to avoid rate-limit pain during first-time setup.
# Set to "1" / "true" to enable staging; any other value means production.
USE_STAGING="${USE_STAGING:-false}"

# Days before expiry to trigger renewal. Lego's default is 30.
RENEW_DAYS="${RENEW_DAYS:-30}"

# Where lego keeps its state. Mount this as a persistent volume.
LEGO_PATH="${LEGO_PATH:-/data/lego}"

# --- Derived ----------------------------------------------------------------
CRT="${LEGO_PATH}/certificates/${CERT_DOMAIN}.crt"
KEY="${LEGO_PATH}/certificates/${CERT_DOMAIN}.key"
ISSUER="${LEGO_PATH}/certificates/${CERT_DOMAIN}.issuer.crt"

mkdir -p "${LEGO_PATH}"

log() {
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"
}

build_lego_args() {
    local -a args=(
        --email "${ACME_EMAIL}"
        --dns route53
        --dns.resolvers "1.1.1.1:53,8.8.8.8:53"
        --domains "${CERT_DOMAIN}"
        --domains "*.${CERT_DOMAIN}"
        --path "${LEGO_PATH}"
        --accept-tos
    )
    case "${USE_STAGING,,}" in
        1|true|yes)
            args+=(--server "https://acme-staging-v02.api.letsencrypt.org/directory")
            log "Using Let's Encrypt STAGING environment"
            ;;
    esac
    printf '%s\n' "${args[@]}"
}

# --- Step 1: issue or renew -------------------------------------------------
log "Renewer starting for domain: ${CERT_DOMAIN} (and *.${CERT_DOMAIN})"

mapfile -t LEGO_ARGS < <(build_lego_args)

if [[ -f "${CRT}" && -f "${KEY}" ]]; then
    if [[ "${FORCE}" == "1" ]]; then
        log "Forcing renewal (--force): bypassing expiry check"
        lego "${LEGO_ARGS[@]}" renew --days 9999 --no-random-sleep
    else
        log "Existing cert found; attempting renewal (only acts if <${RENEW_DAYS} days remain)"
        # 'renew' exits 0 whether or not it actually renewed. If the cert isn't due,
        # it's a no-op and the file mtimes don't change.
        lego "${LEGO_ARGS[@]}" renew --days "${RENEW_DAYS}" --no-random-sleep
    fi
else
    log "No existing cert; requesting a fresh one"
    lego "${LEGO_ARGS[@]}" run
fi

if [[ ! -f "${CRT}" || ! -f "${KEY}" ]]; then
    log "ERROR: cert files not present after lego run. Aborting."
    exit 1
fi

# --- Step 2: compute a fingerprint so we only push on change ----------------
# Upload is cheap but pointless if the cert hasn't changed.
NEW_FINGERPRINT=$(openssl x509 -in "${CRT}" -noout -fingerprint -sha256 | cut -d= -f2)
log "Local cert fingerprint: ${NEW_FINGERPRINT}"

REMOTE_FINGERPRINT=""
if aws s3api head-object \
        --bucket "${S3_BUCKET}" \
        --key "${S3_PREFIX}/fingerprint.txt" \
        >/dev/null 2>&1; then
    REMOTE_FINGERPRINT=$(aws s3 cp \
        "s3://${S3_BUCKET}/${S3_PREFIX}/fingerprint.txt" - \
        2>/dev/null || echo "")
fi

if [[ "${FORCE}" == "1" ]]; then
    log "Forcing upload (--force): bypassing remote fingerprint check"
elif [[ -n "${REMOTE_FINGERPRINT}" && "${REMOTE_FINGERPRINT}" == "${NEW_FINGERPRINT}" ]]; then
    log "Remote fingerprint matches local. Nothing to upload. Done."
    exit 0
fi

log "Fingerprint differs (remote: '${REMOTE_FINGERPRINT:-<none>}'); uploading to S3"

# --- Step 3: push to S3 -----------------------------------------------------
# Upload cert bundle and metadata. aws s3 cp is atomic per-object (single PUT).
# Consumers check fingerprint.txt first; uploading it LAST ensures they never
# see a new fingerprint while the cert/key files are still in flight.

UPLOAD_ARGS=(
    --only-show-errors
    --sse AES256
)

aws s3 cp "${CRT}" "s3://${S3_BUCKET}/${S3_PREFIX}/wildcard.crt" "${UPLOAD_ARGS[@]}"
aws s3 cp "${KEY}" "s3://${S3_BUCKET}/${S3_PREFIX}/wildcard.key" "${UPLOAD_ARGS[@]}"

if [[ -f "${ISSUER}" ]]; then
    aws s3 cp "${ISSUER}" "s3://${S3_BUCKET}/${S3_PREFIX}/wildcard.issuer.crt" "${UPLOAD_ARGS[@]}"
fi

# Metadata: expiry date (useful for monitoring), domain, timestamp.
NOT_AFTER=$(openssl x509 -in "${CRT}" -noout -enddate | cut -d= -f2)
cat > /tmp/metadata.json <<EOF
{
  "domain": "${CERT_DOMAIN}",
  "fingerprint_sha256": "${NEW_FINGERPRINT}",
  "not_after": "${NOT_AFTER}",
  "uploaded_at": "$(date -u +'%Y-%m-%dT%H:%M:%SZ')",
  "staging": "${USE_STAGING}"
}
EOF
aws s3 cp /tmp/metadata.json "s3://${S3_BUCKET}/${S3_PREFIX}/metadata.json" "${UPLOAD_ARGS[@]}"

# Fingerprint file LAST — it's the consumer's trigger.
echo -n "${NEW_FINGERPRINT}" > /tmp/fingerprint.txt
aws s3 cp /tmp/fingerprint.txt "s3://${S3_BUCKET}/${S3_PREFIX}/fingerprint.txt" "${UPLOAD_ARGS[@]}"

log "Upload complete. Cert expires: ${NOT_AFTER}"
log "Done."
