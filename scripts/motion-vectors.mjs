#!/usr/bin/env node
// Plays scripted timelines through the web motion model (design/web/motion.js) and writes the poses to
// Tests/NachoComboCoreTests/Fixtures/pet-motion-vectors.json; PetMotionTests replays the same events through
// PetMotion.swift and expects the same poses. `--check` fails when the file is out of date.
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const out = path.join(root, 'Tests/NachoComboCoreTests/Fixtures/pet-motion-vectors.json');
const ctx = vm.createContext({ Math });
vm.runInContext('globalThis = this;', ctx);
for (const f of ['design/web/tokens.js', 'design/web/motion.js']) vm.runInContext(fs.readFileSync(path.join(root, f), 'utf8'), ctx);

// The preview's timeline (also used by the web motion scene), plus press/drag and reduced motion.
const timelines = {
  states: vm.runInContext('({ seed: PetMotionPreview.seed, events: PetMotionPreview.events.map((e) => e.slice(0, 3)) })', ctx),
  touch: { seed: 3, events: [[0, 'face', 'idle'], [500, 'press'], [620, 'release'], [900, 'press'], [1000, 'drag', 600],
    [1150, 'drag', -900], [1300, 'drag', 200], [1400, 'drop'], [1500, 'release']] },
  reduced: { seed: 5, reduceMotion: true, events: [[0, 'face', 'idle'], [1000, 'face', 'thinking'], [3000, 'face', 'tired'], [4000, 'press']] },
};
const result = {};
for (const [name, tl] of Object.entries(timelines)) {
  const end = tl.events[tl.events.length - 1][0] + 2400;
  const samples = [];
  const m = vm.runInContext(`new PetMotion(${JSON.stringify({ face: tl.events[0][2], at: 0, reduceMotion: !!tl.reduceMotion, seed: tl.seed })})`, ctx);
  let next = 1;
  for (let t = 0; t <= end; t += 50) {
    while (next < tl.events.length && tl.events[next][0] <= t) {
      const [at, op, arg] = tl.events[next++];
      if (op === 'face') m.setFace(arg, at); else if (op === 'drag') m.drag(arg, at); else m[op](at);
    }
    samples.push({ t, ...m.pose(t), animating: m.isAnimating(t) });
  }
  result[name] = { ...tl, samples };
}
const text = JSON.stringify(result) + '\n';
if (process.argv.includes('--check')) {
  if (!fs.existsSync(out) || fs.readFileSync(out, 'utf8') !== text) { console.error(`${path.relative(root, out)} is out of date: node scripts/motion-vectors.mjs`); process.exit(1); }
  console.log('motion vectors up to date');
} else {
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, text);
  console.log(`wrote ${path.relative(root, out)} (${Object.values(result).reduce((n, r) => n + r.samples.length, 0)} poses)`);
}
