#!/usr/bin/env node
// Renders the intro video frame by frame on a fixed clock: frame N is the scene at exactly N/fps seconds.
// usage: PLAYWRIGHT_CORE=<playwright-core dir> node tools/render.mjs --captures <dir> --out <frames dir>
//          [--timeline timeline.json] [--manifest capture-manifest.json] [--srt captions.en.srt]
//          [--draft] [--workers 1] [--range t0,t1] [--still 3.2,12 ...]
//   --workers N   parallel browser pages (default 1). Frame i of a multi-page run is drawn by page (i mod N). Since NACHO-994 the scene
//                 draws the same pixels whatever page and history drew them (no will-change layers, integer entrance offsets, no
//                 leftover transforms), but the default stays at one page and `tools/check-text-stability.mjs` is the proof for any other value.
//   --range a,b   only frames from a to b seconds (the files keep their frame numbers; for quick checks of one scene)
//   --still t,t   just those moments as still-<t>.png in --out
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { parseSrt } from './lib/srt.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const videoDir = path.resolve(here, '..');
const repoRoot = path.resolve(videoDir, '../../..');

function args(argv) {
  const o = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    if (!argv[i].startsWith('--')) { o._.push(argv[i]); continue; }
    const k = argv[i].slice(2);
    o[k] = argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[++i] : true;
  }
  return o;
}
const a = args(process.argv.slice(2));
const fail = (m) => { console.error(`render: ${m}`); process.exit(2); };
if (!a.captures || !a.out) fail('usage: render.mjs --captures <dir> --out <frames dir> [--draft] [--workers N] [--still t,t]');
if (!process.env.PLAYWRIGHT_CORE) fail('set PLAYWRIGHT_CORE to a playwright-core directory (the shared browser cache ~/.cache/ms-playwright is used; nothing is installed)');

const timeline = JSON.parse(fs.readFileSync(path.resolve(a.timeline || path.join(videoDir, 'timeline.json'), ''), 'utf8'));
const manifest = JSON.parse(fs.readFileSync(path.resolve(a.manifest || path.join(videoDir, 'capture-manifest.json')), 'utf8'));
const cues = parseSrt(fs.readFileSync(path.resolve(a.srt || path.join(videoDir, 'captions.en.srt')), 'utf8'));
const capturesDir = path.resolve(a.captures);
const outDir = path.resolve(a.out);

// capture id -> file served to the page. `repo:<path>` entries are read from the repository (brand art), the rest from --captures.
const files = {};
const missing = [];
const small = [];
for (const c of manifest.captures) {
  const abs = c.file.startsWith('repo:') ? path.join(repoRoot, c.file.slice(5)) : path.join(capturesDir, c.file);
  if (!fs.existsSync(abs)) { missing.push(`${c.id} -> ${c.file}`); continue; }
  files[c.id] = abs;
  const head = fs.readFileSync(abs).subarray(0, 24);
  const width = head.readUInt32BE(16);
  if (head.toString('latin1', 1, 4) !== 'PNG') missing.push(`${c.id}: ${c.file} is not a PNG`);
  else if (width < c.minWidth) small.push(`${c.id}: ${width}px wide, manifest wants >= ${c.minWidth}px (is it 2x?)`);
}
const used = new Set();
for (const s of timeline.scenes) for (const e of s.elements) if (e.capture) used.add(e.capture);
for (const id of used) if (!manifest.captures.some((c) => c.id === id)) missing.push(`timeline uses "${id}" which is not in capture-manifest.json`);
if (missing.length) fail(`missing or invalid captures:\n  ${missing.join('\n  ')}`);
if (small.length) console.warn(`render: warning, low resolution:\n  ${small.join('\n  ')}`);

const types = { '.html': 'text/html; charset=utf-8', '.css': 'text/css', '.js': 'text/javascript', '.png': 'image/png', '.ttf': 'font/ttf' };
const fontsDir = path.join(repoRoot, 'Resources/Fonts');
const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://x');
  const p = decodeURIComponent(url.pathname);
  let file = null;
  if (p.startsWith('/scene/')) file = path.join(here, 'scene', path.normalize(p.slice(7)));
  else if (p.startsWith('/fonts/')) file = path.join(fontsDir, path.normalize(p.slice(7)));
  else if (p.startsWith('/capture/')) file = files[p.slice(9)];
  const root = p.startsWith('/scene/') ? path.join(here, 'scene') : p.startsWith('/fonts/') ? fontsDir : null;
  if (!file || (root && !file.startsWith(root + path.sep)) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { 'content-type': types[path.extname(file)] || 'application/octet-stream', 'cache-control': 'max-age=3600' });
  fs.createReadStream(file).pipe(res);
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const base = `http://127.0.0.1:${server.address().port}`;
const captureUrls = Object.fromEntries(Object.keys(files).filter((id) => used.has(id)).map((id) => [id, `${base}/capture/${id}`]));

const { chromium } = await import(pathToFileURL(path.join(path.resolve(process.env.PLAYWRIGHT_CORE), 'index.mjs')).href);
const browser = await chromium.launch();
const fps = timeline.fps;
const total = Math.round(timeline.duration * fps);

async function openPage() {
  const page = await browser.newPage({ viewport: { width: timeline.width, height: timeline.height }, deviceScaleFactor: 1 });
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  page.on('requestfailed', (r) => errors.push(`request failed: ${r.url()}`));
  await page.goto(`${base}/scene/index.html`);
  await page.evaluate((payload) => window.initScene(payload), { timeline, captures: captureUrls, cues, draft: !!a.draft });
  return { page, errors };
}

fs.mkdirSync(outDir, { recursive: true });
const t0 = Date.now();
let errorsAll = [];
if (a.still) {
  const { page, errors } = await openPage();
  for (const t of String(a.still).split(',').map(Number)) {
    await page.evaluate((ms) => window.renderAt(ms), t * 1000);
    await page.screenshot({ path: path.join(outDir, `still-${String(t).replace('.', '_')}.png`) });
  }
  await page.close();
  errorsAll = errors;
} else {
  for (const f of fs.readdirSync(outDir)) if (/^\d{5}\.png$/.test(f)) fs.rmSync(path.join(outDir, f));
  const workers = Math.max(1, Math.min(Number(a.workers) || 1, 16));
  const [rFrom, rTo] = a.range ? String(a.range).split(',').map(Number) : [0, timeline.duration];
  const first = Math.max(0, Math.ceil(rFrom * fps - 1e-9)), last = Math.min(total - 1, Math.floor(rTo * fps + 1e-9));
  const count = last - first + 1;
  if (workers > 1) console.warn(`render: ${workers} pages. Frame i is drawn by page (i mod ${workers}); run tools/check-text-stability.mjs on the result.`);
  let done = 0;
  await Promise.all(Array.from({ length: workers }, async (_, w) => {
    const { page, errors } = await openPage();
    for (let i = first + w; i <= last; i += workers) {
      await page.evaluate((ms) => window.renderAt(ms), (i * 1000) / fps);
      await page.screenshot({ path: path.join(outDir, `${String(i).padStart(5, '0')}.png`) });
      if (++done % 250 === 0) console.log(`render: ${done}/${count} frames`);
    }
    errorsAll.push(...errors, ...(await page.evaluate(() => window.__errors)));
    await page.close();
  }));
  console.log(`render: ${count} frames (${timeline.width}x${timeline.height} @ ${fps} fps, ${timeline.duration}s timeline, ${workers} page${workers > 1 ? 's' : ''}) in ${((Date.now() - t0) / 1000).toFixed(1)}s -> ${outDir}`);
}
await browser.close();
server.close();
if (errorsAll.length) { console.error(`render: page errors:\n  ${[...new Set(errorsAll)].join('\n  ')}`); process.exit(1); }
