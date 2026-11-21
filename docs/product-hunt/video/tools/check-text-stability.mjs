#!/usr/bin/env node
// Text stability check: proves that the big English text (titles, pills, taglines) and the captions do not move sideways
// by a pixel from frame to frame once their entrance animation is over.
//
// Why: NACHO-975 found that the title text of the first MP4 "wobbled" left and right by 1 px with a period of 6 frames
// (4.2 Hz at 25 fps): tools/render.mjs drew frame i on page (i mod 6) and each page rasterised the same text a pixel
// differently depending on its own history. This tool measures that directly, so it cannot come back unnoticed.
//
// usage: node tools/check-text-stability.mjs <video.mp4 | folder of 00000.png ...> [--report out.md] [--json out.json]
//          [--timeline timeline.json] [--srt captions.en.srt] [--only S04a,S04c] [--no-captions] [--tmp dir] [--selftest]
//   Input is a finished MP4 (frames are decoded with ffmpeg) or the PNG frames the renderer wrote (exact mode).
//   ffmpeg comes from tools/ffmpeg.sh's settings: FFMPEG_MODE=local, FFMPEG_IMAGE, FFMPEG_DOCKER_USER, DOCKER_HOST, MULTICA_TASK_ID (container label and name, see ffmpeg.sh).
//   --tmp is where ffmpeg writes its raw frames while this runs (default: a hidden folder next to the input, removed afterwards).
//
// What is measured, per element and per stable window (scene start + 1.6 s ... scene end - 0.5 s, narrowed to the time the
// element is really on screen; per caption cue: cue start + 0.25 s ... cue end - 0.25 s):
//   * the left end and right end x of the text (first / last pixel column with at least 2 pixels that stand out from the
//     background by 40 % of the text contrast), the top / bottom end y (information only),
//   * the centre x of its brightness: the sub-pixel sideways SHIFT of the text's column brightness profile against the
//     profile that is typical for the window (the median over its frames), found by cross-correlation. (The plain centroid is
//     also written to the JSON. It is not judged: with bit-identical source frames x264 alone moves the centroid of thin pill text
//     by up to 0.3 px, from re-coding its anti-aliased edges, while the shift stays at 0.00.)
// PASS needs, for every window:
//   1. the left and right end do not change (0 px). PNG frames: exactly. MP4: at most 2 changes in the window, because x264 may
//      re-code a still picture once so that an edge pixel crosses the threshold (a plateau; a render wobble flips every few frames);
//      and the centre shift stays within 0.15 px (MP4) / 0.03 px (PNG),
//   2. no periodic pattern: for a frame-number modulus 2..8 the frame number must not explain the measurement
//      (eta squared >= 0.5 with a spread of the group means >= 0.25 px for the ends, >= 0.05 px for the shift),
//   3. the caption box (measured through its text: the box edges have no contrast against the dark scene) is held to the same rules.
// PNG input adds: no text pixel (>= 30 % of the text contrast above the background) may change its RGB value by more than 2 levels
// between consecutive frames of a window (difference 0). A 1-2 level step is the translucent caption box over a picture that fades behind it.
// Exit code 0 = PASS, 1 = FAIL, 2 = usage error.
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { parseSrt } from './lib/srt.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const videoDir = path.resolve(here, '..');

const a = { _: [] };
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
  if (!argv[i].startsWith('--')) { a._.push(argv[i]); continue; }
  const k = argv[i].slice(2);
  a[k] = argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[++i] : true;
}
const die = (m) => { console.error(`check-text-stability: ${m}`); process.exit(2); };

// ---------------------------------------------------------------- measurement on one gray frame
const W = 1920, H = 1080;

function percentile(hist, total, q) {
  let acc = 0;
  const want = total * q;
  for (let v = 0; v < 256; v++) { acc += hist[v]; if (acc >= want) return v; }
  return 255;
}

// frame: Uint8Array gray (W*H). region [x0,y0,x1,y1) (exclusive end). Returns { bg, sign, contrast }, fixed per window.
function reference(frame, r) {
  const hist = new Uint32Array(256);
  let n = 0;
  for (let y = r[1]; y < r[3]; y++) for (let x = r[0]; x < r[2]; x++) { hist[frame[y * W + x]]++; n++; }
  const bg = percentile(hist, n, 0.5);
  const hi = percentile(hist, n, 0.999) - bg, lo = bg - percentile(hist, n, 0.001);
  const sign = hi >= lo ? 1 : -1;
  return { bg, sign, contrast: Math.max(hi, lo) };
}

function measure(frame, r, ref) {
  const C = ref.contrast, T = Math.max(30, 0.4 * C), floor = 0.3 * C;
  const cols = new Uint16Array(r[2] - r[0]);
  const rows = new Uint16Array(r[3] - r[1]);
  const prof = new Float64Array(r[2] - r[0]);
  let sw = 0, sx = 0;
  for (let y = r[1]; y < r[3]; y++) {
    for (let x = r[0]; x < r[2]; x++) {
      const d = (frame[y * W + x] - ref.bg) * ref.sign;
      if (d >= T) { cols[x - r[0]]++; rows[y - r[1]]++; }
      if (d > floor) { const w = d - floor; sw += w; sx += w * x; }
      prof[x - r[0]] += d < 0 ? 0 : d > C ? C : d;
    }
  }
  let left = -1, right = -1, top = -1, bottom = -1;
  for (let i = 0; i < cols.length; i++) if (cols[i] >= 2) { if (left < 0) left = i + r[0]; right = i + r[0]; }
  for (let i = 0; i < rows.length; i++) if (rows[i] >= 2) { if (top < 0) top = i + r[1]; bottom = i + r[1]; }
  return { left, right, top, bottom, cx: sw > 0 ? sx / sw : -1, prof };
}

// Sideways shift (px, sub-pixel) of every frame's column profile against the median profile of the window.
function shifts(profs) {
  const L = profs[0].length, n = profs.length;
  const ref = new Float64Array(L);
  const col = new Float64Array(n);
  for (let i = 0; i < L; i++) { for (let f = 0; f < n; f++) col[f] = profs[f][i]; ref[i] = Array.from(col).sort((p, q) => p - q)[n >> 1]; }
  const M = 3, step = 0.05, grid = [];
  for (let s = -2; s <= 2 + 1e-9; s += step) grid.push(s);
  const err = (p, s) => {
    let e = 0;
    for (let i = M; i < L - M; i++) {
      const xi = i - s, i0 = Math.floor(xi), fr = xi - i0;
      const v = p[i0] * (1 - fr) + p[i0 + 1] * fr;
      e += (v - ref[i]) ** 2;
    }
    return e;
  };
  return profs.map((p) => {
    const es = grid.map((s) => err(p, s));
    let k = 0;
    for (let i = 1; i < es.length; i++) if (es[i] < es[k]) k = i;
    if (k === 0 || k === es.length - 1) return grid[k];
    const d = es[k - 1] - 2 * es[k] + es[k + 1];
    return grid[k] + (d > 1e-12 ? (0.5 * (es[k - 1] - es[k + 1])) / d * step : 0);
  });
}

// ---------------------------------------------------------------- statistics
const range = (xs) => (xs.length ? Math.max(...xs) - Math.min(...xs) : 0);
const changes = (xs) => { let c = 0; for (let i = 1; i < xs.length; i++) if (xs[i] !== xs[i - 1]) c++; return c; };

// How much of the variation of xs the frame number modulo m explains (eta squared) and the spread of the group means.
function periodicity(frames, xs, m) {
  const sum = new Array(m).fill(0), cnt = new Array(m).fill(0);
  frames.forEach((f, i) => { sum[f % m] += xs[i]; cnt[f % m]++; });
  const means = sum.map((s, i) => (cnt[i] ? s / cnt[i] : null));
  const used = means.filter((v) => v !== null);
  const grand = xs.reduce((p, c) => p + c, 0) / xs.length;
  let ssTot = 0, ssBetween = 0;
  for (const x of xs) ssTot += (x - grand) ** 2;
  means.forEach((mu, i) => { if (mu !== null) ssBetween += cnt[i] * (mu - grand) ** 2; });
  return { m, eta2: ssTot > 1e-12 ? ssBetween / ssTot : 0, spread: used.length ? Math.max(...used) - Math.min(...used) : 0, means };
}

function judge(series, frames, exact) {
  const out = { ok: true, why: [] };
  out.rangeLeft = range(series.left); out.rangeRight = range(series.right);
  out.changesLeft = changes(series.left); out.changesRight = changes(series.right);
  out.rangeShift = range(series.shift);
  out.rangeCx = range(series.cx);
  out.rangeTop = range(series.top); out.rangeBottom = range(series.bottom);
  const maxChanges = exact ? 0 : 2;
  const shiftLimit = exact ? 0.03 : 0.15;
  if (out.changesLeft > maxChanges) { out.ok = false; out.why.push(`left end changes ${out.changesLeft} times (range ${out.rangeLeft} px)`); }
  if (out.changesRight > maxChanges) { out.ok = false; out.why.push(`right end changes ${out.changesRight} times (range ${out.rangeRight} px)`); }
  if (out.rangeShift > shiftLimit) { out.ok = false; out.why.push(`centre shifts ${out.rangeShift.toFixed(3)} px (limit ${shiftLimit})`); }
  out.periodic = [];
  for (const [name, xs, minSpread] of [['left', series.left, 0.25], ['right', series.right, 0.25], ['centre', series.shift, 0.05]]) {
    for (let m = 2; m <= 8; m++) {
      if (frames.length < m * 3) continue;
      const p = periodicity(frames, xs, m);
      if (p.eta2 >= 0.5 && p.spread >= minSpread) out.periodic.push({ series: name, ...p });
    }
  }
  if (out.periodic.length) {
    out.ok = false;
    const worst = out.periodic.slice().sort((x, y) => y.eta2 - x.eta2)[0];
    out.why.push(`periodic: ${worst.series} follows frame mod ${worst.m} (eta2 ${worst.eta2.toFixed(2)}, spread ${worst.spread.toFixed(2)} px)`);
  }
  return out;
}

// ---------------------------------------------------------------- what to measure (from the timeline and the cues)
function buildTargets(timeline, cues, only, withCaptions) {
  const fps = timeline.fps;
  const targets = [];
  const lastT = timeline.duration - (timeline.fadeOut ?? 0.6) - 0.1;
  for (const s of timeline.scenes) {
    if (only && !only.includes(s.id)) continue;
    const hasWideShot = (s.elements || []).some((e) => e.type === 'shot' && e.region && e.region[0] >= 680);
    (s.elements || []).forEach((e, idx) => {
      if (e.type !== 'text' && e.type !== 'pill') return;
      const inAt = e.inAt ?? 0;
      const inDur = e.in === 'cut' ? 0 : (e.inDur ?? 0.5);
      const t0 = s.start + Math.max(1.6, inAt + inDur + 0.3);
      const t1 = Math.min(s.end - 0.5, e.outAt != null ? s.start + e.outAt - 0.1 : Infinity, lastT);
      if (t1 - t0 < 0.5) return;
      let region;
      if (e.type === 'text') {
        const lines = String(e.text).split('\n').length;
        const lh = e.lineHeight ?? (e.font === 'plex' ? 1.25 : 1.02);
        const h = lines * (e.size || 44) * lh;
        const x1 = e.x < 600 && hasWideShot ? 680 : 1880;
        region = [Math.max(0, Math.round(e.x - 50)), Math.max(0, Math.round(e.y - 30)), x1, Math.min(H, Math.round(e.y + h + 30))];
      } else {
        const x1 = e.x < 600 && hasWideShot ? 680 : 1900;
        region = [Math.max(0, Math.round(e.x - 50)), Math.max(0, Math.round(e.y - 10)), x1, Math.min(H, Math.round(e.y + 80))];
      }
      targets.push({ id: `${s.id}#${idx}`, label: `${s.id} ${e.type === 'pill' ? 'pill' : e.font === 'anton' ? 'title' : 'text'} "${String(e.text).replace(/\n/g, ' / ').slice(0, 28)}"`, kind: e.type === 'pill' ? 'pill' : 'text', region, t0, t1 });
    });
  }
  if (withCaptions && !only) {
    for (const c of cues) {
      const t0 = c.start + 0.25, t1 = c.end - 0.25;
      if (t1 - t0 < 0.4) continue;
      targets.push({ id: `cue${c.index}`, label: `caption cue ${c.index}`, kind: 'caption', region: [150, 880, 1770, 1040], t0, t1, caption: true });
    }
  }
  for (const t of targets) { t.f0 = Math.ceil(t.t0 * fps - 1e-9); t.f1 = Math.floor(t.t1 * fps + 1e-9); }
  return targets.filter((t) => t.f1 - t.f0 + 1 >= 5);
}

// ---------------------------------------------------------------- frame source (ffmpeg raw frames)
// ffmpeg writes raw frames to a temporary file, CHUNK frames at a time, and this script reads that file. (Piping the raw
// frames through `docker run` stdout is about 25 times slower than writing to a mounted folder.)
const CHUNK = 250;
let dockerRuns = 0;
function runFfmpeg(args, inputDir, tmpDir) {
  const mode = process.env.FFMPEG_MODE || 'docker';
  const image = process.env.FFMPEG_IMAGE || 'jrottenberg/ffmpeg@sha256:292a972c60356abd651d9a4f9c808c13e7473f65ad400b7eb99215f4e571931d';
  let cmd, cargs, cwd;
  if (mode === 'local') { cmd = 'ffmpeg'; cargs = ['-hide_banner', '-v', 'error', ...args.map((x) => x.replace('{in}', inputDir).replace('{out}', tmpDir))]; cwd = inputDir; }
  else {
    const extra = process.env.FFMPEG_DOCKER_USER ? ['-u', process.env.FFMPEG_DOCKER_USER] : [];
    // Same rule as tools/ffmpeg.sh: with MULTICA_TASK_ID set, label the container and give it a name that is new for every call.
    const owner = process.env.MULTICA_TASK_ID;
    if (owner) extra.push('--label', `mafianacho.owner=${owner}`, '--name', `nc-video-${owner.replace(/[^A-Za-z0-9_.-]/g, '_')}-${process.pid}-${++dockerRuns}`);
    cmd = 'docker';
    cargs = ['run', '--rm', ...extra, '-v', `${inputDir}:/w:ro`, '-v', `${tmpDir}:/o`, '-w', '/w', '--entrypoint', 'ffmpeg', image, '-hide_banner', '-v', 'error', ...args.map((x) => x.replace('{in}', '/w').replace('{out}', '/o'))];
  }
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, cargs, { cwd, stdio: ['ignore', 'inherit', 'inherit'] });
    child.on('error', reject);
    child.on('close', (code) => (code === 0 ? resolve() : reject(new Error(`ffmpeg exited with ${code}`))));
  });
}

async function* frames(input, isDir, fps, firstFrame, lastFrame, tmpDir) {
  const bytes = isDir ? W * H * 3 : W * H;
  const inputDir = isDir ? path.resolve(input) : path.dirname(path.resolve(input));
  const file = path.join(tmpDir, 'chunk.raw');
  for (let a0 = firstFrame; a0 <= lastFrame; a0 += CHUNK) {
    const n = Math.min(CHUNK, lastFrame - a0 + 1);
    const out = ['-fps_mode', 'passthrough', '-f', 'rawvideo', '-pix_fmt', isDir ? 'rgb24' : 'gray', '-y', '{out}/chunk.raw'];
    const args = isDir
      ? ['-framerate', String(fps), '-start_number', String(a0), '-i', '{in}/%05d.png', '-frames:v', String(n), ...out]
      : ['-i', '{in}/' + path.basename(input), '-vf', `select=between(n\\,${a0}\\,${a0 + n - 1})`, ...out];
    await runFfmpeg(args, inputDir, tmpDir);
    const size = fs.statSync(file).size;
    if (size % bytes !== 0) throw new Error(`ffmpeg wrote a partial frame (${size} bytes)`);
    const fd = fs.openSync(file, 'r');
    try {
      for (let i = 0; i < size / bytes; i++) {
        const data = Buffer.allocUnsafe(bytes);
        fs.readSync(fd, data, 0, bytes, i * bytes);
        yield { index: a0 + i, data };
      }
    } finally { fs.closeSync(fd); fs.rmSync(file, { force: true }); }
  }
}

function toGray(rgb) {
  const g = new Uint8Array(W * H);
  for (let i = 0, j = 0; i < g.length; i++, j += 3) g[i] = (rgb[j] * 77 + rgb[j + 1] * 150 + rgb[j + 2] * 29) >> 8;
  return g;
}

// ---------------------------------------------------------------- selftest: synthetic frames, no ffmpeg
function selftest() {
  const mk = (shift) => {
    const f = new Uint8Array(W * H).fill(20);
    for (let y = 300; y < 340; y++) for (let x = 110 + shift; x < 400 + shift; x++) f[y * W + x] = 230;
    // a few edge pixels with partial coverage so that a sub-pixel shift is visible
    for (let y = 300; y < 340; y++) f[y * W + 109 + shift] = 90;
    return f;
  };
  const region = [60, 280, 680, 360];
  const nums = Array.from({ length: 60 }, (_, i) => i);
  const ref = reference(mk(0), region);
  const run = (fn) => {
    const ms = nums.map((i) => measure(fn(i), region, ref));
    const sh = shifts(ms.map((m) => m.prof));
    return judge({ left: ms.map((m) => m.left), right: ms.map((m) => m.right), top: ms.map((m) => m.top), bottom: ms.map((m) => m.bottom), cx: ms.map((m) => m.cx), shift: sh }, nums, true);
  };
  const bad = run((i) => mk(i % 6 === 2 || i % 6 === 5 ? 1 : 0));
  const good = run(() => mk(0));
  console.log(`selftest wobbling (1 px every 3rd frame): ${bad.ok ? 'PASS' : 'FAIL'} (${bad.why.join('; ')})`);
  console.log(`selftest steady: ${good.ok ? 'PASS' : 'FAIL'}`);
  process.exit(!bad.ok && good.ok ? 0 : 1);
}

// ---------------------------------------------------------------- main
if (a.selftest) selftest();
const input = a._[0];
if (!input || !fs.existsSync(input)) die('usage: check-text-stability.mjs <video.mp4 | frames folder> [--report out.md] [--json out.json] [--only S04a,S04c] [--no-captions]');
const isDir = fs.statSync(input).isDirectory();
const timeline = JSON.parse(fs.readFileSync(a.timeline || path.join(videoDir, 'timeline.json'), 'utf8'));
const cues = parseSrt(fs.readFileSync(a.srt || path.join(videoDir, 'captions.en.srt'), 'utf8'));
if (timeline.width !== W || timeline.height !== H) die(`the check is written for ${W}x${H}`);
const only = typeof a.only === 'string' ? a.only.split(',') : null;
const targets = buildTargets(timeline, cues, only, !a['no-captions']);
if (!targets.length) die('nothing to measure (check --only)');
const lastFrame = Math.max(...targets.map((t) => t.f1)), firstFrame = Math.min(...targets.map((t) => t.f0));
const wanted = new Set();
for (const t of targets) { t.series = { left: [], right: [], top: [], bottom: [], cx: [] }; t.profs = []; t.idx = []; t.diff = []; t.prevRgb = null; for (let f = t.f0; f <= t.f1; f++) wanted.add(f); }

const tmpDir = path.resolve(typeof a.tmp === 'string' ? a.tmp : path.join(isDir ? path.resolve(input) : path.dirname(path.resolve(input)), `.stability-tmp-${process.pid}`));
fs.mkdirSync(tmpDir, { recursive: true });
process.on('exit', () => fs.rmSync(path.join(tmpDir, 'chunk.raw'), { force: true }));
if (typeof a.tmp !== 'string') process.on('exit', () => fs.rmSync(tmpDir, { recursive: true, force: true }));
let seen = 0;
for await (const fr of frames(input, isDir, timeline.fps, firstFrame, lastFrame, tmpDir)) {
  seen++;
  if (!wanted.has(fr.index)) continue;
  const gray = isDir ? toGray(fr.data) : fr.data;
  for (const t of targets) {
    if (fr.index < t.f0 || fr.index > t.f1) continue;
    if (!t.ref) t.ref = reference(gray, t.region);
    const m = measure(gray, t.region, t.ref);
    t.idx.push(fr.index);
    for (const k of Object.keys(t.series)) t.series[k].push(m[k]);
    t.profs.push(m.prof);
    if (isDir) {
      // exact mode: number of text pixels (>= 30 % of the text contrast above the background, in this or the previous frame)
      // whose RGB value changed by more than 2 levels (of 255) against the previous frame of this window. Pictures that fade next to
      // the text (a shot's drop shadow reaches into the box) are dark, never that bright, so they do not count.
      const [x0, y0, x1, y1] = t.region;
      const bw = x1 - x0;
      const curRgb = Buffer.allocUnsafe(bw * 3 * (y1 - y0));
      const curGray = new Uint8Array(bw * (y1 - y0));
      let o = 0, g = 0;
      for (let y = y0; y < y1; y++) { fr.data.copy(curRgb, o, (y * W + x0) * 3, (y * W + x1) * 3); o += bw * 3; for (let x = x0; x < x1; x++) curGray[g++] = gray[y * W + x]; }
      if (t.prevRgb) {
        const thr = 0.3 * t.ref.contrast;
        let d = 0;
        for (let i = 0; i < curGray.length; i++) {
          if ((curGray[i] - t.ref.bg) * t.ref.sign < thr && (t.prevGray[i] - t.ref.bg) * t.ref.sign < thr) continue;
          const dr = Math.abs(curRgb[i * 3] - t.prevRgb[i * 3]), dg = Math.abs(curRgb[i * 3 + 1] - t.prevRgb[i * 3 + 1]), db = Math.abs(curRgb[i * 3 + 2] - t.prevRgb[i * 3 + 2]);
          const m2 = Math.max(dr, dg, db);
          if (m2 > 2) { d++; if (m2 > (t.maxDelta || 0)) t.maxDelta = m2; } // 1-2 levels: the translucent caption box over a picture that fades behind it
        }
        t.diff.push(d);
      }
      t.prevRgb = curRgb; t.prevGray = curGray;
    }
  }
}

const results = [];
for (const t of targets) {
  if (t.idx.length < 5) continue;
  t.series.shift = shifts(t.profs);
  t.profs = null;
  const j = judge(t.series, t.idx, isDir);
  if (isDir) {
    const total = t.diff.reduce((p, c) => p + c, 0);
    j.frameDiff = total; j.maxDelta = t.maxDelta || 0;
    if (total > 0) { j.ok = false; j.why.push(`${total} text pixels differ between consecutive frames`); }
  }
  results.push({ t, j });
}

const fmt = (x) => (Number.isInteger(x) ? String(x) : x.toFixed(3));
const lines = [];
lines.push(`# Text stability check: \`${path.basename(path.resolve(input))}\``);
lines.push('');
lines.push(`Input: ${isDir ? 'PNG frames (exact mode)' : 'MP4 (decoded with ffmpeg)'}, ${seen} frames read, ${results.length} measurements (${results.filter((r) => r.t.kind !== 'caption').length} text/pill elements, ${results.filter((r) => r.t.kind === 'caption').length} caption cues).`);
lines.push(`Rules: left and right end do not change (${isDir ? 'exactly' : 'at most 2 changes per window: an encoder may re-code a still picture once'}); centre shift <= ${isDir ? '0.03' : '0.15'} px; no periodic pattern against frame mod 2..8${isDir ? '; no text pixel changes between consecutive frames' : ''}. Window: scene start + 1.6 s to scene end - 0.5 s (cue start + 0.25 s to end - 0.25 s).`);
lines.push('');
lines.push(`| Measurement | Frames | Left end: range (px) / changes | Right end: range (px) / changes | Centre shift range (px) | First left-end values | ${isDir ? 'Changed text pixels | ' : ''}Result |`);
lines.push(`|---|---|---|---|---|---|${isDir ? '---|' : ''}---|`);
for (const { t, j } of results) {
  const sample = t.series.left.slice(0, 12).join(' ');
  lines.push(`| ${t.label} (${t.t0.toFixed(1)}-${t.t1.toFixed(1)} s) | ${t.idx.length} | ${fmt(j.rangeLeft)} / ${j.changesLeft} | ${fmt(j.rangeRight)} / ${j.changesRight} | ${fmt(j.rangeShift)} | ${sample} | ${isDir ? `${j.frameDiff}${j.frameDiff ? ` (max step ${j.maxDelta})` : ''} | ` : ''}${j.ok ? 'PASS' : 'FAIL: ' + j.why.join('; ')} |`);
}
const failed = results.filter((r) => !r.j.ok);
const periodicFails = results.filter((r) => r.j.periodic.length);
lines.push('');
lines.push(`Summary: ${results.length - failed.length} of ${results.length} measurements pass; ${periodicFails.length} show a periodic pattern.`);
if (periodicFails.length) {
  const mods = new Map();
  for (const r of periodicFails) for (const p of r.j.periodic) mods.set(p.m, (mods.get(p.m) || 0) + 1);
  lines.push(`Periods found (frame mod m, number of findings): ${[...mods].sort((x, y) => y[1] - x[1]).map(([m, c]) => `${m}: ${c}`).join(', ')}.`);
  const ex = periodicFails.find((r) => r.j.periodic.some((p) => p.m === 6)) || periodicFails[0];
  const p6 = ex.j.periodic.find((p) => p.m === 6) || ex.j.periodic[0];
  lines.push(`Example (${ex.t.label}): ${p6.series} by frame mod ${p6.m} = ${p6.means.map((v) => (v === null ? '-' : v.toFixed(2))).join(' ')}.`);
}
lines.push('');
lines.push(failed.length ? '**text stability: FAIL**' : '**text stability: PASS**');
const text = lines.join('\n');
console.log(text);
if (a.report) fs.writeFileSync(a.report, text + '\n');
if (a.json) fs.writeFileSync(a.json, JSON.stringify(results.map(({ t, j }) => ({ id: t.id, label: t.label, window: [t.t0, t.t1], frames: t.idx.length, left: t.series.left, right: t.series.right, cx: t.series.cx, shift: t.series.shift, ok: j.ok, why: j.why })), null, 1));
process.exit(failed.length ? 1 : 0);
