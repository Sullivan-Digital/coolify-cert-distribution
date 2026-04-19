#!/usr/bin/env bash
#
# Cert consumer: polls S3 for each cert in FETCHED_CERTS (or every cert in the
# SSM cert-mappings table if unset) and writes them to the local Traefik
# dynamic config directory. Emits a single YAML with N entries in
# tls.certificates[] and no defaultCertificate.
#
# Triggers a config-watch reload by touching the dynamic YAML file (no
# container restart needed).
#
# Runs once and exits. Schedule via Coolify's Scheduled Tasks feature.
#
set -euo pipefail

# Source the shared helper. See renew.sh for the path rationale.
# shellcheck source=lib/common.sh
if [[ -r /usr/local/lib/cert-distribution/common.sh ]]; then
    source /usr/local/lib/cert-distribution/common.sh
else
    source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
fi

# --- Optional environment ---------------------------------------------------
# AWS credentials and region are optional on EC2 (instance-profile + IMDS).
# Set explicitly only if running somewhere without IMDS.

STACK_NAME="${STACK_NAME:-CertDistributionStack}"

# Directory Coolify's Traefik reads certs from (host path, bind-mounted in).
CERT_OUT_DIR="${CERT_OUT_DIR:-/host-coolify/proxy/certs}"

# Directory for Traefik's dynamic YAML config.
DYNAMIC_OUT_DIR="${DYNAMIC_OUT_DIR:-/host-coolify/proxy/dynamic}"

# Filename of the dynamic config we write.
DYNAMIC_NAME="${DYNAMIC_NAME:-wildcard-cert.yml}"

# Reload strategy: "touch" (default, uses Traefik's file-watch) or "restart"
# (docker restart PROXY_CONTAINER) or "none".
RELOAD_METHOD="${RELOAD_METHOD:-touch}"
PROXY_CONTAINER="${PROXY_CONTAINER:-coolify-proxy}"

# --- Setup ------------------------------------------------------------------
mkdir -p "${CERT_OUT_DIR}" "${DYNAMIC_OUT_DIR}"

log() {
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"
}

require_tools jq aws openssl curl || exit 1

# --- Resolve AWS region (best-effort) ---------------------------------------
# The AWS CLI usually resolves the region from IMDS on its own, but doing it
# out-of-band and exporting AWS_REGION avoids relying on SDK-level behaviour.
# Non-fatal here: if IMDS is unreachable, fall through and let aws-cli try.
if [[ -z "${AWS_REGION:-}" ]]; then
    if region=$(resolve_region_from_imds); then
        export AWS_REGION="${region}"
    fi
fi

# --- Load SSM mappings + optional S3_BUCKET fallback ------------------------
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

# --- Determine which certs to fetch -----------------------------------------
# FETCHED_CERTS (if set) is authoritative; otherwise pull every cert from
# the mappings. Entries in FETCHED_CERTS must match a mapping cert value
# exactly (after normalisation) — no globbing.

CERT_LIST=()
if [[ -n "${FETCHED_CERTS:-}" ]]; then
    for raw in $FETCHED_CERTS; do
        c=$(normalize_domain "$raw")
        [[ -z "$c" ]] && continue
        # Confirm this cert is declared in SSM — otherwise it'd just 404 on S3.
        in_map=$(printf '%s' "$MAPPINGS_JSON" | jq -r --arg c "$c" '
            def norm: ascii_downcase | sub("\\.$"; "");
            [ .[] | select((.cert | norm) == $c) ] | length
        ')
        if [[ "$in_map" == "0" ]]; then
            log "ERROR: FETCHED_CERTS entry '${c}' not declared in SSM mappings"
            exit 1
        fi
        CERT_LIST+=("$c")
    done
else
    while IFS= read -r c; do
        [[ -z "$c" ]] && continue
        CERT_LIST+=("$c")
    done < <(printf '%s' "$MAPPINGS_JSON" | jq -r '
        def norm: ascii_downcase | sub("\\.$"; "");
        .[].cert | norm
    ')
fi

if (( ${#CERT_LIST[@]} == 0 )); then
    log "ERROR: no certs to fetch (FETCHED_CERTS empty and mappings are empty)"
    exit 1
fi

log "Fetching ${#CERT_LIST[@]} cert(s): ${CERT_LIST[*]}"

# --- fetch_one: download + verify + install a single cert -------------------
# $1 = cert domain (already normalised)
# $2 = slug
# $3 = S3 prefix (certs/<slug>)
#
# Returns 0 on success (cert is in place at ${CERT_OUT_DIR}/<slug>.{crt,key}).
# Returns non-zero on any failure; caller aggregates into fail-fast behaviour.
fetch_one() {
    local cert="$1" slug="$2" s3_prefix="$3"
    local crt_path="${CERT_OUT_DIR}/${slug}.crt"
    local key_path="${CERT_OUT_DIR}/${slug}.key"

    # 1. Fetch remote fingerprint.
    local remote_fp
    remote_fp=$(aws s3 cp "s3://${S3_BUCKET}/${s3_prefix}/fingerprint.txt" - 2>/dev/null) || {
        log "  [${cert}] ERROR: could not fetch fingerprint.txt from ${s3_prefix}/"
        return 1
    }
    if [[ -z "$remote_fp" ]]; then
        log "  [${cert}] ERROR: remote fingerprint empty"
        return 1
    fi

    # 2. Compare against local cert (if present).
    local local_fp=""
    if [[ -f "$crt_path" ]]; then
        local_fp=$(openssl x509 -in "$crt_path" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 || echo "")
    fi

    if [[ "$local_fp" == "$remote_fp" ]]; then
        log "  [${cert}] local matches remote (${remote_fp}); no-op"
        return 0
    fi

    log "  [${cert}] fingerprint differs (local: '${local_fp:-<none>}'); downloading"

    # 3. Download to staging dir.
    local staging
    staging=$(mktemp -d) || return 1
    # shellcheck disable=SC2064
    trap "rm -rf '${staging}'" RETURN

    aws s3 cp "s3://${S3_BUCKET}/${s3_prefix}/cert.crt" "${staging}/crt" --only-show-errors || {
        log "  [${cert}] ERROR: download of cert.crt failed"
        return 1
    }
    aws s3 cp "s3://${S3_BUCKET}/${s3_prefix}/cert.key" "${staging}/key" --only-show-errors || {
        log "  [${cert}] ERROR: download of cert.key failed"
        return 1
    }

    # 4. Verify downloaded fingerprint matches advertised.
    local downloaded_fp
    downloaded_fp=$(openssl x509 -in "${staging}/crt" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2) || {
        log "  [${cert}] ERROR: could not read downloaded cert"
        return 1
    }
    if [[ "$downloaded_fp" != "$remote_fp" ]]; then
        log "  [${cert}] ERROR: downloaded fingerprint '${downloaded_fp}' != advertised '${remote_fp}'"
        return 1
    fi

    # 5. Verify key/cert pair (RSA only; EC trusted-by-convention).
    if openssl rsa -in "${staging}/key" -noout -check 2>/dev/null; then
        local crt_mod key_mod
        crt_mod=$(openssl x509 -in "${staging}/crt" -noout -modulus | openssl sha256) || return 1
        key_mod=$(openssl rsa -in "${staging}/key" -noout -modulus 2>/dev/null | openssl sha256) || return 1
        if [[ "$crt_mod" != "$key_mod" ]]; then
            log "  [${cert}] ERROR: cert and key moduli differ (mismatched pair)"
            return 1
        fi
    fi

    # 6. Atomic move into place.
    mv -f "${staging}/crt" "${crt_path}.new" || return 1
    mv -f "${staging}/key" "${key_path}.new" || return 1
    chmod 644 "${crt_path}.new" || return 1
    chmod 600 "${key_path}.new" || return 1
    mv -f "${crt_path}.new" "${crt_path}" || return 1
    mv -f "${key_path}.new" "${key_path}" || return 1

    log "  [${cert}] installed"
    return 0
}

# --- Main loop (fail-fast) --------------------------------------------------
declare -a SLUGS=()
declare -a CERTS=()

for cert in "${CERT_LIST[@]}"; do
    slug=$(slug_for "$cert")
    s3_prefix="certs/${slug}"
    log "Fetching ${cert} from s3://${S3_BUCKET}/${s3_prefix}/"

    if ! fetch_one "$cert" "$slug" "$s3_prefix"; then
        log "ERROR: fetch of '${cert}' failed — aborting"
        exit 1
    fi
    SLUGS+=("$slug")
    CERTS+=("$cert")
done

# --- Regenerate the Traefik dynamic YAML ------------------------------------
# One YAML containing every loaded cert. No defaultCertificate — Traefik only
# picks the default for SNIs that match nothing loaded, and in that case no
# cert we hold would match anyway (browser sees a warning either way).
DYNAMIC_PATH="${DYNAMIC_OUT_DIR}/${DYNAMIC_NAME}"
TMP_YAML="${DYNAMIC_PATH}.new"

{
    echo "# Managed by cert-consumer — do not edit by hand."
    echo "tls:"
    echo "  certificates:"
    for slug in "${SLUGS[@]}"; do
        echo "    - certFile: /traefik/certs/${slug}.crt"
        echo "      keyFile:  /traefik/certs/${slug}.key"
    done
} > "$TMP_YAML"

mv -f "$TMP_YAML" "$DYNAMIC_PATH"

# --- Trigger reload ---------------------------------------------------------
case "${RELOAD_METHOD}" in
    touch)
        touch "${DYNAMIC_PATH}"
        log "Touched ${DYNAMIC_PATH} to trigger Traefik reload"
        ;;
    restart)
        if command -v docker >/dev/null 2>&1 && [[ -S /var/run/docker.sock ]]; then
            log "Restarting ${PROXY_CONTAINER}"
            docker restart "${PROXY_CONTAINER}" >/dev/null
        else
            log "WARNING: RELOAD_METHOD=restart but docker socket not available; falling back to touch"
            touch "${DYNAMIC_PATH}"
        fi
        ;;
    none)
        log "RELOAD_METHOD=none; skipping reload step"
        ;;
    *)
        log "Unknown RELOAD_METHOD='${RELOAD_METHOD}'; defaulting to touch"
        touch "${DYNAMIC_PATH}"
        ;;
esac

# --- Expiry summary ---------------------------------------------------------
for i in "${!CERTS[@]}"; do
    cert="${CERTS[$i]}"
    slug="${SLUGS[$i]}"
    crt_path="${CERT_OUT_DIR}/${slug}.crt"
    not_after=$(openssl x509 -in "$crt_path" -noout -enddate 2>/dev/null | cut -d= -f2 || echo "unknown")
    log "  ${cert}: expires ${not_after}"
done
log "Done."
