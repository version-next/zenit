import {mkdirSync,readFileSync,writeFileSync} from 'node:fs';
import {resolve,dirname,join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {createServer} from 'node:http';
import {createHash} from 'node:crypto';
import {loadSuite,html,compare,classifyEngineDeviations,reportsFailed,runNative} from './conformance.mjs';
const dir = dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const option = (key, fallback) => {
  if (!args.includes(key)) return fallback;
  const value = args[args.indexOf(key)+1];
  if (value === undefined || value.startsWith('--')) throw Error(`${key} requires a value`);
  return value;
};
const out = resolve(option('--out',join(dir,'results')));
const fixtures = resolve(option('--fixtures',join(dir,'fixtures.json')));
const zenit = option('--zenit');
if (!zenit) throw Error('--zenit <executable> is required (use zig build layout-css-conformance)');
const suite = loadSuite(fixtures);
mkdirSync(out,{recursive:true});
runNative(resolve(zenit),[fixtures,join(out,'zenit.json')]);
const z = JSON.parse(readFileSync(join(out,'zenit.json'),'utf8'));
process.env.PLAYWRIGHT_BROWSERS_PATH ??= join(dir,'.browsers');
const {chromium,firefox,webkit} = await import('playwright-core');
// Local HTTP avoids data-URL font origin restrictions; server never exposes the workspace.
const font = readFileSync(resolve('tools/fixtures/fonts/Lora-Regular.ttf'));
const server = createServer((req,res) => {
  if (req.url === '/font.ttf') {res.writeHead(200,{'Content-Type':'font/ttf','Access-Control-Allow-Origin':'*'});res.end(font);}
  else {res.writeHead(404);res.end();}
});
await new Promise(r => server.listen(0,'127.0.0.1',r));
const fontURL = `http://127.0.0.1:${server.address().port}/font.ttf`;
const reports = [];
let error = false;
try {
  const engines = option('--browsers','chromium,firefox,webkit').split(',').map(v => v.trim()).filter(Boolean);
  if (engines.length === 0) throw Error('--browsers selected no engine');
  for (const name of engines) {
    let browser;
    const report = {engine:name,status:'unavailable',fixtures:[]};
    try {
      const type = {chromium,firefox,webkit}[name];
      if (!type) throw Error(`Unknown browser ${name}`);
      browser = await type.launch({headless:true,timeout:20000,...(name === 'chromium' ? {channel:'chromium-headless-shell',args:['--single-process','--in-process-gpu','--disable-gpu']} : {})});
      report.version = browser.version();
      const page = await browser.newPage({viewport:{width:1200,height:1000},deviceScaleFactor:1});
      for (const f of suite.fixtures) {
        const markup = html(f,fontURL);
        writeFileSync(join(out,`${name}-${encodeURIComponent(f.id)}.html`),markup);
        // The fixture viewport is the initial containing block (CSS2 10.1); body size alone is not.
        await page.setViewportSize({width:Math.ceil(f.width),height:Math.ceil(f.height)});
        await page.setContent(markup);
        await page.evaluate(async () => {await document.fonts.load('16px LC1');await document.fonts.load('32px LC1');await document.fonts.ready;if (!document.fonts.check('16px LC1')) throw Error('Fixed font failed to load');});
        const rects = await page.evaluate(() => [...document.querySelectorAll('[data-id]')].map(el => {
          const r = el.getBoundingClientRect();
          return {id:el.dataset.id,x:r.x,y:r.y,w:r.width,h:r.height};
        }));
        report.fixtures.push(compare(f,z.find(v => v.id === f.id).nodes,rects));
      }
      report.status = 'measured';
    } catch (e) {
      report.error = String(e);
      if (browser) report.status = 'error';
    } finally {await browser?.close();}
    reports.push(report);
  }
  classifyEngineDeviations(reports);
  error = reportsFailed(reports,{enforce:args.includes('--enforce'),requireAll:args.includes('--require-all'),expectedFixtureIds:suite.fixtures.map(f=>f.id)});
} finally {server.close();}
const sha256 = data => createHash('sha256').update(data).digest('hex');
const result = {version:1,generatedAt:new Date().toISOString(),host:{platform:process.platform,arch:process.arch,node:process.version},fixtureSha256:sha256(readFileSync(fixtures)),fontSha256:sha256(font),tolerance:0.5,mode:args.includes('--enforce')?'must-match':'report-only',font:'tools/fixtures/fonts/Lora-Regular.ttf',reports};
writeFileSync(join(out,'report.json'),JSON.stringify(result,null,2));
let md = '# Layout CSS conformance\n\nTolerance: 0.5 CSS px. --enforce fails unqualified must_match differences. Known deviations require two agreeing control engines. Missing primary engine, no measurements or measurement errors fail.\n';
for (const r of reports) {
  md += `\n## ${r.engine}: ${r.status} ${r.version ?? ''}\n\n`;
  if (r.error) md += '```\n'+r.error+'\n```\n';
  if (r.summary) {
    md += '| Property | Fixtures | Different | Known deviations | Different nodes / nodes (raw) |\n|---|---:|---:|---:|---:|\n';
    for (const [p,s] of Object.entries(r.summary)) md += `| ${p} | ${s.fixtures} | ${s.different} | ${s.knownDeviations} | ${s.differentNodes}/${s.nodes} |\n`;
  }
  const known = r.fixtures.filter(f => f.knownDeviation);
  if (known.length) {
    md += '\n### Known engine deviations / 已知偏差\n\n';
    for (const f of known) md += `- ${f.id}: ${f.knownDeviation.reason} (controls: ${f.knownDeviation.corroboratingEngines.join(', ')})\n`;
  }
  for (const f of r.fixtures) {
    md += `\n### ${f.id}: ${f.match?'MATCH':f.knownDeviation?'KNOWN DEVIATION':'DIFF'}${f.must_match?' (must match)':''}\n\n| Node | Zenit x,y,w,h | Browser x,y,w,h | Delta x,y,w,h | Result |\n|---|---|---|---|---|\n`;
    if (f.note) md += `${f.note}\n\n`;
    const fmt = n => n ? ['x','y','w','h'].map(k=>Number(n[k].toFixed(3))).join(', ') : 'missing';
    for (const n of f.nodes) md += `| ${n.id} | ${fmt(n.zenit)} | ${fmt(n.browser)} | ${fmt(n.delta)} | ${n.match?'MATCH':'DIFF'} |\n`;
  }
}
writeFileSync(join(out,'report.md'),md);
console.log(reports.map(r=>`${r.engine}: ${r.status}, ${r.fixtures.filter(f=>f.match).length}/${r.fixtures.length} fixtures match, ${r.fixtures.filter(f=>f.knownDeviation).length} known deviations`).join('\n'));
console.log(`Report: ${join(out,'report.md')}`);
process.exitCode = error ? 1 : 0;
