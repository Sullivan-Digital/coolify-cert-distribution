#!/usr/bin/env bash
#
# Cert renewer: obtains/renews each cert listed in MANAGED_CERTS via ACME
# DNS-01 (Route 53) and pushes it to an S3 bucket for consumer VPSes to fetch.
#
# Each cert lives under s3://${S3_BUCKET}/certs/<slug>/ with the same four
# objects: cert.crt, cert.key, fingerprint.txt, metadata.json.
#
# Runs once and exits. Schedule via Coolify's Scheduled Tasks (daily is fine —
# lego is idempotent and only actually renews within 30 days of expiry).
#
set -euo pipefail

# Source the shared helper. In the container image it lives at
# /usr/local/lib/cert-distribution/common.sh (COPY'd by Dockerfile). For local
# development, fall back to the in-repo copy alongside this script.
# shellcheck source=lib/common.sh
if [[ -r /usr/local/lib/cert-distribution/common.sh ]]; then
    source /usr/local/lib/cert-distribution/common.sh
else
    source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
fi

# --- Arguments --------------------------------------------------------------
# --force: re-issue every cert from LE regardless of expiry and upload
# regardless of fingerprint match. Pair with USE_STAGING=true for end-to-end
# testing without burning prod rate limits.
FORCE=0
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done

# --- Required environment ---------------------------------------------------
: "${MANAGED_CERTS:?MANAGED_CERTS must be set (whitespace-separated list of cert domains to issue)}"
: "${ACME_EMAIL:?ACME_EMAIL must be set}"

# --- Optional environment ---------------------------------------------------
# AWS credentials and region are optional on EC2: if unset, both lego and the
# AWS CLI fall back to their default chain (instance profile + IMDS region).
# Set AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_REGION explicitly only
# if running somewhere without IMDS. Route 53 is global; region only affects
# S3 uploads.

STACK_NAME="${STACK_NAME:-CertDistributionStack}"

# USE_STAGING=1/true/yes → Let's Encrypt staging (no rate limits, untrusted).
USE_STAGING="${USE_STAGING:-false}"

# Days before expiry to trigger renewal. Lego's default is 30.
RENEW_DAYS="${RENEW_DAYS:-30}"

# Root of lego's per-cert state dirs; final path is ${LEGO_ROOT}/<slug>/.
LEGO_ROOT="${LEGO_ROOT:-/data/lego}"

log() {
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"
}

require_tools jq aws openssl lego || exit 1

# --- Fetch SSM mappings + optional S3_BUCKET fallback -----------------------
log "Loading cert→zone mappings from SSM (/${STACK_NAME}/certMappings)"
MAPPINGS_JSON=$(load_ssm_mappings) || {
    log "ERROR: could not read /${STACK_NAME}/certMappings from SSM"
    exit 1
}

if [[ -z "${S3_BUCKET:-}" ]]; then
    log "S3_BUCKET unset; reading /${STACK_NAME}/bucketName from SSM"
    S3_BUCKET=$(load_ssm_bucket_name) || {
        log "ERROR: S3_BUCKET unset and /${STACK_NAME}/bucketName lookup failed"
        exit 1
    }
fi
export S3_BUCKET

# --- renew_one: issue/renew + S3 upload for a single cert -------------------
# Called via `if ! renew_one ...` which inhibits set -e within the function
# body, so every critical command uses explicit `|| return 1`.
#
# $1 = cert domain (already normalised)
# $2 = zone name
# $3 = S3 prefix (e.g. certs/<slug>)
# $4 = slug (for lego per-cert state dir)
renew_one() {
    local cert="$1" zone="$2" s3_prefix="$3" slug="$4"
    local lego_path="${LEGO_ROOT}/${slug}"
    local crt="${lego_path}/certificates/${cert}.crt"
    local key="${lego_path}/certificates/${cert}.key"
    local issuer="${lego_path}/certificates/${cert}.issuer.crt"

    # Lego picks the zone by TXT record lookup via the AWS SDK — it only
    # needs the domain, not the zone id. Export AWS_REGION if set; lego's
    # Route 53 provider is otherwise region-agnostic. We pass the zone only
    # to keep the log line meaningful.
    mkdir -p "${lego_path}" || return 1

    # Lego args common to both run and renew.
    local -a lego_args=(
        --email "${ACME_EMAIL}"
        --dns route53
        --dns.resolvers "1.1.1.1:53,8.8.8.8:53"
        --domains "${cert}"
        --path "${lego_path}"
        --accept-tos
    )
    case "${USE_STAGING,,}" in
        1|true|yes)
            lego_args+=(--server "https://acme-staging-v02.api.letsencrypt.org/directory")
            ;;
    esac

    if [[ -f "${crt}" && -f "${key}" ]]; then
        if [[ "${FORCE}" == "1" ]]; then
            log "  [${cert}] --force: renewing regardless of expiry"
            lego "${lego_args[@]}" renew --days 9999 --no-random-sleep || return 1
        else
            log "  [${cert}] attempting renewal (acts only if <${RENEW_DAYS} days remain)"
            lego "${lego_args[@]}" renew --days "${RENEW_DAYS}" --no-random-sleep || return 1
        fi
    else
        log "  [${cert}] no existing cert; requesting a fresh one"
        lego "${lego_args[@]}" run || return 1
    fi

    if [[ ! -f "${crt}" || ! -f "${key}" ]]; then
        log "  [${cert}] ERROR: cert files not present after lego run"
        return 1
    fi

    # Fingerprint compare — only push on change (unless --force).
    local new_fp remote_fp=""
    new_fp=$(openssl x509 -in "${crt}" -noout -fingerprint -sha256 | cut -d= -f2) || return 1
    log "  [${cert}] local fingerprint: ${new_fp}"

    if aws s3api head-object \
            --bucket "${S3_BUCKET}" \
            --key "${s3_prefix}/fingerprint.txt" \
            >/dev/null 2>&1; then
        remote_fp=$(aws s3 cp "s3://${S3_BUCKET}/${s3_prefix}/fingerprint.txt" - 2>/dev/null || echo "")
    fi

    if [[ "${FORCE}" == "1" ]]; then
        log "  [${cert}] --force: uploading regardless of remote fingerprint"
    elif [[ -n "${remote_fp}" && "${remote_fp}" == "${new_fp}" ]]; then
        log "  [${cert}] remote fingerprint matches; nothing to upload"
        return 0
    fi

    log "  [${cert}] uploading to s3://${S3_BUCKET}/${s3_prefix}/ (remote was '${remote_fp:-<none>}')"

    local -a upload_args=(--only-show-errors --sse AES256)

    aws s3 cp "${crt}" "s3://${S3_BUCKET}/${s3_prefix}/cert.crt" "${upload_args[@]}" || return 1
    aws s3 cp "${key}" "s3://${S3_BUCKET}/${s3_prefix}/cert.key" "${upload_args[@]}" || return 1

    if [[ -f "${issuer}" ]]; then
        aws s3 cp "${issuer}" "s3://${S3_BUCKET}/${s3_prefix}/cert.issuer.crt" "${upload_args[@]}" || return 1
    fi

    # metadata.json before fingerprint.txt, so consumers polling the
    # fingerprint never see a new value paired with stale metadata.
    local not_after tmp_meta tmp_fp
    not_after=$(openssl x509 -in "${crt}" -noout -enddate | cut -d= -f2) || return 1
    tmp_meta=$(mktemp) || return 1
    tmp_fp=$(mktemp) || return 1
    # shellcheck disable=SC2064  # we want the trap to expand $tmp_* now
    trap "rm -f '${tmp_meta}' '${tmp_fp}'" RETURN

    cat > "${tmp_meta}" <<EOF
{
  "domain": "${cert}",
  "zone": "${zone}",
  "fingerprint_sha256": "${new_fp}",
  "not_after": "${not_after}",
  "uploaded_at": "$(date -u +'%Y-%m-%dT%H:%M:%SZ')",
  "staging": "${USE_STAGING}"
}
EOF

    aws s3 cp "${tmp_meta}" "s3://${S3_BUCKET}/${s3_prefix}/metadata.json" "${upload_args[@]}" || return 1

    # Fingerprint LAST — it's the consumer's trigger.
    printf '%s' "${new_fp}" > "${tmp_fp}" || return 1
    aws s3 cp "${tmp_fp}" "s3://${S3_BUCKET}/${s3_prefix}/fingerprint.txt" "${upload_args[@]}" || return 1

    log "  [${cert}] upload complete; cert expires ${not_after}"
    return 0
}

# --- Main loop --------------------------------------------------------------
declare -i FAILED=0
declare -i SUCCEEDED=0

for raw_cert in $MANAGED_CERTS; do
    cert=$(normalize_domain "$raw_cert")
    if [[ -z "$cert" ]]; then
        continue
    fi

    if ! zone=$(resolve_zone "$cert" "$MAPPINGS_JSON"); then
        log "ERROR: cert '$cert' has no permission mapping in SSM; skipping"
        FAILED+=1
        continue
    fi

    slug=$(slug_for "$cert")
    s3_prefix="certs/${slug}"

    log "Renewing ${cert} in zone ${zone} → s3://${S3_BUCKET}/${s3_prefix}/"

    if ! renew_one "$cert" "$zone" "$s3_prefix" "$slug"; then
        log "ERROR: renewal of '${cert}' failed"
        FAILED+=1
        continue
    fi
    SUCCEEDED+=1
done

log "Finished: ${SUCCEEDED} succeeded, ${FAILED} failed"
if (( FAILED > 0 )); then
    exit 1
fi
