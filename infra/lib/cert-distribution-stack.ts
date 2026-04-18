import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as route53 from 'aws-cdk-lib/aws-route53';
import * as s3 from 'aws-cdk-lib/aws-s3';

export interface CertDistributionStackProps extends cdk.StackProps {
  /** Route 53 hosted zone name (e.g. example.com) — looked up, not created. */
  readonly zoneName: string;
  /** Cert apex domain (e.g. internal.example.com). Used for the ACME
   *  challenge scoping: _acme-challenge.<certDomain>. */
  readonly certDomain: string;
  /** Key prefix inside the bucket. Must match S3_PREFIX in the scripts. */
  readonly s3Prefix?: string;
}

export class CertDistributionStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: CertDistributionStackProps) {
    super(scope, id, props);

    const s3Prefix = props.s3Prefix ?? 'certs/wildcard';

    // --- S3 bucket --------------------------------------------------------
    // Block-all-public-access + SSE-S3 are the defaults for Bucket in CDK.
    // Versioning off per project choice; RETAIN so cert history survives
    // stack deletion.
    const bucket = new s3.Bucket(this, 'CertBucket', {
      encryption: s3.BucketEncryption.S3_MANAGED,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      enforceSSL: true,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });

    // Convenience ARNs used by both roles.
    const prefixObjectsArn = bucket.arnForObjects(`${s3Prefix}/*`);

    // --- Route 53 lookup --------------------------------------------------
    // Looked up at synth time; result is cached in cdk.context.json.
    const hostedZone = route53.HostedZone.fromLookup(this, 'HostedZone', {
      domainName: props.zoneName,
    });

    // --- Renewer role -----------------------------------------------------
    // Attach this to the EC2 instance running the cert-renewer container.
    // Mirrors the least-privilege policy documented in renewer/README.md.
    const renewerRole = new iam.Role(this, 'RenewerRole', {
      assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
      description: 'Instance role for cert-renewer: Route53 DNS-01 + S3 write',
    });

    renewerRole.addToPolicy(new iam.PolicyStatement({
      sid: 'Route53AcmeChallenge',
      actions: ['route53:GetChange'],
      resources: ['arn:aws:route53:::change/*'],
    }));

    renewerRole.addToPolicy(new iam.PolicyStatement({
      sid: 'Route53ListZones',
      actions: ['route53:ListHostedZonesByName'],
      resources: ['*'],
    }));

    renewerRole.addToPolicy(new iam.PolicyStatement({
      sid: 'Route53ReadZone',
      actions: ['route53:ListResourceRecordSets'],
      resources: [hostedZone.hostedZoneArn],
    }));

    // Scope writes to the single _acme-challenge TXT record for certDomain.
    // If this role leaks, attacker can't rewrite MX/A/other records.
    renewerRole.addToPolicy(new iam.PolicyStatement({
      sid: 'Route53WriteChallengeOnly',
      actions: ['route53:ChangeResourceRecordSets'],
      resources: [hostedZone.hostedZoneArn],
      conditions: {
        'ForAllValues:StringEquals': {
          'route53:ChangeResourceRecordSetsNormalizedRecordNames': [
            `_acme-challenge.${props.certDomain}`,
          ],
          'route53:ChangeResourceRecordSetsRecordTypes': ['TXT'],
        },
      },
    }));

    renewerRole.addToPolicy(new iam.PolicyStatement({
      sid: 'S3WriteCerts',
      actions: [
        's3:PutObject',
        's3:PutObjectAcl',
        's3:GetObject',
        's3:DeleteObject',
      ],
      resources: [prefixObjectsArn],
    }));

    renewerRole.addToPolicy(new iam.PolicyStatement({
      sid: 'S3ListBucket',
      actions: ['s3:ListBucket'],
      resources: [bucket.bucketArn],
      conditions: {
        StringLike: { 's3:prefix': [`${s3Prefix}/*`] },
      },
    }));

    // --- Consumer role ----------------------------------------------------
    // Attach this to EVERY EC2 instance running a cert-consumer container.
    // Read-only access to the cert prefix. Mirrors consumer/README.md.
    const consumerRole = new iam.Role(this, 'ConsumerRole', {
      assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
      description: 'Instance role for cert-consumer: read-only S3 cert prefix',
    });

    consumerRole.addToPolicy(new iam.PolicyStatement({
      sid: 'S3ReadCerts',
      actions: ['s3:GetObject'],
      resources: [prefixObjectsArn],
    }));

    consumerRole.addToPolicy(new iam.PolicyStatement({
      sid: 'S3ListBucketPrefix',
      actions: ['s3:ListBucket'],
      resources: [bucket.bucketArn],
      conditions: {
        StringLike: { 's3:prefix': [`${s3Prefix}/*`] },
      },
    }));

    // --- Lock down data access to the two roles ---------------------------
    // Without this, any principal in the AWS account whose identity policy
    // grants s3 actions (e.g. AdministratorAccess) could read wildcard.key.
    // The private key is the real blast radius here: whoever holds it can
    // MITM anything behind *.<certDomain>. So we explicitly deny data ops
    // to every principal except the two role ARNs.
    //
    // Scoped to DATA actions only — management actions like PutBucketPolicy
    // remain governed by identity policies, so IAM admins can still manage
    // the bucket and `cdk deploy` keeps working without special-casing.
    bucket.addToResourcePolicy(new iam.PolicyStatement({
      sid: 'DenyDataAccessExceptRoles',
      effect: iam.Effect.DENY,
      principals: [new iam.AnyPrincipal()],
      actions: [
        's3:GetObject',
        's3:GetObjectVersion',
        's3:GetObjectAcl',
        's3:GetObjectVersionAcl',
        's3:PutObject',
        's3:PutObjectAcl',
        's3:DeleteObject',
        's3:DeleteObjectVersion',
        's3:ListBucket',
        's3:ListBucketVersions',
      ],
      resources: [bucket.bucketArn, bucket.arnForObjects('*')],
      conditions: {
        StringNotEquals: {
          'aws:PrincipalArn': [renewerRole.roleArn, consumerRole.roleArn],
        },
      },
    }));

    // --- Instance profiles ------------------------------------------------
    // CDK creates these implicitly when you pass a role to ec2.Instance, but
    // since the EC2 hosts are provisioned outside this stack (Coolify), we
    // emit the profiles explicitly so they can be attached via the console
    // or a launch template.
    const renewerProfile = new iam.CfnInstanceProfile(this, 'RenewerInstanceProfile', {
      roles: [renewerRole.roleName],
    });

    const consumerProfile = new iam.CfnInstanceProfile(this, 'ConsumerInstanceProfile', {
      roles: [consumerRole.roleName],
    });

    // --- Outputs ----------------------------------------------------------
    new cdk.CfnOutput(this, 'BucketName', {
      value: bucket.bucketName,
      description: 'Set this as S3_BUCKET on both renewer and consumer.',
    });
    new cdk.CfnOutput(this, 'BucketArn', { value: bucket.bucketArn });

    new cdk.CfnOutput(this, 'RenewerRoleArn', { value: renewerRole.roleArn });
    new cdk.CfnOutput(this, 'RenewerInstanceProfileName', {
      value: renewerProfile.ref,
      description: 'Attach to the EC2 instance running cert-renewer.',
    });

    new cdk.CfnOutput(this, 'ConsumerRoleArn', { value: consumerRole.roleArn });
    new cdk.CfnOutput(this, 'ConsumerInstanceProfileName', {
      value: consumerProfile.ref,
      description: 'Attach to every EC2 instance running cert-consumer.',
    });

    new cdk.CfnOutput(this, 'HostedZoneId', {
      value: hostedZone.hostedZoneId,
      description: 'Set this as AWS_HOSTED_ZONE_ID on the renewer.',
    });
  }
}
