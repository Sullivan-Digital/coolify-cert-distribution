# shellcheck shell=bash
#
# Shared helpers for the renewer and consumer. This file is duplicated between
# renewer/lib/common.sh and consumer/lib/common.sh — keep them in sync.
# See PLAN_MULTI_CERT_SUPPORT.md §8 for why we duplicate instead of sharing.
#
# Expected to be sourced, not executed. Callers must have `set -euo pipefail`
# in effect.

# Normalise a domain string: lowercase, strip trailing dot. Apply at every
# input boundary (env vars, SSM reads) so case/trailing-dot skew between CDK
# input and runtime never causes a silent mismatch.
normalize_domain() {
    local d="$1"
    d=$(printf '%s' "$d" | tr '[:upper:]' '[:lower:]')
    d="${d%.}"
    printf '%s' "$d"
}

# Map a cert domain to a filesystem/S3-safe slug.
#   *.foo.com                -> wildcard-foo-com
#   coolify.foo.com          -> coolify-foo-com
#   *.internal.foo.com       -> wildcard-internal-foo-com
slug_for() {
    local cert
    cert="$(normalize_domain "$1")"
    if [[ "$cert" == \*.* ]]; then
        cert="wildcard.${cert#*.}"
    fi
    printf '%s' "${cert//./-}"
}

# Assert required tools are on PATH. Callers pass the tool names they need.
# Usage: require_tools jq aws openssl
require_tools() {
    local missing=()
    local tool
    for tool in "$@"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing+=("$tool")
        fi
    done
    if (( ${#missing[@]} > 0 )); then
        echo "ERROR: required tool(s) not on PATH: ${missing[*]}" >&2
        return 1
    fi
}

# Fetch /<STACK_NAME>/certMappings from SSM and echo the JSON string.
# Caller is responsible for having STACK_NAME set.
load_ssm_mappings() {
    local stack="${STACK_NAME:-CertDistributionStack}"
    aws ssm get-parameter \
        --name "/${stack}/certMappings" \
        --query 'Parameter.Value' \
        --output text
}

# Fetch /<STACK_NAME>/bucketName from SSM and echo the plain-string value.
load_ssm_bucket_name() {
    local stack="${STACK_NAME:-CertDistributionStack}"
    aws ssm get-parameter \
        --name "/${stack}/bucketName" \
        --query 'Parameter.Value' \
        --output text
}

# Resolve the Route 53 zone name for a given cert domain, using the
# exact-match-then-longest-wildcard-suffix rule.
#
#   $1 = target cert domain (already normalised)
#   $2 = mappings JSON (array of {cert, zone})
#
# Prints the resolved zone name on stdout. Exits non-zero with no output if
# the cert has no matching mapping — callers should branch on the return
# code, not the string.
resolve_zone() {
    local target="$1"
    local mappings_json="$2"
    local zone

    zone=$(printf '%s' "$mappings_json" | jq -r --arg target "$target" '
        # Normalise every mapping entry once so matching is case-insensitive
        # and trailing-dot-insensitive on both sides.
        def norm: ascii_downcase | sub("\\.$"; "");
        [ .[] | { cert: (.cert | norm), zone: (.zone | norm) } ] as $m
        |
        (
            # Exact match wins.
            ( $m[] | select(.cert == $target) | .zone ) //
            # Else longest-suffix wildcard wins. Bind .suffix to $suffix so the
            # endswith() pipe (which rebinds .) can still reference it.
            (
                [ $m[]
                    | select(.cert | startswith("*."))
                    | (.cert[2:]) as $suffix
                    | { cert, zone, suffix: $suffix }
                    | select($target == $suffix or ($target | endswith("." + $suffix)))
                ]
                | sort_by(.suffix | length) | reverse | .[0].zone
            )
        ) // empty
    ')

    if [[ -z "$zone" || "$zone" == "null" ]]; then
        return 1
    fi
    printf '%s' "$zone"
}
