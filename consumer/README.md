# cert-consumer

Runs on **every** Coolify-managed server that has a `coolify-proxy` (Traefik)
instance serving wildcard-domain services. On startup the container runs
`fetch.sh` once to bootstrap the cert (crashlooping on failure so config
errors are visible), then stays running continuously. Coolify's **Scheduled
Tasks** feature triggers subsequent fetches on a cron via `docker exec`.
The script polls S3 for cert updates; downloads, verifies, and installs
the cert if changed; triggers a Traefik reload.

## How it reloads Traefik

Default (`RELOAD_METHOD=touch`): writes the cert files, then `touch`es the
dynamic YAML config. Traefik's file provider has `watch=true` by default in
Coolify, so it reacts to the mtime change and re-reads the config — which
re-reads the referenced cert files. Zero connection drops. Existing TLS
sessions continue on the old cert; new handshakes use the new cert.

Alternative (`RELOAD_METHOD=restart`): does `docker restart coolify-proxy`.
2-3 seconds of proxy downtime, but guaranteed-cleanest reload. Use this if
you hit an edge case where the touch method doesn't pick up changes (rare
with the bind-mounted volume Coolify uses, but can happen on some kernels
with older inotify).

## Deployment on Coolify

1. Zip this folder and deploy as a Docker Compose resource on each server
   that has a Coolify proxy running.
2. Set the environment variables in Coolify's UI.
3. Deploy it. The container runs `fetch.sh` once at startup to populate
   the cert; if that fails (IAM, bucket, network) the container exits and
   Coolify's restart policy loops it, so config errors are visible rather
   than silent. After a successful bootstrap it stays running for
   scheduled-task execs.
4. Under **Scheduled Tasks**, click **+ Add New**:
   - Name: `fetch`
   - Command: `/usr/local/bin/fetch.sh`
   - Frequency: `0 */12 * * *` (every 12 hours — adjust to taste)
   - Container: `cert-consumer`

Subsequent scheduled-task runs only do anything if the renewer has
uploaded a new cert (compared by SHA-256 fingerprint).

## IAM policy for the AWS credentials

This is a **separate** IAM role/user from the renewer — read-only access to
the cert bucket, nothing else. If a consumer server is compromised, the
attacker gets the wildcard cert (which they already have on-disk anyway)
and the ability to read that bucket prefix. Nothing more.

On EC2, attach this policy to the instance's IAM role and leave
`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` unset — the AWS CLI picks up
credentials from IMDS automatically. Set the static keys only when running
somewhere without an instance role.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3ReadCerts",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject"
      ],
      "Resource": "arn:aws:s3:::YOUR_BUCKET/certs/wildcard/*"
    },
    {
      "Sid": "S3ListBucketPrefix",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::YOUR_BUCKET",
      "Condition": {
        "StringLike": {
          "s3:prefix": ["certs/wildcard/*"]
        }
      }
    }
  ]
}
```

Replace `YOUR_BUCKET`. Every consumer server can use the **same** IAM user
and credentials — there's no per-server scoping needed since they're all
reading the same cert.

## What this bind-mounts and why

The compose file mounts `/data/coolify/proxy` from the host into the
container at `/host-coolify/proxy`. That host path is where Coolify's
Traefik proxy reads its dynamic config and certs from (per Coolify's
custom-ssl-certs documentation). The consumer writes into the same place
so the proxy picks it up.

If your Coolify installation uses a non-default path, override `CERT_OUT_DIR`
and `DYNAMIC_OUT_DIR` via env vars, and adjust the volume mount accordingly.

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
  bind mount. Do not rewrite them to the consumer's view of the path.

### Coexistence with per-host Let's Encrypt certs

The stock proxy config keeps the `letsencrypt` HTTP-01 resolver enabled.
That's fine — it only fires for routers that explicitly set
`tls.certresolver=letsencrypt`. The wildcard this consumer installs is
written as Traefik's `defaultCertificate`, so:

- Existing services pinned to `letsencrypt` keep getting per-host certs.
- New services that set `tls: true` with no resolver get served the
  wildcard automatically.

You can migrate services onto the wildcard at your own pace by removing
their `certresolver` label.

## Verifying after first run

SSH into the server and check:

```bash
# Cert files exist
ls -la /data/coolify/proxy/certs/
# Dynamic config exists and references the cert
cat /data/coolify/proxy/dynamic/wildcard-cert.yml
# Traefik is serving the cert
echo | openssl s_client -servername anything.internal.sullivandigital.com.au \
    -connect 127.0.0.1:443 2>/dev/null | openssl x509 -noout -issuer -dates
```

You should see `issuer=C = US, O = Let's Encrypt, CN = R3` (or similar)
and a `notAfter` date about 90 days in the future.

## Failure modes to be aware of

- **Renewer broken, cert approaching expiry**: the consumer will silently
  keep the old cert because the remote fingerprint never changes. Set up
  external monitoring on `metadata.json`'s `not_after` field, or on the
  actual HTTPS endpoint of a known service. This is the most important
  thing to monitor.
- **S3 unreachable**: consumer exits non-zero. Coolify's Scheduled Tasks
  will log the failure. Not urgent on any single run — you have ~60 days
  of headroom before the cert expires.
- **Consumer bootstrap fails on a new server**: the container crashloops
  instead of silently coming up with no cert. Check logs (`docker logs
  cert-consumer`) for IAM, bucket, or network errors before deploying
  HTTPS services on that server.
