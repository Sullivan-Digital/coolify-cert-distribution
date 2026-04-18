#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { CertDistributionStack } from '../lib/cert-distribution-stack';

const app = new cdk.App();

// Required context args:
//   -c zoneName=example.com         Route 53 hosted zone name (parent domain)
//   -c certDomain=internal.example.com  Apex of the wildcard cert (ACME challenge
//                                       lands at _acme-challenge.<certDomain>)
//
// Optional:
//   -c stackName=...   override default stack name
const zoneName = app.node.tryGetContext('zoneName') as string | undefined;
const certDomain = app.node.tryGetContext('certDomain') as string | undefined;
const stackName = (app.node.tryGetContext('stackName') as string | undefined) ?? 'CertDistributionStack';

// HostedZone.fromLookup() needs an explicit account/region. The CDK CLI
// populates CDK_DEFAULT_ACCOUNT/REGION from your active AWS credentials.
const account = process.env.CDK_DEFAULT_ACCOUNT;
const region = process.env.CDK_DEFAULT_REGION;

// Collect every missing input up front so the user fixes them all at once,
// rather than running, fixing one, running again, ad nauseam.
const missing: string[] = [];
if (!zoneName) missing.push('  -c zoneName=<route53-zone-name>        (Route 53 hosted zone, parent domain)');
if (!certDomain) missing.push('  -c certDomain=<cert-apex-domain>        (apex of the wildcard cert)');
if (!account) missing.push('  env CDK_DEFAULT_ACCOUNT                 (run `aws sso login` or set AWS_PROFILE)');
if (!region) missing.push('  env CDK_DEFAULT_REGION                  (configure a default region in your AWS profile)');

if (missing.length > 0) {
  throw new Error(
    `Missing required configuration:\n${missing.join('\n')}`,
  );
}
const env = { account: account!, region: region! };

new CertDistributionStack(app, stackName, {
  env,
  zoneName: zoneName!,
  certDomain: certDomain!,
});
