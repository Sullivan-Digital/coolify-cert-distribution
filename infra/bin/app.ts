#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { CertDistributionStack, CertConfig } from '../lib/cert-distribution-stack';

const app = new cdk.App();

// Required context args:
//   -c certs='[{"cert":"*.foo.com","zone":"foo.com"}, ...]'
//     JSON array of { cert, zone } entries. Each entry is a *permission grant*:
//     the renewer role may write _acme-challenge.<cert> TXT records in <zone>.
//     Patterns may be concrete (coolify.foo.com) or wildcards (*.foo.com);
//     wildcards mean "any descendant at any depth", matching IAM's StringLike
//     semantics. Prefer using ./infra.sh which builds this array for you.
//
// Optional:
//   -c stackName=...   override default stack name
const stackName = (app.node.tryGetContext('stackName') as string | undefined) ?? 'CertDistributionStack';
const certsRaw = app.node.tryGetContext('certs') as string | unknown;

// HostedZone.fromLookup() needs an explicit account/region. The CDK CLI
// populates CDK_DEFAULT_ACCOUNT/REGION from your active AWS credentials.
const account = process.env.CDK_DEFAULT_ACCOUNT;
const region = process.env.CDK_DEFAULT_REGION;

// Collect every missing/invalid input up front so the user fixes them all at
// once, rather than running, fixing one, running again, ad nauseam.
const missing: string[] = [];
let certs: CertConfig[] = [];

if (certsRaw === undefined || certsRaw === null || certsRaw === '') {
  missing.push('  -c certs=<json-array>                   (list of { cert, zone } entries; prefer ./infra.sh)');
} else {
  try {
    const parsed = typeof certsRaw === 'string' ? JSON.parse(certsRaw) : certsRaw;
    certs = validateCerts(parsed);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    missing.push(`  -c certs=<json-array>                   (invalid: ${msg})`);
  }
}

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
  certs,
});

function validateCerts(value: unknown): CertConfig[] {
  if (!Array.isArray(value)) {
    throw new Error('certs must be a JSON array');
  }
  if (value.length === 0) {
    throw new Error('certs must not be empty');
  }
  const result: CertConfig[] = [];
  value.forEach((entry, i) => {
    if (entry === null || typeof entry !== 'object' || Array.isArray(entry)) {
      throw new Error(`certs[${i}] must be an object`);
    }
    const obj = entry as Record<string, unknown>;
    const cert = obj.cert;
    const zone = obj.zone;
    if (typeof cert !== 'string' || cert.length === 0) {
      throw new Error(`certs[${i}].cert must be a non-empty string`);
    }
    if (typeof zone !== 'string' || zone.length === 0) {
      throw new Error(`certs[${i}].zone must be a non-empty string`);
    }
    if (cert !== cert.toLowerCase()) {
      throw new Error(`certs[${i}].cert must be lowercase: '${cert}'`);
    }
    if (zone !== zone.toLowerCase()) {
      throw new Error(`certs[${i}].zone must be lowercase: '${zone}'`);
    }
    if (cert.endsWith('.')) {
      throw new Error(`certs[${i}].cert must not end with a dot: '${cert}'`);
    }
    if (zone.endsWith('.')) {
      throw new Error(`certs[${i}].zone must not end with a dot: '${zone}'`);
    }
    result.push({ cert, zone });
  });
  return result;
}
