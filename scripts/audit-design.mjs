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
    // Korean line breaks: no eojeol (space-separated word) split over two lines, no one-word last line in a bubble.
    for (const el of document.querySelectorAll('.bubble, .line span, .card .q span, .hello b, .signin p')) {
      const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT); const chars = [];
      for (let n; (n = walker.nextNode());) { for (let i = 0; i < n.textContent.length; i++) {
        const r = document.createRange(); r.setStart(n, i); r.setEnd(n, i + 1); const b = r.getBoundingClientRect();
        const ch = n.textContent[i];
        if (/\s/.test(ch)) chars.push({ ch: ' ', top: null });  // a space (even collapsed or at a line end) separates words
        else if (b.width) chars.push({ ch, top: Math.round(b.top) });
      }
      chars.push({ ch: ' ', top: null }); }  // text nodes of different elements are different words
      const lines = []; for (const c of chars) { if (c.top === null) { if (lines.length) lines[lines.length - 1].text += ' '; continue; } if (!lines.length || Math.abs(lines[lines.length - 1].top - c.top) > 4) lines.push({ top: c.top, text: '' }); lines[lines.length - 1].text += c.ch; }
      let word = [], prevTop = null;
      for (const c of chars) { if (/\s/.test(c.ch)) { word = []; continue; } if (word.length && Math.abs(c.top - prevTop) > 4) out.push(`word split: "${el.textContent.trim().slice(0, 24)}" at "${word.map((w) => w.ch).join('')}${c.ch}"`); word.push(c); prevTop = c.top; }
      if (el.classList.contains('bubble') && lines.length > 1 && !/\s/.test(lines[lines.length - 1].text.trim())) out.push(`orphan last line: "${lines[lines.length - 1].text.trim()}" in "${el.textContent.trim().slice(0, 24)}"`);
    }
    // Floating text (absolutely placed, no background of its own or of a parent) over other text: unreadable.
    const textRects = (el) => { const rs = []; const w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
      for (let n; (n = w.nextNode());) { if (!n.textContent.trim()) continue; const rg = document.createRange(); rg.selectNodeContents(n);
        for (const rc of rg.getClientRects()) if (rc.width && rc.height) rs.push({ rc, node: n }); } return rs; };
    // A backdrop only counts on the floating element or on parents that do not also hold the text below it.
    const covers = (e) => { const cs = getComputedStyle(e);
      // A see-through fill only counts with a blur behind it (the app's glass); a plain fill must be (nearly) opaque.
      const m = cs.backgroundColor.match(/rgba?\(([^)]+)\)/); const parts = m ? m[1].split(',') : [];
      const alpha = !m ? 0 : parts.length < 4 ? 1 : parseFloat(parts[3]);
      return alpha >= 0.98 || (alpha > 0.5 && cs.backdropFilter && cs.backdropFilter !== 'none') || (cs.backgroundImage && cs.backgroundImage !== 'none'); };
    const allText = textRects(document.querySelector('.stage'));
    for (const el of document.querySelectorAll('.stage *')) {
      const cs = getComputedStyle(el); if (cs.position !== 'absolute' && cs.position !== 'fixed') continue;
      let hit = null;
      for (const { rc: a } of textRects(el)) { for (const { rc: b, node } of allText) {
        if (el.contains(node)) continue;
        if (!(a.left < b.right - 1 && b.left < a.right - 1 && a.top < b.bottom - 1 && b.top < a.bottom - 1)) continue;
        let shielded = false;
        for (let e = el; e && !e.contains(node); e = e.parentElement) if (covers(e)) { shielded = true; break; }
        if (!shielded) { hit = node; break; } }
        if (hit) break; }
      if (hit) out.push(`floating text over text: "${el.textContent.trim().slice(0, 24)}" over "${hit.textContent.trim().slice(0, 24)}"`);
    }
    const chat = document.querySelector('.chat'), pet = document.querySelector('.stage > .pet');
    if (chat && pet) { const a = chat.getBoundingClientRect(), c = pet.getBoundingClientRect(); if (a.bottom > c.top) out.push('chat overlaps pet'); out.push(`gap chat→pet ${Math.round(c.top - a.bottom)}px`); }
    return out;
  });
  const bad = r.filter((x) => !x.startsWith('gap'));
  console.log(`${s}/${th}: ${bad.length ? bad.join(' | ') : 'ok'} ${r.filter((x) => x.startsWith('gap')).join('')}`);
}
await b.close(); server.close();
