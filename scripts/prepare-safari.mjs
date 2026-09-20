#!/usr/bin/env node
// Apple packaging lives here; all browser code and manifest permissions live in WXT.
import { execFileSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, readFileSync, rmSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const revision = 'bc2f738f3cf45dff8289ebec1585ee166732a48d'; // Safari export imports + popup sizing; includes OPFS upload fix
const source = resolve(process.env.ARCHIVEBOX_EXTENSION_SOURCE || resolve(root, '../archivebox-browser-extension'));
const output = resolve(root, 'SafariWebExtension/Resources');
const run = (program, args, cwd = root) => execFileSync(program, args, { cwd, stdio: 'inherit' });
if (!existsSync(source)) {
  // A fresh checkout (including CI) gets a sibling extension repo, never a fork
  // inside this app. Do not switch branches or reset an existing developer checkout.
  mkdirSync(dirname(source), { recursive: true });
  run('git', ['clone', '--filter=blob:none', '--no-checkout', 'https://github.com/ArchiveBox/archivebox-browser-extension.git', source]);
  run('git', ['checkout', '--detach', revision], source);
}
const head = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: source, encoding: 'utf8' }).trim();
const dirty = execFileSync('git', ['status', '--porcelain'], { cwd: source, encoding: 'utf8' }).trim();
if (!process.env.ARCHIVEBOX_EXTENSION_SOURCE && (head !== revision || dirty)) {
  throw new Error(`Expected clean extension revision ${revision} at ${source}. Set ARCHIVEBOX_EXTENSION_SOURCE explicitly to build a development checkout.`);
}
run('pnpm', ['install', '--frozen-lockfile'], source);
run('pnpm', ['build:safari'], source);
// Only generated resources are copied. No source patches or manifest rewrites.
rmSync(output, { recursive: true, force: true });
cpSync(resolve(source, '.output/safari-mv3'), output, { recursive: true });
cpSync(resolve(source, 'LICENSE'), resolve(output, 'UPSTREAM-LICENSE'));
const manifest = JSON.parse(readFileSync(resolve(output, 'manifest.json'), 'utf8'));
console.log(`Prepared Safari extension ${manifest.version} from ${head}${dirty ? ' (development changes)' : ''}.`);
