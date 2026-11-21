#!/usr/bin/env node
// Collects the gallery-loop segments of timeline.json (seconds of the finished video) into one numbered frame folder
// (hard links, falling back to copies) so ffmpeg can build the GIF from it.
// usage: node tools/gif-frames.mjs <frames dir> <out dir> [timeline.json]
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const [frames, out, tlPath] = process.argv.slice(2);
if (!frames || !out) { console.error('usage: gif-frames.mjs <frames dir> <out dir> [timeline.json]'); process.exit(2); }
const tl = JSON.parse(fs.readFileSync(tlPath || path.join(here, '..', 'timeline.json'), 'utf8'));
fs.rmSync(out, { recursive: true, force: true });
fs.mkdirSync(out, { recursive: true });
let n = 0;
for (const [from, to] of tl.gif.segments) {
  for (let i = Math.round(from * tl.fps); i < Math.round(to * tl.fps); i++) {
    const src = path.join(frames, `${String(i).padStart(5, '0')}.png`);
    const dst = path.join(out, `${String(n++).padStart(5, '0')}.png`);
    try { fs.linkSync(src, dst); } catch { fs.copyFileSync(src, dst); }
  }
}
console.log(`gif frames: ${n} (${(n / tl.fps).toFixed(2)} s) from ${tl.gif.segments.length} segments`);
