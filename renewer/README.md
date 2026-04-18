# cert-renewer

Runs on **one** server (any Coolify-managed host — typically your control plane).
Obtains a wildcard certificate from Let's Encrypt via Route 53 DNS-01 and
publishes it to an S3 bucket.

The container stays running continuously (a trivial `sleep infinity`); the
actual renewal work is triggered via Coolify's **Scheduled Tasks** feature,
which `docker exec`s into the container on a cron. Each execution is
idempotent — lego only actually renews when the cert has less than
`RENEW_DAYS` (default 30) of validity remaining, and the S3 upload step
only fires when the cert fingerprint actually changed.

## What ends up in S3

After a successful run, the bucket at `s3://${S3_BUCKET}/${S3_PREFIX}/` contains:

```
wildcard.crt          # fullchain PEM
wildcard.key          # private key PEM
wildcard.issuer.crt   # issuer cert chain (optional, some tools want it)
fingerprint.txt       # SHA-256 fingerprint; consumers use this to detect change
metadata.json         # expiry date, domain, upload timestamp
```

`fingerprint.txt` is always written **last**, so consumers that poll it never
see a new fingerprint paired with stale cert bytes.

## Deployment on Coolify

1. Zip this folder and deploy it as a Docker Compose resource in Coolify
   (or point Coolify at a Git repo containing these files).
2. Set the environment variables in Coolify's UI (see `docker-compose.yml`
   header comment for the list).
3. Deploy it. The container will start and stay running (it just sleeps —
   renewal is triggered by scheduled task, not container startup).
4. Under the resource's **Scheduled Tasks** tab, click **+ Add New**:
   - Name: `renew`
   - Command: `/usr/local/bin/renew.sh`
   - Frequency: `0 3 * * *` (daily at 03:00 UTC)
   - Container: `cert-renewer` (only shown for multi-service composes)
5. Trigger the task manually from the UI to run the first issuance.
   Check execution history for stdout/stderr output.

Subsequent runs are no-ops until the cert is within `RENEW_DAYS` (default 30)
of expiry — lego exits 0 without renewing and the script detects no
fingerprint change, so nothing gets pushed to S3.

### Recommendation: test against staging first

Set `USE_STAGING=true` for the first run. It'll hit Let's Encrypt's staging
environment (no rate limits, untrusted cert). Once that works end-to-end,
set `USE_STAGING=false`, **delete the `lego_data` volume** (so lego doesn't
try to renew the staging cert), and re-run to get a production cert.

## IAM policy for the AWS credentials

The IAM principal needs two things: Route 53 write access for the ACME
DNS-01 challenge, and S3 write access to the cert bucket. On EC2, attach
this policy to the instance's IAM role and leave `AWS_ACCESS_KEY_ID` /
`AWS_SECRET_ACCESS_KEY` unset — both lego and the AWS CLI pick up
credentials from IMDS automatically. Set the static keys only when running
somewhere without an instance role.

Least-privilege policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "Route53AcmeChallenge",
      "Effect": "Allow",
      "Action": "route53:GetChange",
      "Resource": "arn:aws:route53:::change/*"
    },
    {
      "Sid": "Route53ListZones",
      "Effect": "Allow",
      "Action": "route53:ListHostedZonesByName",
      "Resource": "*"
    },
    {
      "Sid": "Route53ReadZone",
      "Effect": "Allow",
      "Action": "route53:ListResourceRecordSets",
      "Resource": "arn:aws:route53:::hostedzone/YOUR_ZONE_ID"
    },
    {
      "Sid": "Route53WriteChallengeOnly",
      "Effect": "Allow",
      "Action": "route53:ChangeResourceRecordSets",
      "Resource": "arn:aws:route53:::hostedzone/YOUR_ZONE_ID",
      "Condition": {
        "ForAllValues:StringEquals": {
          "route53:ChangeResourceRecordSetsNormalizedRecordNames": [
            "_acme-challenge.internal.example.com"
          ],
          "route53:ChangeResourceRecordSetsRecordTypes": ["TXT"]
        }
      }
    },
    {
      "Sid": "S3WriteCerts",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:PutObjectAcl",
        "s3:GetObject",
        "s3:DeleteObject"
      ],
      "Resource": "arn:aws:s3:::YOUR_BUCKET/certs/wildcard/*"
    },
    {
      "Sid": "S3ListBucket",
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

Replace `YOUR_ZONE_ID`, `YOUR_BUCKET`, and the domain in the ACME-challenge
condition with your values. The ACME-challenge restriction means this key
can only touch one specific TXT record in Route 53 — if it leaks, the
attacker can't modify your MX, A, or any other records.

## Bucket setup

Create the S3 bucket with:
- **Block all public access: ON** (this is the AWS default and must stay on).
- **Default encryption: SSE-S3** (AES256) — the script uploads with this
  header but bucket-level default makes it belt-and-braces.
- **Versioning: ON** (optional but recommended — gives you audit history
  and one-click rollback if a bad cert ever gets uploaded).
- **Bucket policy: none** — IAM alone controls access.
