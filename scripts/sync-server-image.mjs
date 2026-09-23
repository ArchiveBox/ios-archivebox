// The core release coordinator calls this workflow with an immutable ArchiveBox version.
// A changed digest becomes an app source commit, so the normal release reservation
// gives it a fresh app version without manually choosing one.
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, appendFileSync, existsSync } from 'node:fs';

const version = process.env.ARCHIVEBOX_VERSION;
if (!/^\d+\.\d+\.\d+(?:rc\d+)?$/.test(version || '')) throw Error('Expected an ArchiveBox release version');
const git = (...args) => execFileSync('git', args, { encoding: 'utf8' }).trim();
const image = JSON.parse(readFileSync('ServerApp/payload/resolved-image.json', 'utf8'));
if (image.version !== version || !/^sha256:[0-9a-f]{64}$/.test(image.digest) || !/^[0-9a-f]{40}$/.test(image.revision)) {
  throw Error('The resolved image does not match the dispatched release');
}
const lockPath = 'ServerApp/core-image.json';
const lock = { version, digest: image.digest, revision: image.revision };
git('fetch', 'origin', 'main', '--tags');
git('merge', '--ff-only', 'origin/main');
const previous = existsSync(lockPath) ? JSON.parse(readFileSync(lockPath, 'utf8')) : null;
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
