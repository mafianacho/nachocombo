#!/usr/bin/env node
// Records the motion preview (design/web ?scene=motion) frame by frame on a fixed clock, so the video shows exactly
// what motion.js computes: <out>/frames-<theme>/00000.png … at 25 fps, then (when ffmpeg is on PATH or FFMPEG is set)
// <out>/nacho-pet-motion.mp4 (light | dark side by side) and nacho-pet-motion.gif (light).
// usage: PLAYWRIGHT_CORE=<playwright-core dir> [FFMPEG=ffmpeg] node scripts/capture-motion.mjs [out dir]
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const out = path.resolve(process.argv[2] || path.join(root, 'build/design-motion'));
const { chromium } = await import(pathToFileURL(path.join(process.env.PLAYWRIGHT_CORE, 'index.mjs')).href);
const types = { '.html': 'text/html; charset=utf-8', '.css': 'text/css', '.js': 'text/javascript', '.png': 'image/png', '.webp': 'image/webp' };
const server = http.createServer((req, res) => {
  const f = path.join(root, path.normalize(decodeURIComponent(new URL(req.url, 'http://x').pathname)));
  if (!f.startsWith(root + path.sep) || !fs.existsSync(f) || fs.statSync(f).isDirectory()) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { 'content-type': types[path.extname(f)] || 'application/octet-stream' });
  fs.createReadStream(f).pipe(res);
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const base = `http://127.0.0.1:${server.address().port}/design/web/index.html?scene=motion`;
const fps = 25;
const browser = await chromium.launch();
const errors = [];
let frames = 0;
for (const theme of ['light', 'dark']) {
  const dir = path.join(out, `frames-${theme}`);
  fs.rmSync(dir, { recursive: true, force: true });
  fs.mkdirSync(dir, { recursive: true });
  const page = await browser.newPage({ deviceScaleFactor: 2, viewport: { width: 600, height: 400 } });
  page.on('pageerror', (e) => errors.push(String(e)));
  await page.goto(`${base}&theme=${theme}`);
  await page.waitForFunction(() => window.PRELOAD.every((i) => i.complete && i.naturalWidth > 0));
  const length = await page.evaluate(() => window.PetMotionPreview.length);
  const el = await page.$('#capture');
  for (let i = 0; i * 1000 / fps <= length; i++) {
    await page.evaluate((ms) => window.renderAt(ms), (i * 1000) / fps);
    await page.waitForFunction(() => [...document.images].every((im) => !im.src || im.complete));
    await el.screenshot({ path: path.join(dir, `${String(i).padStart(5, '0')}.png`) });
    frames++;
  }
  await page.close();
}
await browser.close();
server.close();
console.log(`${frames} frames in ${out}`);
if (errors.length) { console.error(errors); process.exit(1); }
const ffmpeg = process.env.FFMPEG || 'ffmpeg';
try {
  execFileSync(ffmpeg, ['-y', '-loglevel', 'error', '-framerate', String(fps), '-i', path.join(out, 'frames-light/%05d.png'), '-framerate', String(fps),
    '-i', path.join(out, 'frames-dark/%05d.png'), '-filter_complex', 'hstack=inputs=2,pad=ceil(iw/2)*2:ceil(ih/2)*2',
    '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-crf', '20', '-movflags', '+faststart', path.join(out, 'nacho-pet-motion.mp4')]);
  execFileSync(ffmpeg, ['-y', '-loglevel', 'error', '-framerate', String(fps), '-i', path.join(out, 'frames-light/%05d.png'), '-vf',
    'scale=iw/2:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4', '-loop', '0',
    path.join(out, 'nacho-pet-motion.gif')]);
  console.log('wrote nacho-pet-motion.mp4 and nacho-pet-motion.gif');
} catch (e) {
  console.log(`no ffmpeg (${e.code || e.message}): frames only`);
}
