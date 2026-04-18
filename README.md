# Coolify wildcard cert distribution

Distributes a single Let's Encrypt wildcard certificate to multiple
Coolify-managed servers via S3, avoiding the rate-limit problem of every
Traefik instance independently requesting certs for the same wildcard.

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

- **One ACME issuance per 60 days**, regardless of server count.
  No more duplicate-cert rate-limit concerns.
- **Zero SSH between servers.** S3 is the only shared surface. No key
  management, no `authorized_keys` bookkeeping, no network paths to open.
- **Centralised revocation and rotation.** Change the cert once in S3,
  all servers pick it up on next poll.
- **Audit trail.** S3 bucket versioning (recommended) gives you history
  of every cert ever uploaded, with timestamps and IAM user attribution
  via CloudTrail.
- **Deploys as a Coolify resource.** Same UX as everything else — logs,
  scheduled tasks, env vars, restart button.

## Pieces

- `infra/` — AWS CDK project that provisions the S3 bucket and the two EC2
  instance roles (renewer + consumer). Run this first.
- `renewer/` — deploy once, on any Coolify-managed server. Obtains the
  wildcard via Route 53 DNS-01, pushes to S3.
- `consumer/` — deploy on every Coolify server that serves HTTPS with
  this wildcard. Polls S3, writes cert files, nudges Traefik.

Each folder has its own README with deployment and IAM-policy details.

## Ordering of operations for initial setup

1. Deploy the CDK stack in `infra/` — creates the bucket, two managed
   IAM policies (renewer, consumer), and default instance roles that
   have those policies attached. Note the stack outputs: bucket name,
   hosted zone id, the two policy ARNs, and the two default
   instance-profile names.
2. Attach the default instance profiles to the EC2 hosts: the renewer
   profile on the one server that will run `cert-renewer`, the consumer
   profile on every server that runs a Coolify proxy. For additional
   servers, you can either reuse these profiles or mint your own role
   per server and attach the matching managed policy ARN.
3. Deploy the renewer somewhere. Container starts and sits idle.
4. Add a Scheduled Task to the renewer: command `/usr/local/bin/renew.sh`,
   cron `0 3 * * *`. Set `USE_STAGING=true` for the first run.
5. Trigger the task manually. Validate staging cert lands in S3.
6. Set `USE_STAGING=false`, delete the `lego_data` volume so lego forgets
   the staging account, re-trigger the task.
7. Verify the production cert is in S3 (`aws s3 ls s3://BUCKET/certs/wildcard/`).
8. Deploy the consumer on each proxy-serving VPS. Add its scheduled task:
   command `/usr/local/bin/fetch.sh`, cron `0 */12 * * *`. Trigger manually
   the first time.
9. On each server, ensure the Coolify Traefik proxy is set up for file-based
   certs rather than ACME:
   a. Remove any `--certificatesresolvers...acme...` flags from the proxy
      compose (Servers → Proxy → Configuration) — they're no longer needed.
   b. The consumer writes `wildcard-cert.yml` into the dynamic config
      directory, which configures Traefik to use the cert.
   c. Coolify-generated service labels like `tls.certresolver=letsencrypt`
      become inert because the `defaultCertificate` in the dynamic config
      already serves a valid cert for any hostname matching the wildcard.

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

The one failure mode that bites silently is **renewer broken while cert
approaches expiry**. Set up monitoring on at least one of:

- The `not_after` field in `s3://BUCKET/certs/wildcard/metadata.json`.
  If it's less than 14 days in the future, page someone.
- An external HTTPS uptime check on one of your wildcard-served services.
  Most uptime services (UptimeRobot, Healthchecks.io, BetterStack) include
  cert-expiry warnings.

Both are trivial to set up. Do both.
