#!/usr/bin/env node
// Captures every scene of the web mockup (design/web) with headless Chromium:
//   <out>/<scene>-light@1x.png, -dark@1x.png, -light@2x.png, -dark@2x.png and <scene>-pair@2x.png (light | dark).
// usage: PLAYWRIGHT_CORE=/path/to/node_modules/playwright-core [CHROMIUM=/path/to/chrome] \
//        node scripts/capture-design.mjs [out dir, default build/design-captures] [scene ...]
// Serves the repository on a loopback port (no network beyond 127.0.0.1); fails on console errors or missing files.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const out = path.resolve(process.argv[2] || path.join(root, 'build/design-captures'));
const only = process.argv.slice(3);
const pwPath = process.env.PLAYWRIGHT_CORE;
if (!pwPath) { console.error('set PLAYWRIGHT_CORE to a playwright-core directory'); process.exit(2); }
const { chromium } = await import(pathToFileURL(path.join(pwPath, 'index.mjs')).href);

const types = { '.html': 'text/html; charset=utf-8', '.css': 'text/css', '.js': 'text/javascript', '.png': 'image/png', '.webp': 'image/webp' };
const missing = [];
const server = http.createServer((req, res) => {
  const p = path.normalize(decodeURIComponent(new URL(req.url, 'http://x').pathname));
  const f = path.join(root, p);
  if (!f.startsWith(root + path.sep) || !fs.existsSync(f) || fs.statSync(f).isDirectory()) { missing.push(p); res.writeHead(404); return res.end(); }
  res.writeHead(200, { 'content-type': types[path.extname(f)] || 'application/octet-stream' });
  fs.createReadStream(f).pipe(res);
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const base = `http://127.0.0.1:${server.address().port}/design/web/index.html`;

const browser = await chromium.launch({ executablePath: process.env.CHROMIUM || undefined, args: ['--font-render-hinting=none'] });
fs.mkdirSync(out, { recursive: true });
const errors = [];
const page0 = await browser.newPage();
await page0.goto(base);
const scenes = Object.keys(await page0.evaluate(() => window.SCENES)).filter((s) => !only.length || only.includes(s));
await page0.close();
const shots = [];
for (const scale of [1, 2]) {
  const ctx = await browser.newContext({ deviceScaleFactor: scale, viewport: { width: 2000, height: 1200 }, reducedMotion: 'reduce' });
  const page = await ctx.newPage();
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
  page.on('pageerror', (e) => errors.push(String(e)));
  const variants = [['light', '&theme=light'], ['dark', '&theme=dark']];
  if (scale === 2) variants.push(['pair', '&pair=1']);
  for (const s of scenes) for (const [name, qs] of variants) {
    await page.goto(`${base}?scene=${s}${qs}`);
    await page.evaluate(() => document.fonts.ready);
    await page.waitForFunction(() => [...document.images].every((i) => !i.getAttribute('src') || (i.complete && i.naturalWidth > 0)));
    const el = await page.$('#capture');
    const file = path.join(out, `${s}-${name}@${scale}x.png`);
    await el.screenshot({ path: file });
    const box = await el.boundingBox();
    shots.push(`${path.basename(file)} ${Math.round(box.width * scale)}x${Math.round(box.height * scale)}`);
  }
  await ctx.close();
}
await browser.close();
server.close();
fs.writeFileSync(path.join(out, 'index.txt'), shots.join('\n') + '\n');
console.log(`${shots.length} captures in ${path.relative(root, out) || out} (${scenes.length} scenes)`);
if (errors.length || missing.length) {
  console.error('console errors:', errors, 'missing files:', missing);
  process.exit(1);
}
