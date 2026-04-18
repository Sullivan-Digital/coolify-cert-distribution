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

    // --- Renewer managed policy -------------------------------------------
    // Standalone managed policy so it can be attached to any EC2 instance
    // role that runs a cert-renewer container, without having to re-declare
    // the permissions. Mirrors the least-privilege policy in renewer/README.md.
    const renewerPolicy = new iam.ManagedPolicy(this, 'CertDistributionRenewerPolicy', {
      description: 'Cert-renewer permissions: Route53 DNS-01 + S3 cert write',
      statements: [
        new iam.PolicyStatement({
          sid: 'Route53AcmeChallenge',
          actions: ['route53:GetChange'],
          resources: ['arn:aws:route53:::change/*'],
        }),
        new iam.PolicyStatement({
          sid: 'Route53ListZones',
          actions: ['route53:ListHostedZonesByName'],
          resources: ['*'],
        }),
        new iam.PolicyStatement({
          sid: 'Route53ReadZone',
          actions: ['route53:ListResourceRecordSets'],
          resources: [hostedZone.hostedZoneArn],
        }),
        // Scope writes to the single _acme-challenge TXT record for certDomain.
        // If this policy leaks onto a role that's then compromised, the attacker
        // still can't rewrite MX/A/other records.
        new iam.PolicyStatement({
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
        }),
        new iam.PolicyStatement({
          sid: 'S3WriteCerts',
          actions: [
            's3:PutObject',
            's3:PutObjectAcl',
            's3:GetObject',
            's3:DeleteObject',
          ],
          resources: [prefixObjectsArn],
        }),
        new iam.PolicyStatement({
          sid: 'S3ListBucket',
          actions: ['s3:ListBucket'],
          resources: [bucket.bucketArn],
          conditions: {
            StringLike: { 's3:prefix': [`${s3Prefix}/*`] },
          },
        }),
      ],
    });

    // --- Consumer managed policy ------------------------------------------
    // Attach to any EC2 instance role that runs a cert-consumer container.
    // Read-only access to the cert prefix. Mirrors consumer/README.md.
    const consumerPolicy = new iam.ManagedPolicy(this, 'CertDistributionConsumerPolicy', {
      description: 'Cert-consumer permissions: read-only S3 cert prefix',
      statements: [
        new iam.PolicyStatement({
          sid: 'S3ReadCerts',
          actions: ['s3:GetObject'],
          resources: [prefixObjectsArn],
        }),
        new iam.PolicyStatement({
          sid: 'S3ListBucketPrefix',
          actions: ['s3:ListBucket'],
          resources: [bucket.bucketArn],
          conditions: {
            StringLike: { 's3:prefix': [`${s3Prefix}/*`] },
          },
        }),
      ],
    });

    // --- Default roles ----------------------------------------------------
    // Convenience roles pre-attached to the managed policies above, for the
    // common case of one renewer host and one initial consumer host. For
    // additional servers, mint your own role and attach the managed policy.
    const renewerRole = new iam.Role(this, 'CertDistributionRenewerRole', {
      assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
      description: 'Default instance role for cert-renewer',
      managedPolicies: [renewerPolicy],
    });

    const consumerRole = new iam.Role(this, 'CertDistributionConsumerRole', {
      assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
      description: 'Default instance role for cert-consumer',
      managedPolicies: [consumerPolicy],
    });

    // --- Instance profiles ------------------------------------------------
    // CDK creates these implicitly when you pass a role to ec2.Instance, but
    // since the EC2 hosts are provisioned outside this stack (Coolify), we
    // emit the profiles explicitly so they can be attached via the console
    // or a launch template.
    const renewerProfile = new iam.CfnInstanceProfile(this, 'CertDistributionRenewerInstanceProfile', {
      roles: [renewerRole.roleName],
    });

    const consumerProfile = new iam.CfnInstanceProfile(this, 'CertDistributionConsumerInstanceProfile', {
      roles: [consumerRole.roleName],
    });

    // --- Outputs ----------------------------------------------------------
    new cdk.CfnOutput(this, 'BucketName', {
      value: bucket.bucketName,
      description: 'Set this as S3_BUCKET on both renewer and consumer.',
    });
    new cdk.CfnOutput(this, 'BucketArn', { value: bucket.bucketArn });

    new cdk.CfnOutput(this, 'RenewerPolicyArn', {
      value: renewerPolicy.managedPolicyArn,
      description: 'Attach to any EC2 instance role that runs cert-renewer.',
    });
    new cdk.CfnOutput(this, 'RenewerRoleArn', { value: renewerRole.roleArn });
    new cdk.CfnOutput(this, 'RenewerInstanceProfileName', {
      value: renewerProfile.ref,
      description: 'Default instance profile for the cert-renewer host.',
    });

    new cdk.CfnOutput(this, 'ConsumerPolicyArn', {
      value: consumerPolicy.managedPolicyArn,
      description: 'Attach to any EC2 instance role that runs cert-consumer.',
    });
    new cdk.CfnOutput(this, 'ConsumerRoleArn', { value: consumerRole.roleArn });
    new cdk.CfnOutput(this, 'ConsumerInstanceProfileName', {
      value: consumerProfile.ref,
      description: 'Default instance profile for a cert-consumer host.',
    });

    new cdk.CfnOutput(this, 'HostedZoneId', {
      value: hostedZone.hostedZoneId,
      description: 'Set this as AWS_HOSTED_ZONE_ID on the renewer.',
    });
  }
}
