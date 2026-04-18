#!/usr/bin/env bash
#
# Cert consumer: polls S3 for cert changes and writes them to the local
# Traefik dynamic config directory. Triggers a config-watch reload by
# touching the dynamic YAML file (no container restart needed).
#
# Runs once and exits. Schedule via Coolify's Scheduled Tasks feature
# to run every 24h (or more frequently if you want faster rollout).
#
set -euo pipefail

# --- Required environment ---------------------------------------------------
: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID must be set (read-only to cert bucket)}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY must be set}"
: "${AWS_REGION:?AWS_REGION must be set (e.g. ap-southeast-2)}"
: "${S3_BUCKET:?S3_BUCKET must be set}"

# --- Optional environment ---------------------------------------------------
S3_PREFIX="${S3_PREFIX:-certs/wildcard}"

# Directory on the host where Coolify's Traefik expects cert files.
# This path is the one mounted into coolify-proxy as /traefik/certs.
# It's hard-coded by Coolify and documented in their custom-ssl-certs page.
CERT_OUT_DIR="${CERT_OUT_DIR:-/host-coolify/proxy/certs}"

# Directory for the Traefik dynamic YAML config.
DYNAMIC_OUT_DIR="${DYNAMIC_OUT_DIR:-/host-coolify/proxy/dynamic}"

# Filenames Traefik reads.
CRT_NAME="${CRT_NAME:-wildcard.crt}"
KEY_NAME="${KEY_NAME:-wildcard.key}"
DYNAMIC_NAME="${DYNAMIC_NAME:-wildcard-cert.yml}"

# Whether to also restart the Traefik container if the cert changed.
# "touch" (default) just touches the dynamic config file and relies on
# Traefik's file-provider watch to reload. "restart" does a full container
# restart (brief downtime, but absolutely guaranteed to pick up new cert).
RELOAD_METHOD="${RELOAD_METHOD:-touch}"

# Container name of the Coolify Traefik proxy. Only used if RELOAD_METHOD=restart.
PROXY_CONTAINER="${PROXY_CONTAINER:-coolify-proxy}"

# --- Setup ------------------------------------------------------------------
mkdir -p "${CERT_OUT_DIR}" "${DYNAMIC_OUT_DIR}"

log() {
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"
}

# --- Step 1: fetch remote fingerprint ---------------------------------------
log "Consumer checking s3://${S3_BUCKET}/${S3_PREFIX}/ for cert updates"

REMOTE_FINGERPRINT=$(aws s3 cp \
    "s3://${S3_BUCKET}/${S3_PREFIX}/fingerprint.txt" - \
    --region "${AWS_REGION}" 2>/dev/null || echo "")

if [[ -z "${REMOTE_FINGERPRINT}" ]]; then
    log "ERROR: could not fetch remote fingerprint. Is the bucket populated?"
    exit 1
fi

log "Remote fingerprint: ${REMOTE_FINGERPRINT}"

# --- Step 2: compare against local ------------------------------------------
LOCAL_FINGERPRINT=""
if [[ -f "${CERT_OUT_DIR}/${CRT_NAME}" ]]; then
    LOCAL_FINGERPRINT=$(openssl x509 -in "${CERT_OUT_DIR}/${CRT_NAME}" \
        -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 || echo "")
fi

if [[ "${LOCAL_FINGERPRINT}" == "${REMOTE_FINGERPRINT}" ]]; then
    log "Local cert matches remote. Nothing to do."
    exit 0
fi

log "Cert changed (local: '${LOCAL_FINGERPRINT:-<none>}'). Fetching new one."

# --- Step 3: download atomically --------------------------------------------
# Download to a staging location, then move into place. Prevents Traefik from
# ever reading half-written files if it happens to scan mid-download.
STAGING=$(mktemp -d)
trap 'rm -rf "${STAGING}"' EXIT

aws s3 cp "s3://${S3_BUCKET}/${S3_PREFIX}/wildcard.crt" "${STAGING}/crt" \
    --region "${AWS_REGION}" --only-show-errors
aws s3 cp "s3://${S3_BUCKET}/${S3_PREFIX}/wildcard.key" "${STAGING}/key" \
    --region "${AWS_REGION}" --only-show-errors

# Verify the downloaded cert matches the fingerprint we saw.
# Protects against partial/corrupt downloads and against the rare race
# where the fingerprint file is updated between our read and the cert read.
DOWNLOADED_FINGERPRINT=$(openssl x509 -in "${STAGING}/crt" \
    -noout -fingerprint -sha256 | cut -d= -f2)
if [[ "${DOWNLOADED_FINGERPRINT}" != "${REMOTE_FINGERPRINT}" ]]; then
    log "ERROR: downloaded cert fingerprint '${DOWNLOADED_FINGERPRINT}' does not match advertised '${REMOTE_FINGERPRINT}'. Aborting."
    exit 1
fi

# Verify key and cert actually match each other.
CRT_MODULUS=$(openssl x509 -in "${STAGING}/crt" -noout -modulus | openssl sha256)
KEY_MODULUS=$(openssl rsa -in "${STAGING}/key" -noout -modulus 2>/dev/null | openssl sha256 || \
              openssl pkey -in "${STAGING}/key" -pubout 2>/dev/null | openssl sha256)
# Note: modulus check only works for RSA. For EC keys we just trust they're paired
# (lego writes them together and an unpaired key would fail TLS handshake anyway).
if openssl rsa -in "${STAGING}/key" -noout -check 2>/dev/null; then
    if [[ "${CRT_MODULUS}" != "${KEY_MODULUS}" ]]; then
        log "ERROR: downloaded cert and key do not match. Aborting."
        exit 1
    fi
fi

# --- Step 4: atomically move into place -------------------------------------
mv -f "${STAGING}/crt" "${CERT_OUT_DIR}/${CRT_NAME}.new"
mv -f "${STAGING}/key" "${CERT_OUT_DIR}/${KEY_NAME}.new"
chmod 600 "${CERT_OUT_DIR}/${KEY_NAME}.new"
chmod 644 "${CERT_OUT_DIR}/${CRT_NAME}.new"
mv -f "${CERT_OUT_DIR}/${CRT_NAME}.new" "${CERT_OUT_DIR}/${CRT_NAME}"
mv -f "${CERT_OUT_DIR}/${KEY_NAME}.new" "${CERT_OUT_DIR}/${KEY_NAME}"

# --- Step 5: ensure the dynamic config references the cert ------------------
# The paths here use /traefik — that's the in-container path inside
# coolify-proxy where /data/coolify/proxy is mounted. Do NOT change these
# to match CERT_OUT_DIR (which is the host path from the consumer's view).
DYNAMIC_PATH="${DYNAMIC_OUT_DIR}/${DYNAMIC_NAME}"
cat > "${DYNAMIC_PATH}.new" <<EOF
# Managed by cert-consumer — do not edit by hand.
tls:
  certificates:
    - certFile: /traefik/certs/${CRT_NAME}
      keyFile: /traefik/certs/${KEY_NAME}
  stores:
    default:
      defaultCertificate:
        certFile: /traefik/certs/${CRT_NAME}
        keyFile: /traefik/certs/${KEY_NAME}
EOF
mv -f "${DYNAMIC_PATH}.new" "${DYNAMIC_PATH}"

# --- Step 6: trigger Traefik reload -----------------------------------------
case "${RELOAD_METHOD}" in
    touch)
        # Traefik's file provider (providers.file.watch=true) reacts to mtime
        # changes on the dynamic config file. A plain touch is enough to make
        # it re-scan and re-load certs. No connection drops.
        touch "${DYNAMIC_PATH}"
        log "Touched ${DYNAMIC_PATH} to trigger Traefik config watch reload"
        ;;
    restart)
        if command -v docker >/dev/null 2>&1 && [[ -S /var/run/docker.sock ]]; then
            log "Restarting ${PROXY_CONTAINER}"
            docker restart "${PROXY_CONTAINER}" >/dev/null
        else
            log "WARNING: RELOAD_METHOD=restart but docker socket not available. Falling back to touch."
            touch "${DYNAMIC_PATH}"
        fi
        ;;
    none)
        log "RELOAD_METHOD=none; skipping reload step"
        ;;
    *)
        log "Unknown RELOAD_METHOD='${RELOAD_METHOD}'. Defaulting to touch."
        touch "${DYNAMIC_PATH}"
        ;;
esac

# --- Step 7: log the new cert's expiry for monitoring -----------------------
NOT_AFTER=$(openssl x509 -in "${CERT_OUT_DIR}/${CRT_NAME}" -noout -enddate | cut -d= -f2)
log "Cert installed. Expires: ${NOT_AFTER}"
log "Done."
