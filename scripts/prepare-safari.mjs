#!/usr/bin/env node
// Apple packaging lives here. The WXT repository remains an ordinary browser extension.
import { execFileSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const revision = 'a3929b60de96b10a871ec59c3b67036fc5604ca5'; // extension 3.3.2
const source = resolve(root, '.build/wxt-source');
const output = resolve(root, 'SafariWebExtension/Resources');
const run = (program, args, cwd = root) => execFileSync(program, args, { cwd, stdio: 'inherit' });
mkdirSync(resolve(root, '.build'), { recursive: true });
if (!existsSync(resolve(source, '.git'))) {
  run('git', ['clone', '--filter=blob:none', '--no-checkout', 'https://github.com/ArchiveBox/archivebox-browser-extension.git', source]);
}
run('git', ['fetch', 'origin', revision], source);
run('git', ['checkout', '--detach', revision], source);
// Reset only files this packaging step owns so repeated builds apply the patch once.
const patchedFiles = ['src/lib/storage.ts', 'src/lib/archivebox.ts', 'src/options/OptionsApp.tsx'];
run('git', ['restore', '--source', revision, '--', ...patchedFiles], source);
const replace = (file, before, after) => {
  const path = resolve(source, file);
  const text = readFileSync(path, 'utf8');
  if (!text.includes(before)) throw new Error(`Safari integration no longer matches upstream: ${file}`);
  writeFileSync(path, text.replace(before, after));
};
cpSync(resolve(root, 'SafariWebExtension/apple-connection.ts'), resolve(source, 'src/lib/apple-connection.ts'));
replace('src/lib/storage.ts', "import type", "import { appConnection } from './apple-connection';\nimport type");
replace('src/lib/storage.ts', "  const sync = await browser.storage.sync.get(['config_archiveBoxBaseUrl']);",
  `  const sync = await browser.storage.sync.get(['config_archiveBoxBaseUrl']);
  // Keep each server/key pair together: never mix a manual server with an app token.
  const manual = local.archivebox_server_url || local.archivebox_api_key || sync.config_archiveBoxBaseUrl;
  const connection = manual ? undefined : await appConnection();`);
replace('src/lib/storage.ts', "local.archivebox_server_url || sync.config_archiveBoxBaseUrl || ''",
  "local.archivebox_server_url || sync.config_archiveBoxBaseUrl || connection?.server || ''");
replace('src/lib/storage.ts', "archivebox_api_key: String(local.archivebox_api_key || ''),",
  "archivebox_api_key: String(manual ? local.archivebox_api_key || '' : connection?.token || ''),");
replace('src/lib/storage.ts', '  const nextConfig: Partial<ConfigState> = { ...config };',
  `  const nextConfig: Partial<ConfigState> = { ...config };
  if ('archivebox_server_url' in config || 'archivebox_api_key' in config) {
    const current = await getConfig();
    nextConfig.archivebox_server_url = config.archivebox_server_url ?? current.archivebox_server_url;
    nextConfig.archivebox_api_key = config.archivebox_api_key ??
      (nextConfig.archivebox_server_url === current.archivebox_server_url ? current.archivebox_api_key : '');
    if (!nextConfig.archivebox_server_url) {
      nextConfig.archivebox_api_key = '';
      await browser.storage.sync.remove('config_archiveBoxBaseUrl');
    }
  }`);
replace('src/lib/archivebox.ts', "  alternate.hostname = alternate.hostname.startsWith('api.') ? alternate.hostname.slice(4) : `api.${alternate.hostname}`;",
  "  alternate.hostname = ['localhost', 'api.localhost'].includes(alternate.hostname) ? 'api.archivebox.localhost' : alternate.hostname.startsWith('api.') ? alternate.hostname.slice(4) : `api.${alternate.hostname}`;");
replace('src/options/OptionsApp.tsx', '<Field label={t("ArchiveBox Server URL")}>',
  '<p className="help-text">Configure a server and key here, or leave the server blank to use the ArchiveBox app connection automatically. Browser personas are selected separately.</p><Field label={t("ArchiveBox Server URL")}>');
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
console.log(`Prepared Safari extension ${manifest.version} from ${revision}.`);
