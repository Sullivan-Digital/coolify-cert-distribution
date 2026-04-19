# cert-renewer

Runs on **one** server (any Coolify-managed host — typically your control plane).
Obtains every certificate listed in `MANAGED_CERTS` from Let's Encrypt via
Route 53 DNS-01 and publishes each one to the shared S3 bucket.

The container stays running continuously (a trivial `sleep infinity`); the
actual renewal work is triggered via Coolify's **Scheduled Tasks** feature,
which `docker exec`s into the container on a cron. Each execution is
idempotent per cert — lego only actually renews when a cert has less than
`RENEW_DAYS` (default 30) of validity remaining, and the S3 upload step
only fires when that cert's fingerprint actually changed.

## Environment variables

### Required

- `MANAGED_CERTS` — whitespace-separated list of cert domains to issue,
  e.g. `"*.sullivandigital.com.au *.internal.sullivandigital.com.au coolify.bar.com"`.
  Each entry must have been declared in the CDK `--cert` input; the renewer
  looks up each one's zone from the SSM `certMappings` parameter at runtime.
- `ACME_EMAIL` — contact address for Let's Encrypt.

### Optional

- `STACK_NAME` — CDK stack name, used for SSM parameter paths. Default:
  `CertDistributionStack`. Override if you deployed under a different name.
- `S3_BUCKET` — bucket name. If unset, read from `/${STACK_NAME}/bucketName`
  via SSM.
- `AWS_REGION` — on EC2 the renewer resolves the region from IMDSv2
  automatically at the start of `renew.sh`, so this can be left unset.
  Set it explicitly when running somewhere without IMDS. (The compose
  file uses `network_mode: host` so IMDSv2 is reachable regardless of
  the instance's `HttpPutResponseHopLimit` setting.)
- `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` — omit on EC2 with an
  instance role attached.
- `USE_STAGING` — `true`/`1`/`yes` to use Let's Encrypt staging.
- `RENEW_DAYS` — days-before-expiry renewal window. Default 30.
- `LEGO_ROOT` — parent dir for per-cert lego state. Default `/data/lego`;
  each cert lands at `${LEGO_ROOT}/<slug>/`.

## Zone resolution

For each cert in `MANAGED_CERTS`, the renewer resolves its Route 53 zone
from the SSM mapping table using this algorithm (matching IAM's
`StringLike` semantics):

1. **Exact match wins**: if any mapping's `cert` equals the target, use its zone.
2. **Else longest-suffix wildcard match wins**: among mappings whose cert
   starts with `*.`, keep those where the target equals the cert's
   suffix (the part after `*.`) or ends with `.<suffix>`. Pick the longest
   suffix. Use that mapping's zone.
3. **Else error-and-skip**: the cert isn't permitted — log and move on to
   the next cert. The overall script exits non-zero at the end if any cert
   failed.

So for mappings `[{"cert":"*.foo.com","zone":"foo.com"}, {"cert":"*.internal.foo.com","zone":"internal.foo.com"}]`:

- `MANAGED_CERTS="api.internal.foo.com"` → resolves to `internal.foo.com`
  (longer suffix wins).
- `MANAGED_CERTS="coolify.foo.com"` → resolves to `foo.com`.
- `MANAGED_CERTS="nope.example.com"` → errors and skips.

The cert list in `MANAGED_CERTS` doesn't have to match the mappings 1:1 — a
common pattern is declaring the wildcard `*.foo.com` in CDK and issuing
subdomains like `api.foo.com` at runtime.

## What ends up in S3

For each cert, the bucket at `s3://${S3_BUCKET}/certs/<slug>/` contains:

```
cert.crt          # fullchain PEM
cert.key          # private key PEM
cert.issuer.crt   # issuer cert chain (optional, some tools want it)
fingerprint.txt   # SHA-256 fingerprint; consumers use this to detect change
metadata.json     # domain, zone, expiry, upload timestamp, staging flag
```

`<slug>` is derived from the cert domain: `*.foo.com` → `wildcard-foo-com`;
`coolify.foo.com` → `coolify-foo-com`.

`fingerprint.txt` is always written **last**, so consumers that poll it
never see a new fingerprint paired with stale cert bytes.

## Deployment on Coolify

1. Zip this folder and deploy it as a Docker Compose resource in Coolify
   (or point Coolify at a Git repo containing these files).
2. Set `MANAGED_CERTS` and `ACME_EMAIL` in Coolify's UI. Add `STACK_NAME`
   only if you deployed CDK under a non-default name. Everything else is
   optional.
3. Deploy it. The container starts and stays running (it just sleeps —
   renewal is triggered by scheduled task, not container startup).
4. Under the resource's **Scheduled Tasks** tab, click **+ Add New**:
   - Name: `renew`
   - Command: `/usr/local/bin/renew.sh`
   - Frequency: `0 3 * * *` (daily at 03:00 UTC)
   - Container: `cert-renewer` (only shown for multi-service composes)
5. Trigger the task manually from the UI to run the first issuance.
   Check execution history for stdout/stderr output.

Subsequent runs are no-ops per cert until each is within `RENEW_DAYS`
(default 30) of expiry — lego exits 0 without renewing and the script
detects no fingerprint change, so nothing gets pushed to S3.

### Recommendation: test against staging first

Set `USE_STAGING=true` for the first run. It'll hit Let's Encrypt's staging
environment (no rate limits, untrusted cert). Once that works end-to-end,
set `USE_STAGING=false`, **delete the `lego_data` volume** (so lego doesn't
try to renew the staging certs), and re-run to get production certs.

### `--force` flag

`docker exec cert-renewer /usr/local/bin/renew.sh --force` re-issues every
cert regardless of current expiry and re-uploads regardless of fingerprint
match. Useful for end-to-end testing; pair with `USE_STAGING=true` to avoid
burning production rate limits.

## IAM policy for the AWS credentials

The CDK stack (`infra/`) publishes a `RenewerPolicy` managed policy and a
default `RenewerRole`. Attach the role/policy to the EC2 host that runs
this container. On EC2, leave `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`
unset — both lego and the AWS CLI pick up credentials from IMDS
automatically.

If you aren't using the CDK stack: the policy grants
- `route53:GetChange`, `route53:ListHostedZonesByName`, and
  `route53:ListResourceRecordSets` on each permitted zone.
- `route53:ChangeResourceRecordSets` on each zone, scoped by the
  `ForAllValues:StringLike` condition to the expanded
  `_acme-challenge.<cert>` / `_acme-challenge.*.<cert>` TXT record names.
- `s3:PutObject` / `s3:GetObject` / `s3:DeleteObject` on
  `<bucket>/certs/*`, plus `s3:ListBucket` with a `certs/*` prefix
  condition.
- `ssm:GetParameter` on `/<stackName>/bucketName` and `/<stackName>/certMappings`.

The ACME-challenge restriction means a compromised credential can only
touch the specific TXT records needed for the declared certs — it can't
rewrite MX, A, or any other records in the zone.

## Bucket setup

Create the S3 bucket with:
- **Block all public access: ON** (AWS default; must stay on).
- **Default encryption: SSE-S3** (AES256) — the script uploads with this
  header but bucket-level default makes it belt-and-braces.
- **Versioning: ON** (optional but recommended — gives you audit history
  and one-click rollback if a bad cert ever gets uploaded).
- **Bucket policy: none** — IAM alone controls access.

## Troubleshooting

### `Invalid Configuration: Missing Region` from lego

Lego's Route 53 provider (AWS SDK Go v2) requires a region even though
Route 53 is global. `renew.sh` resolves one from IMDSv2 before invoking
lego — if that fails you'll see:

```
[…] ERROR: AWS_REGION is unset and could not be resolved from IMDSv2.
```

The compose file uses `network_mode: host` precisely so IMDSv2 is
reachable from inside the container without fiddling with the
instance's `HttpPutResponseHopLimit`. If you've changed that, switch
back — or set `AWS_REGION` explicitly in the Coolify UI for the
cert-renewer service (works anywhere, IMDS or not).

## Upgrading from the single-cert version

- `CERT_DOMAIN` and `AWS_HOSTED_ZONE_ID` are no longer read. Remove them
  from your Coolify deploy.
- `S3_PREFIX` is silently ignored. Certs now land at `certs/<slug>/` per
  cert; there's no single prefix to configure.
- The old `certs/wildcard/` S3 prefix is not auto-migrated. After one
  successful renew cycle on the new layout, you can
  `aws s3 rm --recursive s3://BUCKET/certs/wildcard/`.
- Lego state migrates by re-issuing: on first run under the new script,
  each cert registers a fresh ACME account under `/data/lego/<slug>/`.
  If you want to avoid re-registration, you can move the existing
  `/data/lego/accounts/` subtree into each per-slug dir before the first
  run — but honestly, the ACME rate limit for account creation is high
  enough that it's not worth the bother.
