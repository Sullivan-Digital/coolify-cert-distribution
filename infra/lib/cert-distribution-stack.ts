import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as route53 from 'aws-cdk-lib/aws-route53';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as ssm from 'aws-cdk-lib/aws-ssm';

export interface CertConfig {
  /** Cert pattern (e.g. *.foo.com or coolify.foo.com). Lowercase, no trailing dot. */
  readonly cert: string;
  /** Route 53 hosted zone name (e.g. foo.com). Lowercase, no trailing dot. */
  readonly zone: string;
}

export interface CertDistributionStackProps extends cdk.StackProps {
  /** Cert→zone permission grants. See CertConfig. */
  readonly certs: CertConfig[];
  /** Key prefix inside the bucket. Each cert lives at <s3Prefix>/<slug>/. */
  readonly s3Prefix?: string;
}

export class CertDistributionStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: CertDistributionStackProps) {
    super(scope, id, props);

    const s3Prefix = props.s3Prefix ?? 'certs';

    // --- S3 bucket --------------------------------------------------------
    const bucket = new s3.Bucket(this, 'CertBucket', {
      encryption: s3.BucketEncryption.S3_MANAGED,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      enforceSSL: true,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });

    const prefixObjectsArn = bucket.arnForObjects(`${s3Prefix}/*`);

    // --- Route 53 lookups -------------------------------------------------
    // One fromLookup per *unique* zone (cached in cdk.context.json after the
    // first synth).
    const uniqueZones = Array.from(new Set(props.certs.map((c) => c.zone)));
    const hostedZoneMap = new Map<string, route53.IHostedZone>();
    for (const zoneName of uniqueZones) {
      hostedZoneMap.set(
        zoneName,
        route53.HostedZone.fromLookup(this, `HostedZone_${slugify(zoneName)}`, {
          domainName: zoneName,
        }),
      );
    }

    // --- Renewer policy ---------------------------------------------------
    // Global Route 53 plumbing (same as before).
    const route53GlobalStatements = [
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
    ];

    // One ListResourceRecordSets statement per zone.
    const route53ReadStatements = uniqueZones.map(
      (zoneName) =>
        new iam.PolicyStatement({
          sid: `Route53ReadZone${slugifyForSid(zoneName)}`,
          actions: ['route53:ListResourceRecordSets'],
          resources: [hostedZoneMap.get(zoneName)!.hostedZoneArn],
        }),
    );

    // One ChangeResourceRecordSets statement per zone, with
    // ForAllValues:StringLike and expanded _acme-challenge.* record names.
    const certsByZone = new Map<string, CertConfig[]>();
    for (const c of props.certs) {
      const list = certsByZone.get(c.zone) ?? [];
      list.push(c);
      certsByZone.set(c.zone, list);
    }

    const route53WriteStatements = Array.from(certsByZone.entries()).map(
      ([zoneName, certsInZone]) => {
        const recordNames: string[] = [];
        for (const c of certsInZone) {
          if (c.cert.startsWith('*.')) {
            // Bare domain (lets us issue foo.com alongside *.foo.com).
            recordNames.push(`_acme-challenge.${c.cert.slice(2)}`);
            // Wildcard form (StringLike matches descendants at any depth).
            recordNames.push(`_acme-challenge.${c.cert}`);
          } else {
            recordNames.push(`_acme-challenge.${c.cert}`);
          }
        }
        // De-dupe in case two certs in the same zone expand to the same name.
        const dedupedRecordNames = Array.from(new Set(recordNames));
        return new iam.PolicyStatement({
          sid: `Route53Write${slugifyForSid(zoneName)}`,
          actions: ['route53:ChangeResourceRecordSets'],
          resources: [hostedZoneMap.get(zoneName)!.hostedZoneArn],
          conditions: {
            'ForAllValues:StringLike': {
              'route53:ChangeResourceRecordSetsNormalizedRecordNames': dedupedRecordNames,
              'route53:ChangeResourceRecordSetsRecordTypes': ['TXT'],
            },
          },
        });
      },
    );

    // --- SSM parameters (runtime discovery) -------------------------------
    // Renewer + consumer read these at startup to find the bucket and the
    // cert→zone mapping table.
    const bucketNameParam = new ssm.StringParameter(this, 'BucketNameParam', {
      parameterName: `/${this.stackName}/bucketName`,
      description: 'S3 bucket holding the distributed certs (cert-distribution).',
      stringValue: bucket.bucketName,
      tier: ssm.ParameterTier.STANDARD,
    });

    const certMappingsParam = new ssm.StringParameter(this, 'CertMappingsParam', {
      parameterName: `/${this.stackName}/certMappings`,
      description: 'JSON array of { cert, zone } mappings (cert-distribution).',
      stringValue: JSON.stringify(props.certs),
      tier: ssm.ParameterTier.STANDARD,
    });

    const ssmReadStatement = new iam.PolicyStatement({
      sid: 'SsmReadCertMappings',
      actions: ['ssm:GetParameter'],
      resources: [bucketNameParam.parameterArn, certMappingsParam.parameterArn],
    });

    // --- Renewer managed policy -------------------------------------------
    const renewerPolicy = new iam.ManagedPolicy(this, 'RenewerPolicy', {
      description: 'Cert-renewer permissions: Route53 DNS-01 + S3 cert write',
      statements: [
        ...route53GlobalStatements,
        ...route53ReadStatements,
        ...route53WriteStatements,
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
        ssmReadStatement,
      ],
    });

    // --- Consumer managed policy ------------------------------------------
    const consumerPolicy = new iam.ManagedPolicy(this, 'ConsumerPolicy', {
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
        ssmReadStatement,
      ],
    });

    // --- Default roles ----------------------------------------------------
    const renewerRole = new iam.Role(this, 'RenewerRole', {
      assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
      description: 'Default instance role for cert-renewer',
      managedPolicies: [renewerPolicy],
    });

    const consumerRole = new iam.Role(this, 'ConsumerRole', {
      assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
      description: 'Default instance role for cert-consumer',
      managedPolicies: [consumerPolicy],
    });

    // --- Instance profiles ------------------------------------------------
    const renewerProfile = new iam.CfnInstanceProfile(this, 'RenewerInstanceProfile', {
      roles: [renewerRole.roleName],
    });

    const consumerProfile = new iam.CfnInstanceProfile(this, 'ConsumerInstanceProfile', {
      roles: [consumerRole.roleName],
    });

    // --- Outputs ----------------------------------------------------------
    new cdk.CfnOutput(this, 'BucketName', {
      value: bucket.bucketName,
      description: 'S3 bucket name (also published at /<stack>/bucketName in SSM).',
    });
    new cdk.CfnOutput(this, 'BucketArn', { value: bucket.bucketArn });

    new cdk.CfnOutput(this, 'BucketNameParamName', {
      value: bucketNameParam.parameterName,
      description: 'SSM parameter that publishes the bucket name.',
    });
    new cdk.CfnOutput(this, 'CertMappingsParamName', {
      value: certMappingsParam.parameterName,
      description: 'SSM parameter that publishes the cert→zone mappings JSON.',
    });

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
  }
}

// For CDK construct IDs: replace anything non-alphanumeric with an underscore.
function slugify(s: string): string {
  return s.replace(/[^A-Za-z0-9]/g, '_');
}

// For IAM statement Sids: alphanumerics only, no underscores (AWS requires
// Sid to match [A-Za-z0-9]).
function slugifyForSid(s: string): string {
  return s.replace(/[^A-Za-z0-9]/g, '');
}
