#!/usr/bin/env node
// Apple packaging lives here. The WXT repository remains an ordinary browser extension.
import { execFileSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const revision = '133dcf983550da368667372c20a76a56f9d91c66'; // extension 3.3.2
const source = resolve(root, '.build/wxt-source');
const output = resolve(root, 'SafariWebExtension/Resources');
const run = (program, args, cwd = root) => execFileSync(program, args, { cwd, stdio: 'inherit' });
mkdirSync(resolve(root, '.build'), { recursive: true });
if (!existsSync(resolve(source, '.git'))) {
  run('git', ['clone', '--filter=blob:none', '--no-checkout', 'https://github.com/ArchiveBox/archivebox-browser-extension.git', source]);
}
run('git', ['fetch', 'origin', revision], source);
run('git', ['checkout', '--detach', revision], source);
run('pnpm', ['install', '--frozen-lockfile'], source);
run('pnpm', ['build:safari'], source);
// This directory contains only this script's generated build output.
rmSync(output, { recursive: true, force: true });
cpSync(resolve(source, '.output/safari-mv3'), output, { recursive: true });
cpSync(resolve(source, 'LICENSE'), resolve(output, 'UPSTREAM-LICENSE'));
const manifestPath = resolve(output, 'manifest.json');
const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
manifest.permissions = [...new Set([...manifest.permissions, 'nativeMessaging'])];
writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + '\n');
for (const page of ['popup.html', 'options.html']) {
  const path = resolve(output, page);
  const html = readFileSync(path, 'utf8');
  if (!html.includes('</head>')) throw new Error(`Unexpected WXT HTML: ${page}`);
  writeFileSync(path, html.replace('</head>', '<script defer src="/apple-connection.js"></script></head>'));
}
cpSync(resolve(root, 'SafariWebExtension/apple-connection.js'), resolve(output, 'apple-connection.js'));
console.log(`Prepared Safari extension ${manifest.version} from ${revision}.`);
