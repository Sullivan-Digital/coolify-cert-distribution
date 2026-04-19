# infra

AWS CDK project that provisions the shared infrastructure for `cert-renewer`
and `cert-consumer`:

- **S3 bucket** (private, SSE-S3, TLS-only, retained on stack delete).
- **RenewerPolicy** — managed policy granting Route 53 DNS-01 + S3 write,
  scoped per-zone to the exact `_acme-challenge.<cert>` TXT records declared
  at deploy time. Attach to any EC2 instance role that runs `cert-renewer`.
- **ConsumerPolicy** — managed policy granting read-only access to the cert
  prefix + the two runtime SSM parameters. Attach to any EC2 instance role
  that runs `cert-consumer`.
- **Default roles + instance profiles** (`RenewerRole`, `ConsumerRole`)
  with the managed policies pre-attached, for the common case of one
  renewer host and one initial consumer host.
- **Two SSM parameters** for runtime discovery:
  - `/<stackName>/bucketName` — the S3 bucket name.
  - `/<stackName>/certMappings` — JSON array of `{ cert, zone }` entries
    (same shape as the `certs` context input).

The stack does **not** provision EC2 instances, VPCs, or Coolify — it only
creates the bucket and the IAM/SSM pieces.

## Prerequisites

- Node.js 20+
- `jq` on PATH (used by `infra.sh`)
- AWS credentials with permission to create the resources (admin is easiest
  for a first deploy; tighten later).
- The AWS account must already be CDK-bootstrapped in your target region
  (`npx cdk bootstrap` once per account/region).

## Usage — `infra.sh` wrapper (recommended)

```bash
cd infra
npm install

./infra.sh synth \
    --cert "*.sullivandigital.com.au" \
    --cert "*.internal.sullivandigital.com.au" \
    --profile sullivan-admin --region ap-southeast-2

./infra.sh deploy \
    --cert "*.sullivandigital.com.au" \
    --cert "*.internal.sullivandigital.com.au" \
    --profile sullivan-admin --region ap-southeast-2
```

### `--cert` syntax

Each `--cert` flag declares one cert/zone permission grant. Repeat the flag
for every cert you want the renewer role to be able to issue.

- `--cert "*.foo.com"` — wildcard cert. Zone inferred as `foo.com`. The IAM
  policy allows writing `_acme-challenge.foo.com` (for issuing the bare apex
  alongside the wildcard) and `_acme-challenge.*.foo.com` (for the wildcard
  itself) as TXT records in that zone.
- `--cert "coolify.foo.com"` — concrete cert. Zone inferred as `foo.com`.
  IAM allows writing `_acme-challenge.coolify.foo.com` only.
- `--cert "*.foo.com:bar.com"` — explicit zone override. Use this when the
  cert's DNS lives in a zone that isn't the obvious `strip-leading-label`
  guess (rare — typically only for subdomain delegations).

Zone inference rule: strip the leading DNS label. `*.foo.com` → `foo.com`;
`bar.foo.com` → `foo.com`.

**Wildcard semantics**: wildcards match any descendant at any depth,
matching IAM's `StringLike` operator. The runtime matcher uses the same
loose rule so issuance behaviour and IAM policy stay in agreement.

**Reserved prefix**: cert patterns cannot start with the literal string
`wildcard.` (the internal slug for `*.foo.com` would collide).

### Passthrough args

Everything not consumed by `--cert` is forwarded to `cdk` as-is:
`--profile`, `--region`, `--context foo=bar`, `--require-approval`, etc.

## Usage — calling `cdk` directly

```bash
cd infra
npm install

npx cdk deploy -c certs='[
  {"cert":"*.sullivandigital.com.au","zone":"sullivandigital.com.au"},
  {"cert":"*.internal.sullivandigital.com.au","zone":"internal.sullivandigital.com.au"}
]'
```

The `certs` context key is a JSON array of `{ cert, zone }` entries. Values
must be lowercase and free of trailing dots; validation errors are reported
up-front alongside any missing `CDK_DEFAULT_ACCOUNT`/`REGION`.

## Outputs

After a successful deploy, CloudFormation emits:

| Output                        | Use it for                                                           |
| ----------------------------- | -------------------------------------------------------------------- |
| `BucketName`                  | Informational — renewer/consumer read this from SSM.                 |
| `BucketNameParamName`         | SSM parameter name the renewer/consumer fall back to for the bucket. |
| `CertMappingsParamName`       | SSM parameter name the runtime reads for cert→zone mappings.         |
| `RenewerPolicyArn`            | Attach to any EC2 instance role that runs `cert-renewer`.            |
| `ConsumerPolicyArn`           | Attach to any EC2 instance role that runs `cert-consumer`.           |
| `RenewerInstanceProfileName`  | Default profile for the `cert-renewer` host.                         |
| `ConsumerInstanceProfileName` | Default profile for a `cert-consumer` host.                          |
| `RenewerRoleArn`              | Default renewer role (e.g. for cross-account assume-role).           |
| `ConsumerRoleArn`             | Default consumer role (same).                                        |

Once the instance profiles are attached, leave `AWS_ACCESS_KEY_ID` /
`AWS_SECRET_ACCESS_KEY` unset in the container environment. Lego and the
AWS CLI pick up credentials from IMDS automatically.

### Where the old `HostedZoneId` output went

Previously the stack emitted a single `HostedZoneId` output because exactly
one zone was in play. Now that zones are per-cert, there's no single value
to emit — the renewer reads zones from the SSM mapping table at runtime.

## Attaching an instance profile to an existing EC2 host

Console: EC2 → Instances → select instance → Actions → Security → Modify IAM
role → pick the profile name from the outputs → Update.

CLI:

```bash
aws ec2 associate-iam-instance-profile \
  --instance-id i-0123456789abcdef0 \
  --iam-instance-profile Name=<profile-name-from-outputs>
```

The change is live immediately — no instance restart required. IMDS starts
serving the new credentials within seconds.

## Teardown

```bash
./infra.sh destroy --cert "*.sullivandigital.com.au" --profile sullivan-admin
```

The bucket is retained (`RemovalPolicy.RETAIN`) and must be deleted manually
if you actually want it gone. This is deliberate — it holds your live certs.

## Policy size

Realistic cert counts (5–10) sit far below the 6,144-character managed-policy
quota. Each cert adds 1–2 values to its zone's `ChangeResourceRecordSets`
statement; if you find yourself approaching the limit you likely have wider
architectural problems than this policy.
