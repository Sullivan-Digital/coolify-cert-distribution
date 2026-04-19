# Coolify cert distribution

Distributes one or more Let's Encrypt certificates (wildcard or specific) to
multiple Coolify-managed servers via S3, avoiding the rate-limit problem of
every Traefik instance independently requesting certs for the same domains.
Supports multiple certs across multiple Route 53 hosted zones.

```
                    ┌────────────────┐
                    │   Route 53     │
                    └────────┬───────┘
                             │ DNS-01 challenge
                             │
    ┌─────────────┐          │          ┌────────────────┐
    │ cert-       │──────────┘          │ S3 bucket      │
    │  renewer    │─────────────────────▶ (locked down)  │
    │ (1 server)  │   push cert         │                │
    └─────────────┘                     └───────┬────────┘
                                                │
           ┌────────────────────┬───────────────┼────────────────┐
           │                    │               │                │
           ▼                    ▼               ▼                ▼
    ┌─────────────┐      ┌─────────────┐  ┌─────────────┐  ┌─────────────┐
    │ cert-       │      │ cert-       │  │ cert-       │  │ cert-       │
    │  consumer   │      │  consumer   │  │  consumer   │  │  consumer   │
    │   VPS 1     │      │   VPS 2     │  │   VPS 3     │  │   VPS N     │
    └──────┬──────┘      └──────┬──────┘  └──────┬──────┘  └──────┬──────┘
           │                    │                │                │
           ▼                    ▼                ▼                ▼
    ┌─────────────┐      ┌─────────────┐  ┌─────────────┐  ┌─────────────┐
    │ coolify-    │      │ coolify-    │  │ coolify-    │  │ coolify-    │
    │  proxy      │      │  proxy      │  │  proxy      │  │  proxy      │
    │ (Traefik)   │      │ (Traefik)   │  │ (Traefik)   │  │ (Traefik)   │
    └─────────────┘      └─────────────┘  └─────────────┘  └─────────────┘
```

## Why this design

- **One ACME issuance per cert per 60 days**, regardless of server count.
  No duplicate-cert rate-limit concerns.
- **Zero SSH between servers.** S3 is the only shared surface. No key
  management, no `authorized_keys` bookkeeping, no network paths to open.
- **Permission grants are declared in CDK, runtime selection is a deploy-time
  env var.** The CDK stack declares which cert/zone combinations the renewer
  role may touch; `MANAGED_CERTS` on the renewer picks which of those to
  actually issue. Add/remove managed certs without redeploying infra.
- **Audit trail.** S3 bucket versioning (recommended) gives you history
  of every cert ever uploaded, with timestamps and IAM user attribution
  via CloudTrail.
- **Deploys as a Coolify resource.** Same UX as everything else — logs,
  scheduled tasks, env vars, restart button.

## Pieces

- `infra/` — AWS CDK project that provisions the S3 bucket, the two managed
  IAM policies (renewer, consumer), and two SSM parameters the runtime reads.
  Run this first. Includes an `infra.sh` wrapper for the common case.
- `renewer/` — deploy once, on any Coolify-managed server. Obtains every
  cert listed in `MANAGED_CERTS` via Route 53 DNS-01 and pushes each to S3
  under its own per-cert prefix.
- `consumer/` — deploy on every Coolify server that serves HTTPS with these
  certs. Fetches each cert listed in the SSM mapping table (or a subset via
  `FETCHED_CERTS`), writes them to disk, nudges Traefik. Emits one dynamic
  YAML containing every loaded cert.

Each folder has its own README with deployment and IAM-policy details.

## Ordering of operations for initial setup

1. Deploy the CDK stack in `infra/`. The `./infra.sh` wrapper is the easiest
   way — it parses repeated `--cert "<pattern>[:zone]"` flags and builds the
   `certs` context array for you:
   ```bash
   cd infra
   npm install
   ./infra.sh deploy \
       --cert "*.sullivandigital.com.au" \
       --cert "*.internal.sullivandigital.com.au" \
       --profile sullivan-admin --region ap-southeast-2
   ```
   Note the stack outputs: bucket name, the two SSM parameter names, the two
   policy ARNs, and the two default instance-profile names.
2. Attach the default instance profiles to the EC2 hosts: the renewer
   profile on the one server that will run `cert-renewer`, the consumer
   profile on every server that runs a Coolify proxy. For additional
   servers, reuse these profiles or mint your own role and attach the
   matching managed policy ARN.
3. Deploy the renewer somewhere. Set `MANAGED_CERTS` (whitespace-separated
   list of cert domains to issue — each must appear in the CDK `--cert`
   input), `ACME_EMAIL`, and optionally `STACK_NAME` if you renamed the
   stack. Container starts and sits idle.
4. Add a Scheduled Task to the renewer: command `/usr/local/bin/renew.sh`,
   cron `0 3 * * *`. Set `USE_STAGING=true` for the first run.
5. Trigger the task manually. Validate staging certs land in S3 under
   `s3://BUCKET/certs/<slug>/` (one prefix per cert).
6. Set `USE_STAGING=false`, delete the `lego_data` volume so lego forgets
   the staging accounts, re-trigger the task.
7. Verify production certs are in S3 (`aws s3 ls s3://BUCKET/certs/`).
8. Deploy the consumer on each proxy-serving VPS. With an instance profile
   attached, no required env vars — it discovers bucket + mappings via SSM.
   Set `FETCHED_CERTS` if this server only needs a subset. It runs
   `fetch.sh` once at container start to bootstrap (container crashloops if
   this fails — check logs). Then add its scheduled task: command
   `/usr/local/bin/fetch.sh`, cron `0 */12 * * *`, for ongoing pulls.
9. On each server, ensure the Coolify Traefik proxy is set up for file-based
   certs rather than ACME:
   a. Remove any `--certificatesresolvers...acme...` flags from the proxy
      compose (Servers → Proxy → Configuration) — they're no longer needed.
   b. The consumer writes `wildcard-cert.yml` into the dynamic config
      directory, with one `tls.certificates[]` entry per loaded cert.
      Traefik matches incoming SNIs against the loaded certs.
   c. Coolify-generated service labels like `tls.certresolver=letsencrypt`
      continue to work — they only fire for routers that explicitly opt in.
      For services with no resolver, Traefik picks the right cert by SNI
      against the loaded set.

### Upgrading from the single-cert version

- The old `S3_PREFIX` / `CERT_DOMAIN` / `AWS_HOSTED_ZONE_ID` env vars are
  no longer read. Safe to remove from Coolify on existing deploys.
  `S3_PREFIX` in particular is **silently ignored** — the script now writes
  to `certs/<slug>/` per cert, not a flat `certs/wildcard/`.
- The old `certs/wildcard/` S3 prefix is not auto-migrated. After a
  successful renew + fetch cycle on the new layout, you can manually
  `aws s3 rm --recursive s3://BUCKET/certs/wildcard/`.
- The old on-disk `wildcard.crt` / `wildcard.key` files in each server's
  `/data/coolify/proxy/certs/` are harmless leftovers — the new dynamic
  YAML doesn't reference them and Traefik ignores unreferenced files. You
  can delete them manually once confident in the new layout.
- The new dynamic YAML has no `defaultCertificate` block. SNIs that match
  no loaded cert now get Traefik's self-signed cert instead of the old LE
  wildcard; both produce a browser warning, just a different cert shown.

## Why containers stay running instead of run-to-completion

Coolify's Scheduled Tasks feature works by `docker exec`-ing into a
**running** container on a schedule. That's why both containers use
`sleep infinity` as their main process — they exist only so there's
somewhere for the scheduled task to exec. Resource cost is negligible
(~5MB RAM per container).

An alternative would be running the scripts via host cron (not touching
Coolify's scheduler). This works but costs you Coolify's UI-based
execution history, log viewing, and cron editing. Not worth it unless
you're specifically avoiding Coolify's scheduler (e.g., because of known
reliability issues with its internal scheduler — see Coolify issue #6638
for context).

## Monitoring — don't skip this

The one failure mode that bites silently is **renewer broken while a cert
approaches expiry**. Set up monitoring on at least one of:

- The `not_after` field in `s3://BUCKET/certs/<slug>/metadata.json` for each
  managed cert. If any is less than 14 days in the future, page someone.
  The renewer's built-in healthcheck does this too, but external monitoring
  is belt-and-braces.
- An external HTTPS uptime check on one of your served services. Most
  uptime services (UptimeRobot, Healthchecks.io, BetterStack) include
  cert-expiry warnings.

Both are trivial to set up. Do both.
