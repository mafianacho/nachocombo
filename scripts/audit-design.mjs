#!/usr/bin/env node
// usage: PLAYWRIGHT_CORE=<playwright-core dir> node scripts/audit-design.mjs <repo root>  — prints per scene/theme what is clipped or overflowing.
// Geometry audit of the pet mockup: clipped log content, text overflow, elements outside the stage, overlaps of chat vs pet.
import http from 'node:http'; import fs from 'node:fs'; import path from 'node:path'; import { pathToFileURL } from 'node:url';
const root = process.argv[2];
const { chromium } = await import(pathToFileURL(path.join(process.env.PLAYWRIGHT_CORE, 'index.mjs')).href);
const server = http.createServer((req, res) => { const f = path.join(root, decodeURIComponent(new URL(req.url, 'http://x').pathname));
  if (!fs.existsSync(f) || fs.statSync(f).isDirectory()) { res.writeHead(404); return res.end(); } res.writeHead(200, { 'content-type': f.endsWith('.css') ? 'text/css' : f.endsWith('.js') ? 'text/javascript' : f.endsWith('.png') ? 'image/png' : 'text/html' }); fs.createReadStream(f).pipe(res); });
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const base = `http://127.0.0.1:${server.address().port}/design/web/index.html`;
const b = await chromium.launch(); const p = await b.newPage();
await p.goto(base); const scenes = Object.keys(await p.evaluate(() => window.SCENES));
for (const s of scenes) for (const th of ['light', 'dark']) {
  await p.goto(`${base}?scene=${s}&theme=${th}`); await p.evaluate(() => document.fonts.ready);
  const r = await p.evaluate(() => {
    const out = []; const stage = document.querySelector('.stage').getBoundingClientRect();
    const log = document.querySelector('.log');
    if (log) { const kids = [...log.children]; const top = Math.min(...kids.map((k) => k.getBoundingClientRect().top)); if (top < log.getBoundingClientRect().top - 0.5) out.push(`log clipped by ${Math.round(log.getBoundingClientRect().top - top)}px`); }
    for (const el of document.querySelectorAll('.stage *')) {
      const cs = getComputedStyle(el); if (cs.display === 'none') continue;
      const rc = el.getBoundingClientRect(); if (!rc.width) continue;
      if (el.scrollWidth > el.clientWidth + 1 && cs.overflowX !== 'visible' && cs.textOverflow !== 'ellipsis' && !el.classList.contains('log')) out.push(`text overflow: ${el.className || el.tagName} "${el.textContent.slice(0, 30)}"`);
      if (!el.closest('.chat::after') && (rc.right > stage.right + 0.5 || rc.left < stage.left - 0.5 || rc.top < stage.top - 0.5 || rc.bottom > stage.bottom + 0.5)) out.push(`outside stage: ${el.className || el.tagName}`);
      const fs = parseFloat(cs.fontSize); if (el.childNodes.length && [...el.childNodes].some((n) => n.nodeType === 3 && n.textContent.trim()) && fs < 11) out.push(`font ${fs}px: ${el.className}`);
    }
    const chat = document.querySelector('.chat'), pet = document.querySelector('.stage > .pet');
    if (chat && pet) { const a = chat.getBoundingClientRect(), c = pet.getBoundingClientRect(); if (a.bottom > c.top) out.push('chat overlaps pet'); out.push(`gap chat→pet ${Math.round(c.top - a.bottom)}px`); }
    return out;
  });
  const bad = r.filter((x) => !x.startsWith('gap'));
  console.log(`${s}/${th}: ${bad.length ? bad.join(' | ') : 'ok'} ${r.filter((x) => x.startsWith('gap')).join('')}`);
}
await b.close(); server.close();
