import { readFileSync, appendFileSync } from 'node:fs';
import { createPrivateKey, sign } from 'node:crypto';
import { setTimeout } from 'node:timers/promises';

const env = process.env;
const key = createPrivateKey(readFileSync(env.ASC_KEY_PATH));
const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
async function api(path, method = 'GET', body) {
  // Short-lived JWTs are regenerated while Apple processes the uploaded builds.
  const now = Math.floor(Date.now() / 1000);
  const payload = `${encode({ alg: 'ES256', kid: env.ASC_KEY_ID, typ: 'JWT' })}.${encode({ iss: env.ASC_ISSUER_ID, iat: now, exp: now + 600, aud: 'appstoreconnect-v1' })}`;
  const token = `${payload}.${sign('sha256', Buffer.from(payload), { key, dsaEncoding: 'ieee-p1363' }).toString('base64url')}`;
  const response = await fetch(`https://api.appstoreconnect.apple.com/v1/${path}`, {
    method, redirect: 'error', signal: AbortSignal.timeout(30_000),
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (!response.ok) throw new Error(`${method} ${path}: ${response.status} ${await response.text()}`);
  return response.status === 204 ? undefined : response.json();
}

const group = (await api(`betaGroups/${env.ASC_GROUP_ID}?include=app`)).data;
if (!group.attributes.isInternalGroup || group.relationships.app.data.id !== env.ASC_APP_ID) {
  throw new Error('Configured group must be an internal group belonging to ArchiveBox.');
}
const pending = new Set(env.RELEASE_PLATFORM === 'both' ? ['IOS', 'MAC_OS'] : [env.RELEASE_PLATFORM === 'iOS' ? 'IOS' : 'MAC_OS']);
const deadline = Date.now() + 60 * 60 * 1000;
while (pending.size && Date.now() < deadline) {
  const query = new URLSearchParams({ 'filter[app]': env.ASC_APP_ID, 'filter[version]': env.RELEASE_BUILD, include: 'preReleaseVersion', limit: '20' });
  const result = await api(`builds?${query}`);
  for (const build of result.data) {
    const version = result.included?.find(item => item.type === 'preReleaseVersions' && item.id === build.relationships.preReleaseVersion.data.id)?.attributes;
    if (!version || !pending.has(version.platform) || version.version !== env.RELEASE_VERSION) continue;
    const state = build.attributes.processingState;
    if (state === 'FAILED' || state === 'INVALID') throw new Error(`${version.platform} build processing ${state}`);
    if (state !== 'VALID') continue;
    // This client uses only platform HTTPS/TLS; it ships no custom cryptography.
    if (build.attributes.usesNonExemptEncryption == null) {
      await api(`builds/${build.id}`, 'PATCH', { data: { type: 'builds', id: build.id, attributes: { usesNonExemptEncryption: false } } });
    }
    await api(`betaGroups/${env.ASC_GROUP_ID}/relationships/builds`, 'POST', { data: [{ type: 'builds', id: build.id }] });
    let page = `betaGroups/${env.ASC_GROUP_ID}/relationships/builds?limit=200`;
    let assigned = false;
    while (page && !assigned) {
      const members = await api(page);
      assigned = members.data.some(item => item.id === build.id);
      const next = members.links?.next;
      if (next && !next.startsWith('https://api.appstoreconnect.apple.com/v1/')) throw new Error('Unexpected API pagination origin.');
      page = next?.slice('https://api.appstoreconnect.apple.com/v1/'.length);
    }
    if (!assigned) throw new Error('TestFlight group assignment was not confirmed.');
    const message = `${version.platform} ${env.RELEASE_VERSION} (${env.RELEASE_BUILD}) assigned to ${group.attributes.name}`;
    console.log(message);
    if (env.GITHUB_STEP_SUMMARY) appendFileSync(env.GITHUB_STEP_SUMMARY, `${message}\n\n`);
    pending.delete(version.platform);
  }
  if (pending.size) {
    console.log(`Waiting for Apple processing: ${[...pending].join(', ')}`);
    await setTimeout(60_000);
  }
}
if (pending.size) throw new Error(`Apple processing did not finish within one hour: ${[...pending].join(', ')}. Check App Store Connect before uploading again.`);
