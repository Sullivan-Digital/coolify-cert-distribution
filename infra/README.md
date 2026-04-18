# infra

AWS CDK project that provisions the shared infrastructure for `cert-renewer`
and `cert-consumer`:

- **S3 bucket** (private, SSE-S3, TLS-only, retained on stack delete)
- **RenewerRole** — EC2 instance role with Route 53 DNS-01 + S3 write, scoped
  to a single `_acme-challenge.<certDomain>` TXT record
- **ConsumerRole** — EC2 instance role with read-only access to the cert
  prefix
- **Instance profiles** for both roles, ready to attach to existing EC2 hosts

The stack does **not** provision EC2 instances, VPCs, or Coolify — it only
creates the bucket and the IAM pieces. Attach the instance profiles to the
EC2 hosts that already run your Coolify proxies.

## Prerequisites

- Node.js 20+
- AWS credentials with permission to create the resources (admin is easiest
  for a first deploy; tighten later).
- The AWS account must already be CDK-bootstrapped in your target region
  (`npx cdk bootstrap` once per account/region).

## Usage

```bash
cd infra
npm install

# One-time per account/region if not already done:
npx cdk bootstrap -c zoneName=example.com -c certDomain=internal.example.com

# Diff against deployed stack:
npx cdk diff \
  -c zoneName=example.com \
  -c certDomain=internal.example.com

# Deploy:
npx cdk deploy \
  -c zoneName=example.com \
  -c certDomain=internal.example.com
```

`zoneName` is the Route 53 hosted zone that owns the parent domain. It is
**looked up**, not created — the zone must already exist in the target
account. `certDomain` is the apex of the wildcard cert; the ACME challenge
record the renewer writes will be `_acme-challenge.<certDomain>`.

Example: if your wildcard is `*.internal.example.com`, pass
`-c zoneName=example.com -c certDomain=internal.example.com`.

## Outputs

After a successful deploy, CloudFormation emits:

| Output                        | Use it for                                                 |
| ----------------------------- | ---------------------------------------------------------- |
| `BucketName`                  | `S3_BUCKET` env on both renewer and consumer               |
| `HostedZoneId`                | `AWS_HOSTED_ZONE_ID` env on the renewer                    |
| `RenewerInstanceProfileName`  | Attach to the EC2 host running `cert-renewer`              |
| `ConsumerInstanceProfileName` | Attach to every EC2 host running `cert-consumer`           |
| `RenewerRoleArn`              | Reference if you need cross-account assume-role later      |
| `ConsumerRoleArn`             | Same                                                       |

Once the instance profiles are attached, you can leave `AWS_ACCESS_KEY_ID`
and `AWS_SECRET_ACCESS_KEY` **unset** in the container environment — both
`lego` and the AWS CLI pick up credentials from IMDS automatically.

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
npx cdk destroy -c zoneName=example.com -c certDomain=internal.example.com
```

The bucket is retained (`RemovalPolicy.RETAIN`) and must be deleted manually
if you actually want it gone. This is deliberate — it holds your live cert.
