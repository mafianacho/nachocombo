#!/usr/bin/env node
// Builds an input folder for the dry run: copies the stand-in pictures named in capture-manifest.json (existing
// docs/images PNGs) under the capture file names, so the pipeline can run before real captures exist.
// usage: node tools/make-standin.mjs <out dir>
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const videoDir = path.resolve(here, '..');
const repoRoot = path.resolve(videoDir, '../../..');
const out = process.argv[2];
if (!out) { console.error('usage: make-standin.mjs <out dir>'); process.exit(2); }
const manifest = JSON.parse(fs.readFileSync(path.join(videoDir, 'capture-manifest.json'), 'utf8'));
fs.mkdirSync(out, { recursive: true });
let n = 0;
for (const c of manifest.captures) {
  if (c.file.startsWith('repo:')) continue;
  fs.copyFileSync(path.join(repoRoot, c.standin), path.join(out, c.file));
  n++;
}
console.log(`stand-in: ${n} pictures from the repo's docs/images copied to ${out}`);
