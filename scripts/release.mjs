// Reserve one immutable source/version pair, then publish only its verified binaries.
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, appendFileSync } from 'node:fs';
const run = (cmd, args) => execFileSync(cmd, args, { encoding: 'utf8', stdio: ['pipe', 'pipe', 'inherit'] }).trim();
const git = (...args) => run('git', args);
const repo = process.env.GITHUB_REPOSITORY || 'ArchiveBox/ios-archivebox';
const gh = (...args) => run('gh', args);
const output = values => {
  console.log(JSON.stringify(values));
  if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, Object.entries(values).map(([k,v]) => `${k}=${v}\n`).join(''));
};
const versionPattern = /^v(\d+)\.(\d+)\.(\d+)$/;
const compare = (a,b) => { for (let i=0;i<3;i++) { const d=Number(a[i])-Number(b[i]); if(d) return d; } return 0; };
const releases = JSON.parse(gh('api', '--paginate', '--slurp', `repos/${repo}/releases?per_page=100`)).flat()
  .filter(r => !r.draft && versionPattern.test(r.tag_name))
  .sort((a,b) => compare(b.tag_name.match(versionPattern).slice(1), a.tag_name.match(versionPattern).slice(1)));
const previous = releases[0]?.tag_name;
if (process.argv[2] === 'prepare') {
  git('fetch', 'origin', 'main', '--tags');
  let source = process.env.GITHUB_SHA || git('rev-parse','HEAD');
  const reserved=JSON.parse(readFileSync('release.json'));
  // A manual retry can start at the bot's version commit rather than its source commit.
  if(reserved.source && git('tag','--points-at',source).split('\n').includes(`release-candidate/${reserved.source}`)) source=reserved.source;
  const candidate = `release-candidate/${source}`;
  const tags = git('tag','--list').split('\n');
  if (tags.includes(candidate)) {
    git('checkout','--detach',candidate);
    const state=JSON.parse(readFileSync('release.json'));
    if(state.source !== source) throw Error('Candidate source mismatch');
    if(previous && compare(state.version.split('.'), previous.slice(1).split('.')) <= 0) { output({ready:false}); process.exit(0); }
    output({ready:true, ...state, sha:git('rev-parse','HEAD')}); process.exit(0);
  }
  if(git('rev-parse','origin/main') !== source) { output({ready:false, reason:'Superseded by a newer main push'}); process.exit(0); }
  // Ignore documentation and tests alone, but include build scripts, assets and pinned payloads.
  const changed=git('diff-tree','--no-commit-id','--name-only','-r',...(previous ? [previous,source] : ['--root',source])).split('\n');
  const significant=changed.some(p => /^(release\.json$|App\/|MacApp\/|MacLocalUI\/|ShareExtension\/|Widgets\/|MacShareExtension\/|SafariWebExtension\/|Sources\/|ServerApp\/(Sources\/|Package\.|build\.sh|prepare\.sh|bundle-metadata\.py)|scripts\/|\.github\/workflows\/(release|build|testflight)\.ya?ml$|ArchiveBox\.xcodeproj\/|project\.yml$|Package\.)/.test(p));
  if(!significant) { output({ready:false,reason:'No app or packaging changes'}); process.exit(0); }
  const state=JSON.parse(readFileSync('release.json'));
  const occupied=tags.filter(t=>versionPattern.test(t)).map(t=>t.slice(1).split('.'));
  let numbers=state.version.split('.');
  for(const v of occupied) if(compare(v,numbers)>0) numbers=v;
  // An explicit, unreserved baseline is used exactly once before patch bumps resume.
  const freshBaseline=!state.source && occupied.every(v=>compare(state.version.split('.'),v)>0);
  const version=freshBaseline ? state.version : `${numbers[0]}.${numbers[1]}.${Number(numbers[2])+1}`;
  const next={version,build:state.build+1,source};
  if(process.argv.includes('--dry-run')) { output({ready:true,...next}); process.exit(0); }
  writeFileSync('release.json',JSON.stringify(next,null,2)+'\n');
  git('config','user.name','ArchiveBox Release Bot');
  git('config','user.email','release-bot@archivebox.io');
  git('add','release.json');git('commit','-m',`Bump release version to ${version}`);
  git('tag',candidate);
  // Atomic push fails safely if main advanced; never force someone else's commits away.
  git('push','--atomic','origin','HEAD:refs/heads/main',`refs/tags/${candidate}`);
  output({ready:true,...next,sha:git('rev-parse','HEAD')});
} else if(process.argv[2] === 'publish') {
  const state=JSON.parse(readFileSync('release.json'));
  const tag=`v${state.version}`, sha=git('rev-parse','HEAD');
  if(git('rev-parse',`release-candidate/${state.source}`)!==sha) throw Error('Not the reserved candidate');
  if(previous) git('merge-base','--is-ancestor',previous,sha);
  const body={tag_name:tag,target_commitish:sha,...(previous?{previous_tag_name:previous}:{})};
  // GitHub also builds a Contributors avatar section from @mentions in generated notes.
  const generated=JSON.parse(execFileSync('gh',['api',`repos/${repo}/releases/generate-notes`,'--input','-'],{input:JSON.stringify(body),encoding:'utf8'})).body.replace(/^## (?:New )?Contributors\n[\s\S]*?(?=^## |^\*\*Full Changelog|$(?![\s\S]))/gm, '').replace(/(^|\s)@([\w-]+)/g, '$1$2');
  const range=previous?`${previous}..${sha}`:sha;
  const commits=git('log','--reverse','--format=%H%x09%s%x09%aN',range).split('\n').filter(Boolean)
    .map(line=>{const [id,title,author]=line.split('\t');return `- [${id.slice(0,7)}](https://github.com/${repo}/commit/${id}) ${title} — ${author}`;}).join('\n');
  const link=process.env.TESTFLIGHT_PUBLIC_URL;
  if(!/^https:\/\/testflight\.apple\.com\/join\/[A-Za-z0-9]+$/.test(link||'')) throw Error('Configure the real public TestFlight invitation URL');
  const notes=`macOS 26+ on Apple Silicon. Download either signed, notarized app below. The Server ZIP includes the Linux runtime and ArchiveBox image; the client ZIP does not.\n\n**iPhone / iPad / Mac beta:** [Join ArchiveBox on TestFlight](${link}). New builds become available there after Apple approves external beta testing.\n\n${generated}\n\n## All commits\n${commits}\n\nSource: ${sha}\n`;
  writeFileSync('dist/release-notes.md',notes);
  const existing=JSON.parse(gh('api','--paginate','--slurp',`repos/${repo}/releases?per_page=100`)).flat().find(r=>r.tag_name===tag);
  if(existing && !existing.draft) throw Error('Public release is immutable');
  if(!git('tag','--list',tag)) {git('tag',tag);git('push','origin',`refs/tags/${tag}`);}
  if(git('rev-parse',`${tag}^{commit}`)!==sha) throw Error('Release tag points elsewhere');
  if(!existing) gh('release','create',tag,'--repo',repo,'--verify-tag','--draft','--title',`ArchiveBox ${state.version}`,'--notes-file','dist/release-notes.md');
  const assets=['ArchiveBox.app.zip','ArchiveBox.Server.app.zip'];
  gh('release','upload',tag,'--repo',repo,'--clobber',...assets.map(a=>`dist/${a}#${a.replace('ArchiveBox.Server', 'ArchiveBox Server')}`));
  // Drafts are omitted by GitHub's tag lookup; the authenticated list includes them.
  const release=JSON.parse(gh('api','--paginate','--slurp',`repos/${repo}/releases?per_page=100`)).flat().find(r=>r.tag_name===tag);
  if(!release) throw Error('Draft release is missing');
  for(const name of assets) {
    const hash=run('/usr/bin/shasum',['-a','256',`dist/${name}`]).split(' ')[0];
    if(!release.assets.some(a=>a.name===name && a.state==='uploaded' && a.digest===`sha256:${hash}`)) throw Error(`Uploaded asset digest mismatch: ${name}`);
  }
  gh('release','edit',tag,'--repo',repo,'--draft=false','--latest','--notes-file','dist/release-notes.md');
  // Keep the existing Sparkle feed URL; never replace the immutable versioned ZIPs.
  const feed=JSON.parse(gh('api','--paginate','--slurp',`repos/${repo}/releases?per_page=100`)).flat().find(r=>r.tag_name==='server-updates');
  if(!feed) gh('release','create','server-updates','--repo',repo,'--target',sha,'--prerelease','--latest=false','--title','ArchiveBox Server update feed','--notes','Stable Sparkle feed. Download apps from the versioned releases.');
  gh('release','upload','server-updates','--repo',repo,'--clobber','dist/appcast.xml');
  if(process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY,`Published [${tag}](https://github.com/${repo}/releases/tag/${tag}) with both notarized apps.\n`);
} else throw Error('Use prepare or publish');
