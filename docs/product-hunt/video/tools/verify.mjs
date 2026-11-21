#!/usr/bin/env node
// Checks the finished MP4 (and GIF) against the delivery spec and prints the evidence as a Markdown table.
// usage: node tools/verify.mjs --mp4 <file> --mp4-probe <ffprobe.json> [--gif <file> --gif-probe <ffprobe.json>] [--gif-max <bytes>] [--audio]
// Exit code 1 when any check fails.
import fs from 'node:fs';

const a = {};
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) if (argv[i].startsWith('--')) a[argv[i].slice(2)] = argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[++i] : true;
if (!a.mp4 || !a['mp4-probe']) { console.error('usage: verify.mjs --mp4 f --mp4-probe f.json [--gif f --gif-probe f.json]'); process.exit(2); }

const rows = [];
let failed = false;
const check = (name, value, ok) => { rows.push([name, String(value), ok ? 'PASS' : 'FAIL']); if (!ok) failed = true; };
const fraction = (s) => { const [n, d] = String(s).split('/').map(Number); return d ? n / d : n; };
const STRUCTURAL = new Set(['major_brand', 'minor_version', 'compatible_brands']); // ftyp box fields, not metadata
const GENERIC_HANDLERS = new Set(['', 'VideoHandler', 'SoundHandler']);

function topLevelBoxes(file) {
  const fd = fs.openSync(file, 'r');
  const size = fs.fstatSync(fd).size;
  const boxes = [];
  let pos = 0;
  const head = Buffer.alloc(16);
  while (pos + 8 <= size && boxes.length < 64) {
    fs.readSync(fd, head, 0, 16, pos);
    let len = head.readUInt32BE(0);
    const type = head.toString('latin1', 4, 8);
    if (len === 1) len = Number(head.readBigUInt64BE(8));
    if (len === 0) len = size - pos;
    boxes.push(type);
    if (len < 8) break;
    pos += len;
  }
  fs.closeSync(fd);
  return boxes;
}

const probe = JSON.parse(fs.readFileSync(a['mp4-probe'], 'utf8'));
const v = probe.streams.find((s) => s.codec_type === 'video');
const audio = probe.streams.filter((s) => s.codec_type === 'audio');
const duration = Number(probe.format.duration);
check('MP4 size (WxH)', `${v.width}x${v.height}`, v.width === 1920 && v.height === 1080);
check('MP4 video codec', `${v.codec_name} (${v.profile})`, v.codec_name === 'h264');
check('MP4 pixel format', v.pix_fmt, v.pix_fmt === 'yuv420p');
check('MP4 frame rate', `${fraction(v.avg_frame_rate)} fps`, [25, 30].includes(fraction(v.avg_frame_rate)));
check('MP4 duration', `${duration.toFixed(2)} s`, duration >= 60 && duration <= 90);
check('MP4 audio streams', audio.length, a.audio ? audio.length === 1 : audio.length === 0);
const boxes = topLevelBoxes(a.mp4);
check('MP4 faststart (moov before mdat)', boxes.join(' > '), boxes.indexOf('moov') >= 0 && boxes.indexOf('moov') < boxes.indexOf('mdat'));
const fmtTags = Object.entries(probe.format.tags || {}).filter(([k]) => !STRUCTURAL.has(k));
check('MP4 container metadata tags', fmtTags.length ? JSON.stringify(Object.fromEntries(fmtTags)) : 'none', fmtTags.length === 0);
const streamTags = probe.streams.flatMap((s) => Object.entries(s.tags || {}).filter(([k, val]) => !(k === 'handler_name' && GENERIC_HANDLERS.has(val)) && !(k === 'language' && val === 'und') && k !== 'vendor_id'));
check('MP4 stream metadata tags (language und, a generic handler name and a zero vendor id are muxer defaults, not metadata)', streamTags.length ? JSON.stringify(streamTags) : 'none', streamTags.length === 0);
const handler = probe.streams.map((s) => s.tags?.handler_name).filter((x) => x !== undefined);
rows.push(['MP4 handler_name (muxer default, informational)', handler.length ? JSON.stringify(handler) : 'absent', 'INFO']);
rows.push(['MP4 size', `${(fs.statSync(a.mp4).size / 1048576).toFixed(2)} MiB`, 'INFO']);

if (a.gif) {
  const g = JSON.parse(fs.readFileSync(a['gif-probe'], 'utf8'));
  const gv = g.streams.find((s) => s.codec_type === 'video');
  const gd = Number(g.format.duration);
  const bytes = fs.statSync(a.gif).size;
  const buf = fs.readFileSync(a.gif);
  const net = buf.indexOf('NETSCAPE2.0');
  const loop = net >= 0 ? buf.readUInt16LE(net + 13) : null;
  check('GIF format', gv.codec_name, gv.codec_name === 'gif' && buf.toString('latin1', 0, 6).startsWith('GIF8'));
  check('GIF size (WxH)', `${gv.width}x${gv.height}`, gv.width <= 1920);
  check('GIF duration', `${gd.toFixed(2)} s`, gd >= 10 && gd <= 20);
  check('GIF loops forever (NETSCAPE2.0, count 0)', loop === null ? 'no loop extension' : `loop count ${loop}`, loop === 0);
  const max = Number(a['gif-max']) || 0;
  check('GIF file size', `${(bytes / 1048576).toFixed(2)} MiB${max ? ` (limit ${(max / 1048576).toFixed(2)} MiB)` : ''}`, !max || bytes <= max);
  const gtags = Object.entries(g.format.tags || {});
  check('GIF metadata tags', gtags.length ? JSON.stringify(Object.fromEntries(gtags)) : 'none', gtags.length === 0);
  rows.push(['GIF frame rate', `${fraction(gv.avg_frame_rate).toFixed(2)} fps`, 'INFO']);
}

console.log('| Check | Result | |\n|---|---|---|');
for (const r of rows) console.log(`| ${r[0]} | ${r[1]} | ${r[2]} |`);
console.log(failed ? '\nverify: FAILED' : '\nverify: all checks passed');
process.exit(failed ? 1 : 0);
