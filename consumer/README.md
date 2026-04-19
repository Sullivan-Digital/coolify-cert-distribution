# cert-consumer

Runs on **every** Coolify-managed server that has a `coolify-proxy` (Traefik)
instance serving HTTPS with the distributed certs. On startup the container
runs `fetch.sh` once to bootstrap (crashlooping on failure so config errors
are visible), then stays running continuously. Coolify's **Scheduled Tasks**
feature triggers subsequent fetches on a cron via `docker exec`.

The script polls S3 for each expected cert, downloads any that changed,
verifies fingerprint + key/cert pair, writes them to disk, emits one Traefik
dynamic YAML with all loaded certs, and touches the YAML to trigger a reload.

## Environment variables

### Required

**None.** With an EC2 instance profile attached, the consumer discovers
everything it needs from SSM.

### Optional

- `STACK_NAME` — CDK stack name, used for SSM parameter paths. Default:
  `CertDistributionStack`.
- `FETCHED_CERTS` — whitespace-separated list of cert domains to fetch.
  Each entry must match a `cert` value in the SSM mapping table exactly
  (after case/trailing-dot normalisation). **No globbing** — if you want a
  wildcard cert, declare `*.foo.com` in CDK and list the literal string
  `*.foo.com` here. Default: fetch every cert in the mapping table.
- `S3_BUCKET` — bucket name. If unset, read from `/${STACK_NAME}/bucketName`
  via SSM.
- `AWS_REGION` / `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` — omit on
  EC2 with an instance role attached. `AWS_REGION` is resolved from
  IMDSv2 at startup (best-effort); set it explicitly if running without
  IMDS. (The compose file uses `network_mode: host` so IMDSv2 is
  reachable regardless of the instance's `HttpPutResponseHopLimit`.)
- `CERT_OUT_DIR` — where cert files land. Default `/host-coolify/proxy/certs`
  (matches Coolify's default bind mount).
- `DYNAMIC_OUT_DIR` — where the Traefik dynamic YAML lands. Default
  `/host-coolify/proxy/dynamic`.
- `DYNAMIC_NAME` — filename of the dynamic YAML. Default `wildcard-cert.yml`
  (the name is historical — it now holds every cert, not just a wildcard).
- `RELOAD_METHOD` — `touch` (default) | `restart` | `none`.
- `PROXY_CONTAINER` — default `coolify-proxy`, only used when
  `RELOAD_METHOD=restart`.

## On-disk layout

For each loaded cert:

```
${CERT_OUT_DIR}/<slug>.crt
${CERT_OUT_DIR}/<slug>.key
```

Where `<slug>` is derived from the cert domain: `*.foo.com` →
`wildcard-foo-com`, `coolify.foo.com` → `coolify-foo-com`.

The dynamic YAML at `${DYNAMIC_OUT_DIR}/${DYNAMIC_NAME}` has one entry per
loaded cert:

```yaml
# Managed by cert-consumer — do not edit by hand.
tls:
  certificates:
    - certFile: /traefik/certs/wildcard-foo-com.crt
      keyFile:  /traefik/certs/wildcard-foo-com.key
    - certFile: /traefik/certs/coolify-bar-com.crt
      keyFile:  /traefik/certs/coolify-bar-com.key
```

The paths here use `/traefik/certs/…` — that's the in-container path inside
`coolify-proxy` where `/data/coolify/proxy` is bind-mounted. Do not rewrite
them to the consumer's view of the path (`${CERT_OUT_DIR}`).

There is **no `defaultCertificate`** block. Traefik matches incoming SNIs
against the loaded certs first; the default is only used for SNIs that
match no loaded cert, and in that case the old LE wildcard also wouldn't
have matched (browser warning either way).

## How it reloads Traefik

Default (`RELOAD_METHOD=touch`): writes the cert files, then `touch`es the
dynamic YAML. Traefik's file provider has `watch=true` by default in
Coolify, so it reacts to the mtime change and re-reads the config — which
re-reads the referenced cert files. Zero connection drops. Existing TLS
sessions continue on the old cert; new handshakes use the new cert.

Alternative (`RELOAD_METHOD=restart`): does `docker restart coolify-proxy`.
2–3 seconds of proxy downtime, but guaranteed-cleanest reload. Use this if
you hit an edge case where the touch method doesn't pick up changes.

## Failure semantics

`fetch.sh` exits non-zero on the first failure (missing fingerprint, download
error, fingerprint mismatch, key/cert mismatch, etc.). `entrypoint.sh` runs
`fetch.sh` at startup with `set -euo pipefail`, so any failure crashes the
container and Coolify's restart policy loops it — better a visible
crashloop than a silently unhealthy container on day 1.

On subsequent scheduled-task runs, a single cert failure still fails the
whole run — partial success semantics would hide real problems.

## Deployment on Coolify

1. Zip this folder and deploy as a Docker Compose resource on each server
   that has a Coolify proxy running.
2. Set any env vars you need in Coolify's UI. For the common case with an
   instance profile attached, you don't need any.
3. Deploy it. The container runs `fetch.sh` once at startup to populate
   the certs; if that fails (IAM, bucket, network, missing mappings) the
   container exits and Coolify's restart policy loops it, so config errors
   are visible rather than silent. After a successful bootstrap it stays
   running for scheduled-task execs.
4. Under **Scheduled Tasks**, click **+ Add New**:
   - Name: `fetch`
   - Command: `/usr/local/bin/fetch.sh`
   - Frequency: `0 */12 * * *` (every 12 hours — adjust to taste)
   - Container: `cert-consumer`

Subsequent scheduled-task runs only transfer bytes when the renewer has
uploaded a new version of a cert (compared by SHA-256 fingerprint per
cert).

## IAM policy for the AWS credentials

The CDK stack publishes a `ConsumerPolicy` managed policy and a default
`ConsumerRole`. Attach the role/policy to each EC2 host that runs this
container. On EC2, leave `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`
unset — the AWS CLI picks up credentials from IMDS automatically.

If you aren't using the CDK stack: the policy grants
- `s3:GetObject` on `<bucket>/certs/*`
- `s3:ListBucket` with a `certs/*` prefix condition
- `ssm:GetParameter` on `/<stackName>/bucketName` and
  `/<stackName>/certMappings`

Every consumer server can use the **same** IAM role and credentials — they
all read the same cert set.

## What this bind-mounts and why

The compose file mounts `/data/coolify/proxy` from the host into the
container at `/host-coolify/proxy`. That host path is where Coolify's
Traefik proxy reads its dynamic config and certs from (per Coolify's
custom-ssl-certs documentation). The consumer writes into the same place
so the proxy picks it up.

If your Coolify installation uses a non-default path, override
`CERT_OUT_DIR` and `DYNAMIC_OUT_DIR` via env vars, and adjust the volume
mount accordingly.

## Compatibility with the stock coolify-proxy config

The default `coolify-proxy` compose that Coolify ships needs **no changes** to
work with this consumer. The key bits that make it work out of the box:

- Proxy bind-mounts `/data/coolify/proxy/:/traefik`, which is the same host
  path this consumer writes to.
- Proxy runs with `--providers.file.directory=/traefik/dynamic/` and
  `--providers.file.watch=true`, so dropping a YAML into
  `/data/coolify/proxy/dynamic/` is picked up automatically.
- The dynamic YAML this consumer writes references `/traefik/certs/…` —
  those are the in-proxy-container paths, which resolve via the existing
  bind mount.

### Coexistence with per-host Let's Encrypt certs

The stock proxy config keeps the `letsencrypt` HTTP-01 resolver enabled.
That's fine — it only fires for routers that explicitly set
`tls.certresolver=letsencrypt`. Traefik matches SNIs against the loaded
certs first; services without a resolver get the matching loaded cert.

You can migrate services off `letsencrypt` onto the shared certs at your
own pace by removing their `certresolver` label.

## Verifying after first run

SSH into the server and check:

```bash
# Cert files exist (one per loaded cert)
ls -la /data/coolify/proxy/certs/

# Dynamic config exists and references the certs
cat /data/coolify/proxy/dynamic/wildcard-cert.yml

# Traefik is serving the right cert for a specific hostname
echo | openssl s_client -servername anything.internal.sullivandigital.com.au \
    -connect 127.0.0.1:443 2>/dev/null | openssl x509 -noout -issuer -dates -ext subjectAltName
```

You should see `issuer=C = US, O = Let's Encrypt, …`, a `notAfter` date
about 90 days in the future, and a SAN list that contains the requested
hostname.

## Failure modes to be aware of

- **Renewer broken, cert approaching expiry**: the consumer silently keeps
  the old cert because the remote fingerprint never changes. The renewer's
  healthcheck catches this from the S3 side; the consumer's healthcheck
  catches it from the on-disk side. Plus: external HTTPS uptime
  monitoring on known services.
- **S3 unreachable**: consumer exits non-zero. Coolify's Scheduled Tasks
  logs the failure. Not urgent on any single run — you have up to ~60 days
  of headroom before any cert expires.
- **Cert declared in CDK but not yet issued by renewer**: the consumer's
  default (fetch every cert in mappings) will fail on the missing one.
  Either run the renewer first, or set `FETCHED_CERTS` to limit to certs
  you know are published.
- **Consumer bootstrap fails on a new server**: the container crashloops
  instead of silently coming up with no certs. Check logs (`docker logs
  cert-consumer`) for IAM, bucket, or network errors before deploying
  HTTPS services on that server.

## Upgrading from the single-cert version

- `S3_PREFIX` is silently ignored. The consumer now reads `certs/<slug>/`
  per cert.
- The old on-disk `wildcard.crt` / `wildcard.key` files are harmless
  leftovers — the new dynamic YAML doesn't reference them, Traefik ignores
  unreferenced files. You can delete them manually once confident in the
  new layout. The healthcheck explicitly does *not* glob `*.crt` so those
  stale files don't cause false positives.
- The dynamic YAML no longer contains a `defaultCertificate`. Unmatched
  SNIs now get Traefik's self-signed cert instead of the old LE wildcard;
  both produce a browser warning, different cert shown.
