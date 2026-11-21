#!/usr/bin/env node
// Lints captions.en.srt against the caption rules and the scene timeline, and NARRATION.md against the captions.
//   <= 42 characters per line, <= 2 lines, reading speed <= 17 characters per second (hard limit 20),
//   2.0 s <= duration <= 7 s (a one-line cue may be as short as 1.5 s), 0.1 s or more between cues, every cue inside one scene,
//   narration <= 150 words per minute over the whole video, and the narration text equal to the caption text, cue by cue.
// usage: node tools/check-captions.mjs [--srt captions.en.srt] [--timeline timeline.json] [--narration NARRATION.md]
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseSrt } from './lib/srt.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const dir = path.resolve(here, '..');
const a = {};
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) if (argv[i].startsWith('--')) a[argv[i].slice(2)] = argv[++i];
const cues = parseSrt(fs.readFileSync(a.srt || path.join(dir, 'captions.en.srt'), 'utf8'));
const tl = JSON.parse(fs.readFileSync(a.timeline || path.join(dir, 'timeline.json'), 'utf8'));
const narrationFile = a.narration || path.join(dir, 'NARRATION.md');

const errors = [];
const warnings = [];
const rows = [];
let words = 0;
cues.forEach((c, i) => {
  const text = c.lines.join(' ');
  const chars = text.length;
  const dur = c.end - c.start;
  const cps = chars / dur;
  words += text.split(/\s+/).filter(Boolean).length;
  const tag = `cue ${c.index}`;
  if (c.index !== i + 1) errors.push(`${tag}: numbering must be 1..N in order`);
  if (c.lines.length > 2) errors.push(`${tag}: ${c.lines.length} lines (max 2)`);
  for (const l of c.lines) if (l.length > 42) errors.push(`${tag}: line "${l}" is ${l.length} characters (max 42)`);
  if (cps > 20) errors.push(`${tag}: ${cps.toFixed(1)} cps (hard limit 20)`);
  else if (cps > 17) warnings.push(`${tag}: ${cps.toFixed(1)} cps (target <= 17)`);
  if (dur < (c.lines.length === 1 ? 1.5 : 2.0)) errors.push(`${tag}: only ${dur.toFixed(2)} s on screen`);
  if (dur > 7) errors.push(`${tag}: ${dur.toFixed(2)} s on screen (max 7)`);
  if (c.end > tl.duration) errors.push(`${tag}: ends after the video (${c.end}s > ${tl.duration}s)`);
  if (i > 0 && c.start - cues[i - 1].end < 0.1 - 1e-9) errors.push(`${tag}: starts ${(c.start - cues[i - 1].end).toFixed(2)} s after the previous cue (min 0.1)`);
  const scene = tl.scenes.find((s) => c.start >= s.start && c.end <= s.end + 1e-9);
  if (!scene) errors.push(`${tag}: crosses a scene boundary (${c.start}-${c.end}s)`);
  rows.push({ index: c.index, scene: scene?.id ?? '??', start: c.start, end: c.end, dur, chars, cps });
});
for (const s of tl.scenes) if (!cues.some((c) => c.start >= s.start && c.end <= s.end + 1e-9)) warnings.push(`scene ${s.id} (${s.title}) has no caption`);

const wpm = words / (tl.duration / 60);
if (wpm > 150) errors.push(`narration pace ${wpm.toFixed(0)} words/min (max 150)`);

if (fs.existsSync(narrationFile)) {
  const lines = fs.readFileSync(narrationFile, 'utf8').split('\n');
  const found = new Map();
  for (const l of lines) {
    const m = /^(\d+)\.\s+(\S+)\s+—\s+(.+)$/.exec(l);
    if (m) found.set(Number(m[1]), m[3].trim());
  }
  for (const c of cues) {
    const want = c.lines.join(' ');
    if (!found.has(c.index)) errors.push(`NARRATION.md: cue ${c.index} missing`);
    else if (found.get(c.index) !== want) errors.push(`NARRATION.md: cue ${c.index} differs from the caption ("${found.get(c.index)}" vs "${want}")`);
  }
  for (const k of found.keys()) if (!cues.some((c) => c.index === k)) errors.push(`NARRATION.md: cue ${k} has no caption`);
} else warnings.push('NARRATION.md not found');

console.log('| cue | scene | start | end | on screen (s) | chars | cps |\n|---|---|---|---|---|---|---|');
for (const r of rows) console.log(`| ${r.index} | ${r.scene} | ${r.start.toFixed(1)} | ${r.end.toFixed(1)} | ${r.dur.toFixed(1)} | ${r.chars} | ${r.cps.toFixed(1)} |`);
console.log(`\ncues: ${cues.length}, words: ${words}, video: ${tl.duration} s, narration pace: ${wpm.toFixed(0)} words/min, max cps: ${Math.max(...rows.map((r) => r.cps)).toFixed(1)}`);
for (const w of warnings) console.log(`warning: ${w}`);
for (const e of errors) console.log(`ERROR: ${e}`);
console.log(errors.length ? `\ncheck-captions: ${errors.length} error(s)` : '\ncheck-captions: OK');
process.exit(errors.length ? 1 : 0);
