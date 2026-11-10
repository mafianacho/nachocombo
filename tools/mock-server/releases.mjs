#!/usr/bin/env node
// Mock GitHub Releases for the auto-update round trip (dev/test only, loopback only, zero dependencies).
//   GET /repos/mafianacho/nachocombo/releases/latest  -> <dir>/latest.json (rewritten by the test between steps)
//   GET /files/<name>                                 -> <dir>/files/<name>
// usage: node tools/mock-server/releases.mjs --port 8793 --dir build/update-roundtrip/feed
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';

const args = process.argv.slice(2);
const opt = (n, d) => { const i = args.indexOf(`--${n}`); return i >= 0 ? args[i + 1] : d; };
const PORT = Number(opt('port', '8793'));
const DIR = path.resolve(opt('dir', '.'));

http.createServer((req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1');
  let file = null;
  if (url.pathname === '/repos/mafianacho/nachocombo/releases/latest') file = path.join(DIR, 'latest.json');
  else if (url.pathname.startsWith('/files/')) {
    const name = path.basename(url.pathname);
    if (/^[A-Za-z0-9._-]+$/.test(name)) file = path.join(DIR, 'files', name);
  }
  console.log(JSON.stringify({ t: new Date().toISOString(), method: req.method, path: url.pathname }));
  if (!file || !fs.existsSync(file)) { res.writeHead(404); return res.end('{}'); }
  res.writeHead(200, { 'content-type': file.endsWith('.json') ? 'application/json' : 'application/octet-stream' });
  fs.createReadStream(file).pipe(res);
}).listen(PORT, '127.0.0.1');
