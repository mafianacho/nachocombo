#!/usr/bin/env node
// Looks for forbidden strings (privacy/forbidden-patterns.json) in the video's source material and outputs.
//   text files (html css js mjs json md srt sh txt toml yml yaml) : every line
//   PNG                                                           : the text-carrying chunks (tEXt, zTXt, iTXt, eXIf, tIME, iCCP) and the raw bytes
//   everything else (MP4, GIF, ...)                               : the raw bytes, as latin-1
// usage: node privacy/scan-forbidden.mjs <file|dir>...  [--selftest]   (exit 1 on any hit)
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const patternsFile = path.join(here, 'forbidden-patterns.json');
const patterns = JSON.parse(fs.readFileSync(patternsFile, 'utf8')).patterns.map((p) => ({ ...p, re: new RegExp(p.regex, 'gi'), binRe: new RegExp(p.binaryRegex || p.regex, 'gi') }));
const TEXT = new Set(['.html', '.css', '.js', '.mjs', '.json', '.md', '.srt', '.sh', '.txt', '.toml', '.yml', '.yaml']);
const SKIP_DIRS = new Set(['.git', 'node_modules']);

function walk(p, out = []) {
  const st = fs.statSync(p);
  if (st.isDirectory()) {
    if (SKIP_DIRS.has(path.basename(p))) return out;
    for (const f of fs.readdirSync(p).sort()) walk(path.join(p, f), out);
  } else out.push(p);
  return out;
}

function pngChunks(buf) {
  const chunks = [];
  let pos = 8;
  while (pos + 12 <= buf.length) {
    const len = buf.readUInt32BE(pos);
    const type = buf.toString('latin1', pos + 4, pos + 8);
    chunks.push({ type, data: buf.subarray(pos + 8, pos + 8 + len) });
    pos += 12 + len;
    if (type === 'IEND') break;
  }
  return chunks;
}

function scanText(label, text, hits, lineAware, binary = false) {
  const lines = lineAware ? text.split('\n') : [text];
  lines.forEach((line, i) => {
    for (const p of patterns) {
      const re = binary ? p.binRe : p.re;
      re.lastIndex = 0;
      let m;
      while ((m = re.exec(line))) {
        hits.push({ file: label, line: lineAware ? i + 1 : 0, pattern: p.name, match: m[0].length > 60 ? `${m[0].slice(0, 57)}...` : m[0] });
        if (m[0].length === 0) re.lastIndex++;
      }
    }
  });
}

export function scanFile(file) {
  const hits = [];
  const notes = [];
  const ext = path.extname(file).toLowerCase();
  const buf = fs.readFileSync(file);
  if (TEXT.has(ext)) scanText(file, buf.toString('utf8'), hits, true);
  else {
    if (ext === '.png' && buf.subarray(1, 4).toString('latin1') === 'PNG') {
      for (const c of pngChunks(buf)) {
        if (['tEXt', 'zTXt', 'iTXt', 'eXIf', 'tIME', 'iCCP'].includes(c.type)) {
          notes.push(c.type);
          let text = c.data.toString('latin1');
          if (c.type === 'zTXt') { try { text += zlib.inflateSync(c.data.subarray(c.data.indexOf(0) + 2)).toString('latin1'); } catch { /* ignore */ } }
          scanText(`${file} [${c.type}]`, text, hits, false, true);
        }
      }
    }
    scanText(file, buf.toString('latin1'), hits, false, true);
  }
  return { hits, notes };
}

function main(targets) {
  const files = targets.flatMap((t) => walk(t)).filter((f) => path.resolve(f) !== patternsFile);
  const hits = [];
  const kinds = {};
  const pngNotes = [];
  for (const f of files) {
    const ext = path.extname(f).toLowerCase() || '(none)';
    kinds[ext] = (kinds[ext] || 0) + 1;
    const r = scanFile(f);
    hits.push(...r.hits);
    if (r.notes.length) pngNotes.push(`${f}: ${[...new Set(r.notes)].join(', ')}`);
  }
  console.log(`scanned ${files.length} files: ${Object.entries(kinds).map(([k, n]) => `${n} ${k}`).join(', ')}`);
  console.log(`patterns: ${patterns.length} (${patterns.map((p) => p.name).join(', ')})`);
  if (pngNotes.length) console.log(`PNG files carrying text/metadata chunks (checked above, listed for review):\n  ${pngNotes.join('\n  ')}`);
  if (hits.length) {
    console.log(`\nFORBIDDEN STRINGS FOUND: ${hits.length}`);
    for (const h of hits) console.log(`  ${h.file}${h.line ? `:${h.line}` : ''}  [${h.pattern}]  ${h.match}`);
  } else console.log('forbidden strings found: 0');
  return hits.length;
}

function selftest() {
  // Positive control: build strings that must be caught without writing them literally in any file of the repository.
  const tmp = fs.mkdtempSync(path.join(process.env.SCAN_TMP || process.cwd(), '.scan-selftest-'));
  try {
    const bad = ['/ho' + 'me/someone/x', '/Us' + 'ers/someone/x', 'someone@' + 'gmail.com', 'boss@' + 'mafianacho.com', 'na' + 'chofather', 'a@b' + '.org'];
    fs.writeFileSync(path.join(tmp, 'bad.html'), bad.join('\n'));
    fs.writeFileSync(path.join(tmp, 'bad.bin'), Buffer.from(`xx${bad[0]}yy\u0000someone@${'gm' + 'ail'}.com\u0000${'T@' + 'h.GkY'}`, 'latin1'));
    fs.writeFileSync(path.join(tmp, 'good.srt'), '1\n00:00:00,000 --> 00:00:02,000\nHello, user@example.com\n');
    const a = scanFile(path.join(tmp, 'bad.html')).hits.length;
    const b = scanFile(path.join(tmp, 'bad.bin')).hits.length;
    const c = scanFile(path.join(tmp, 'good.srt')).hits.length;
    const ok = a >= bad.length && b >= 2 && b <= 4 && c === 0;
    console.log(`selftest: bad text file ${a} hits (want >= ${bad.length}), bad binary ${b} (want 2 to 4; a random-looking byte run such as a one-letter local part must not count), clean file ${c} (want 0) -> ${ok ? 'OK' : 'FAILED'}`);
    return ok ? 0 : 1;
  } finally { fs.rmSync(tmp, { recursive: true, force: true }); }
}

const argv = process.argv.slice(2);
if (import.meta.url === pathToFileUrl(process.argv[1])) {
  if (argv.includes('--selftest')) process.exit(selftest());
  const targets = argv.filter((x) => !x.startsWith('--'));
  if (!targets.length) { console.error('usage: scan-forbidden.mjs <file|dir>... | --selftest'); process.exit(2); }
  process.exit(main(targets) ? 1 : 0);
}
function pathToFileUrl(p) { return new URL(`file://${path.resolve(p)}`).href; }
