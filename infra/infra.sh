#!/usr/bin/env bash
#
# Thin wrapper around `cdk` that builds the `-c certs=<json>` context arg from
# repeated `--cert <pattern>[:zone]` flags. Everything else on the command line
# is forwarded verbatim to cdk.
#
# Usage:
#   ./infra.sh deploy \
#       --cert "*.sullivandigital.com.au" \
#       --cert "*.internal.sullivandigital.com.au" \
#       --cert "acme.oddzone.com:oddzone.com" \
#       --profile sullivan-admin --region ap-southeast-2
#
# `:zone` on a `--cert` value is optional. When absent, the zone is inferred
# by stripping the leading DNS label:
#   *.foo.com        -> zone = foo.com
#   bar.foo.com      -> zone = foo.com
#
# Requires `jq` on PATH.
set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required on PATH" >&2
    exit 1
fi

usage() {
    cat >&2 <<'EOF'
Usage: ./infra.sh <cdk-subcommand> --cert <pattern>[:zone] [--cert ...] [cdk-args...]

Example:
  ./infra.sh deploy --cert "*.foo.com" --cert "*.bar.com:bar.com" --profile prod

Flags:
  --cert <value>   Cert pattern with optional :zone suffix. Repeatable.
                   Patterns may be concrete (coolify.foo.com) or wildcards
                   (*.foo.com). Zone is inferred from the pattern when absent.

Any flags not consumed here are forwarded as-is to `cdk`.
EOF
}

# --- Argument parsing --------------------------------------------------------
CERT_VALUES=()
PASSTHROUGH=()

while (( $# > 0 )); do
    case "$1" in
        --cert)
            if (( $# < 2 )); then
                echo "ERROR: --cert requires a value" >&2
                usage
                exit 2
            fi
            CERT_VALUES+=("$2")
            shift 2
            ;;
        --cert=*)
            CERT_VALUES+=("${1#--cert=}")
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            PASSTHROUGH+=("$1")
            shift
            ;;
    esac
done

if (( ${#CERT_VALUES[@]} == 0 )); then
    echo "ERROR: at least one --cert flag is required" >&2
    usage
    exit 2
fi

# --- Normalise + validate each cert value -----------------------------------
# Emit a JSON array of { cert, zone } objects.

# Normalise: lowercase, strip trailing dot. Apply to both cert and zone so
# runtime comparisons (which also normalise at input boundaries) always match.
normalize() {
    local d="$1"
    d=$(printf '%s' "$d" | tr '[:upper:]' '[:lower:]')
    d="${d%.}"
    printf '%s' "$d"
}

ENTRIES_JSON='[]'
for raw in "${CERT_VALUES[@]}"; do
    cert="${raw%%:*}"
    if [[ "$raw" == *:* ]]; then
        zone="${raw#*:}"
    else
        zone=""
    fi

    cert=$(normalize "$cert")
    zone=$(normalize "$zone")

    if [[ -z "$cert" ]]; then
        echo "ERROR: --cert '$raw': empty cert pattern" >&2
        exit 2
    fi

    # Guard against slug collision between *.foo.com and wildcard.foo.com.
    # slug_for() maps both to 'wildcard-foo-com', so accepting both would
    # overwrite each other on S3 and disk.
    lower_cert="$cert"
    case "$lower_cert" in
        wildcard.*)
            echo "ERROR: --cert '$raw': cert pattern cannot start with 'wildcard.' (reserved — collides with *.foo.com slug)" >&2
            exit 2
            ;;
    esac

    if [[ -z "$zone" ]]; then
        # Infer by stripping the leading DNS label.
        if [[ "$cert" == \*.* ]]; then
            zone="${cert#*.}"
        else
            zone="${cert#*.}"
        fi
        # If the cert has no dots at all, the strip is a no-op — reject.
        if [[ "$zone" == "$cert" ]]; then
            echo "ERROR: --cert '$raw': cannot infer zone from '$cert' (no '.' to strip); use :zone suffix" >&2
            exit 2
        fi
    fi

    if [[ -z "$zone" ]]; then
        echo "ERROR: --cert '$raw': empty zone" >&2
        exit 2
    fi

    ENTRIES_JSON=$(printf '%s' "$ENTRIES_JSON" | jq -c \
        --arg cert "$cert" \
        --arg zone "$zone" \
        '. + [{cert: $cert, zone: $zone}]')
done

# --- Invoke cdk --------------------------------------------------------------
# Prefer the locally-installed cdk if present; fall back to npx (which resolves
# the devDependency) otherwise. Either way we run from the directory this
# script lives in so relative paths in cdk.json resolve.
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

if [[ -x "$HERE/node_modules/.bin/cdk" ]]; then
    CDK=("$HERE/node_modules/.bin/cdk")
else
    CDK=(npx cdk)
fi

exec "${CDK[@]}" "${PASSTHROUGH[@]}" -c "certs=${ENTRIES_JSON}"
