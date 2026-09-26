// A changed stable image becomes an app source commit, so the normal release
// reservation gives it a fresh app version without manually choosing one.
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, appendFileSync, existsSync } from 'node:fs';

const git = (...args) => execFileSync('git', args, { encoding: 'utf8' }).trim();
const image = JSON.parse(readFileSync('ServerApp/payload/resolved-image.json', 'utf8'));
const version = image.version;
if (!/^\d+\.\d+\.\d+$/.test(version || '')) throw Error('Expected a published stable ArchiveBox image');
if (!/^sha256:[0-9a-f]{64}$/.test(image.digest) || !/^[0-9a-f]{40}$/.test(image.revision)) {
  throw Error('The resolved image is missing its verified digest or source revision');
}
const lockPath = 'ServerApp/core-image.json';
const lock = { version, digest: image.digest, revision: image.revision };
git('fetch', 'origin', 'main', '--tags');
git('merge', '--ff-only', 'origin/main');
const previous = existsSync(lockPath) ? JSON.parse(readFileSync(lockPath, 'utf8')) : null;
if (previous && /^\d+\.\d+\.\d+$/.test(previous.version)) {
  const currentParts = version.split('.').map(Number);
  const previousParts = previous.version.split('.').map(Number);
  for (let i = 0; i < currentParts.length; i++) {
    if (currentParts[i] < previousParts[i]) throw Error(`Refusing to downgrade bundled ArchiveBox from ${previous.version} to ${version}`);
    if (currentParts[i] > previousParts[i]) break;
  }
}
if (previous?.version === version && previous.digest !== image.digest) {
  throw Error(`Published ArchiveBox ${version} changed its image digest`);
}
if (JSON.stringify(previous) !== JSON.stringify(lock)) {
  writeFileSync(lockPath, `${JSON.stringify(lock, null, 2)}\n`);
  git('config', 'user.name', 'ArchiveBox Release Bot');
  git('config', 'user.email', 'release-bot@archivebox.io');
  git('add', lockPath);
  git('commit', '-m', `Update bundled ArchiveBox image to ${version}`);
  git('push', 'origin', 'HEAD:refs/heads/main');
}
const sha = git('rev-parse', 'HEAD');
if (process.env.GITHUB_ENV) appendFileSync(process.env.GITHUB_ENV, `RELEASE_SOURCE_SHA=${sha}\n`);
console.log(`ArchiveBox Server image ${version} ${image.digest}; source ${sha}`);
