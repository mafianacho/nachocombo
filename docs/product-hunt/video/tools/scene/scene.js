'use strict';
// Scene compositor for the Nacho Combo intro video. Pure function of time: window.renderAt(ms) lays out one frame from
// timeline.json, so tools/render.mjs can screenshot frame N at exactly N/fps seconds (no CSS transitions, no timers).
// Elements: shot (a capture PNG: crop, fit, zoom, pan, bob), text, pill, rect, click (cursor + ripple).
(() => {
  const clamp = (x, a = 0, b = 1) => Math.min(b, Math.max(a, x));
  const easeOut = (t) => 1 - Math.pow(1 - clamp(t), 3);
  const easeInOut = (t) => { t = clamp(t); return t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2; };
  const lerp = (a, b, t) => a + (b - a) * t;
  const COLORS = { accent: '#ffc43d', ink: '#2a1708', text: '#f6efe3', muted: '#b9ab98', white: '#ffffff' };
  const color = (c) => COLORS[c] || c || COLORS.text;
  const CURSOR = '<svg viewBox="0 0 24 24" width="44" height="44"><path d="M3 2 L3 19 L7.6 14.8 L10.8 22 L14.2 20.5 L11 13.4 L17.6 13.2 Z" fill="#fff" stroke="#1b1b1b" stroke-width="1.5" stroke-linejoin="round"/></svg>';

  let timeline, cues, canvas, captionEl, captionBox, draftEl, fadeEl;
  const scenes = [];
  const rects = {};
  window.__errors = [];
  window.addEventListener('error', (e) => window.__errors.push(String(e.message || e)));

  function visibility(spec, tl, defaultDur) {
    const t0 = spec.inAt ?? 0;
    const inDur = spec.inDur ?? defaultDur ?? 0.5;
    if (tl < t0) return { a: 0, p: 0 };
    const p = spec.in === 'cut' || inDur <= 0 ? 1 : clamp((tl - t0) / inDur);
    let a = spec.in === 'cut' ? 1 : spec.in === 'wipe' ? 1 : easeOut(p);
    if (spec.outAt != null) {
      const outDur = spec.outDur ?? 0.4;
      if (tl > spec.outAt) a *= 1 - clamp((tl - spec.outAt) / outDur);
    }
    return { a, p };
  }

  function entryTransform(spec, p) {
    const e = easeOut(p);
    switch (spec.in) {
      case 'from-right': return { t: `translateX(${(1 - e) * 160}px)` };
      case 'from-left': return { t: `translateX(${-(1 - e) * 160}px)` };
      case 'from-below': return { t: `translateY(${(1 - e) * 50}px)` };
      case 'pop': return { t: `scale(${0.92 + 0.08 * e})` };
      case 'wipe': return { t: `translateX(${(1 - e) * 70}px)`, clip: `inset(0 0 0 ${(1 - e) * 100}%)` };
      default: return { t: '' };
    }
  }

  function place(el, spec) {
    el.style.left = `${spec.x}px`;
    el.style.top = `${spec.y}px`;
    if (spec.w != null) el.style.width = `${spec.w}px`;
  }

  function applyVisibility(el, spec, tl, extraTransform) {
    const { a, p } = visibility(spec, tl);
    el.style.opacity = a;
    el.style.display = a <= 0.001 ? 'none' : 'block';
    const { t, clip } = entryTransform(spec, p);
    el.style.transform = `${t} ${extraTransform || ''}`.trim();
    el.style.clipPath = clip || '';
  }

  function buildShot(spec, images, duration) {
    const im = images[spec.capture];
    if (!im) throw new Error(`timeline: unknown capture "${spec.capture}"`);
    const nw = im.naturalWidth, nh = im.naturalHeight;
    const [cl = 0, ct = 0, cr = 0, cb = 0] = spec.crop || [];
    const cw = nw * (1 - cl - cr), ch = nh * (1 - ct - cb);
    const [rx, ry, rw, rh] = spec.region;
    const s = Math.min(Math.min(rw / cw, rh / ch), spec.maxScale ?? 1.5);
    const w = cw * s, h = ch * s;
    const left = rx + (rw - w) * (spec.align?.[0] ?? 0.5);
    const top = ry + (rh - h) * (spec.align?.[1] ?? 0.5);
    const el = document.createElement('div');
    el.className = 'el shot' + (spec.plain ? ' plain' : '');
    Object.assign(el.style, { left: `${left}px`, top: `${top}px`, width: `${w}px`, height: `${h}px` });
    if (spec.radius != null) el.style.borderRadius = `${spec.radius}px`;
    const pan = document.createElement('div');
    pan.className = 'pan';
    const img = document.createElement('img');
    img.src = im.src;
    Object.assign(img.style, { width: `${nw * s}px`, height: `${nh * s}px`, left: `${-nw * cl * s}px`, top: `${-nh * ct * s}px` });
    pan.appendChild(img);
    el.appendChild(pan);
    if (spec.id) rects[spec.id] = { left, top, w, h };
    const [z0, z1] = spec.zoom || [1, 1];
    const f = spec.focus || [0.5, 0.5];
    const [f0, f1] = Array.isArray(f[0]) ? f : [f, f];
    const t0 = spec.inAt ?? 0;
    const zdur = spec.zoomDur ?? ((spec.outAt ?? duration) - t0);
    return {
      el,
      update(tl) {
        const k = easeInOut((tl - t0) / Math.max(zdur, 0.001));
        pan.style.transformOrigin = `${lerp(f0[0], f1[0], k) * 100}% ${lerp(f0[1], f1[1], k) * 100}%`;
        pan.style.transform = `scale(${lerp(z0, z1, k)})`;
        const bob = spec.bob ? Math.sin((tl / spec.bob[1]) * Math.PI * 2) * spec.bob[0] : 0;
        applyVisibility(el, spec, tl, bob ? `translateY(${bob}px)` : '');
      },
    };
  }

  function buildText(spec, pill) {
    const el = document.createElement('div');
    if (pill) {
      el.className = 'el pill' + (spec.variant === 'ink' ? ' ink' : '');
      if (spec.size) el.style.fontSize = `${spec.size}px`;
    } else {
      el.className = `el text ${spec.font || 'plex'}`;
      el.style.fontSize = `${spec.size || 44}px`;
      if (spec.weight) el.style.fontWeight = spec.weight;
      el.style.color = color(spec.color);
      el.style.textAlign = spec.align || 'left';
      if (spec.lineHeight) el.style.lineHeight = spec.lineHeight;
    }
    el.textContent = spec.text;
    place(el, spec);
    if (pill && spec.align === 'right') el.style.transformOrigin = 'right top';
    return { el, update: (tl) => applyVisibility(el, spec, tl) };
  }

  function buildRect(spec) {
    const el = document.createElement('div');
    el.className = 'el rect';
    const [x, y, w, h] = spec.region;
    Object.assign(el.style, { left: `${x}px`, top: `${y}px`, width: `${w}px`, height: `${h}px`, borderRadius: `${spec.radius ?? 0}px`, background: spec.fill || 'transparent' });
    if (spec.stroke) el.style.border = `2px solid ${spec.stroke}`;
    return { el, update: (tl) => applyVisibility(el, spec, tl) };
  }

  function buildClick(spec) {
    const wrap = document.createElement('div');
    wrap.className = 'el';
    wrap.style.left = '0'; wrap.style.top = '0';
    const cursor = document.createElement('div');
    cursor.className = 'cursor';
    cursor.innerHTML = CURSOR;
    const ripple = document.createElement('div');
    ripple.className = 'ripple';
    wrap.append(ripple, cursor);
    const travel = spec.travel ?? 0.7, hold = spec.hold ?? 0.9, rippleDur = 0.55;
    const pos = (f) => {
      const r = rects[spec.on];
      if (!r) throw new Error(`timeline: click refers to unknown shot id "${spec.on}"`);
      return [r.left + f[0] * r.w, r.top + f[1] * r.h];
    };
    return {
      el: wrap,
      update(tl) {
        const tt = tl - spec.t0;
        if (tt < 0 || tt > travel + hold + 0.3) { wrap.style.display = 'none'; return; }
        wrap.style.display = 'block';
        const [x0, y0] = pos(spec.from), [x1, y1] = pos(spec.at);
        const k = easeInOut(tt / travel);
        const x = lerp(x0, x1, k), y = lerp(y0, y1, k);
        cursor.style.transform = `translate(${x}px, ${y}px)`;
        cursor.style.left = '0'; cursor.style.top = '0';
        const fadeIn = clamp(tt / 0.15), fadeOut = 1 - clamp((tt - travel - hold) / 0.3);
        cursor.style.opacity = Math.min(fadeIn, fadeOut);
        const ra = (tt - travel) / rippleDur;
        if (ra >= 0 && ra <= 1) {
          const size = lerp(24, 110, easeOut(ra));
          Object.assign(ripple.style, { display: 'block', width: `${size}px`, height: `${size}px`, left: `${x1 - size / 2}px`, top: `${y1 - size / 2}px`, opacity: 1 - ra });
        } else ripple.style.display = 'none';
      },
    };
  }

  async function init(payload) {
    timeline = payload.timeline;
    cues = payload.cues;
    canvas = document.getElementById('canvas');
    const images = {};
    await Promise.all(Object.entries(payload.captures).map(([id, url]) => new Promise((resolve, reject) => {
      const im = new Image();
      im.onload = () => { images[id] = im; resolve(); };
      im.onerror = () => reject(new Error(`image failed to load: ${id}`));
      im.src = url;
    })));
    await Promise.all(['400 40px Anton', '400 40px "IBM Plex Sans"', '500 40px "IBM Plex Sans"', '600 40px "IBM Plex Sans"', '700 40px "IBM Plex Sans"', '500 26px "IBM Plex Mono"', '600 26px "IBM Plex Mono"']
      .map((f) => document.fonts.load(f, 'Aa 0123 .,:;')));

    timeline.scenes.forEach((spec, index) => {
      const dur = spec.end - spec.start;
      const sc = document.createElement('div');
      sc.className = `scene bg-${spec.bg || 'dark'}`;
      const items = [];
      for (const e of spec.elements || []) {
        let item;
        if (e.type === 'shot') item = buildShot(e, images, dur);
        else if (e.type === 'text') item = buildText(e, false);
        else if (e.type === 'pill') item = buildText(e, true);
        else if (e.type === 'rect') item = buildRect(e);
        else if (e.type === 'click') item = buildClick(e);
        else throw new Error(`timeline: unknown element type "${e.type}" in ${spec.id}`);
        items.push(item);
        sc.appendChild(item.el);
      }
      canvas.appendChild(sc);
      scenes.push({ spec, el: sc, items, fade: index === 0 ? (timeline.fadeIn ?? 0.4) : (spec.transition === 'cut' ? 0 : (spec.fade ?? timeline.fade ?? 0.45)) });
    });

    captionEl = document.createElement('div');
    captionEl.id = 'captions';
    captionBox = document.createElement('div');
    captionBox.className = 'box';
    captionEl.appendChild(captionBox);
    canvas.appendChild(captionEl);

    draftEl = document.createElement('div');
    draftEl.id = 'draft';
    draftEl.innerHTML = '<div class="big">DRAFT</div><div class="tag">DRAFT · STAND-IN FRAMES · NOT A DELIVERABLE</div>';
    if (payload.draft) draftEl.style.display = 'block';
    canvas.appendChild(draftEl);

    fadeEl = document.createElement('div');
    Object.assign(fadeEl.style, { position: 'absolute', inset: '0', background: '#000', opacity: 0, pointerEvents: 'none' });
    canvas.appendChild(fadeEl);
    return { duration: timeline.duration, scenes: timeline.scenes.length };
  }

  function renderAt(ms) {
    const t = ms / 1000;
    scenes.forEach((s, i) => {
      const next = scenes[i + 1];
      const visible = t >= s.spec.start && (!next || t < next.spec.start + next.fade + 0.001);
      s.el.style.display = visible ? 'block' : 'none';
      if (!visible) return;
      s.el.style.opacity = s.fade > 0 ? clamp((t - s.spec.start) / s.fade) : 1;
      const tl = t - s.spec.start;
      s.items.forEach((item) => item.update(tl));
    });
    const cue = cues.find((c) => t >= c.start && t < c.end);
    if (!cue) captionEl.style.display = 'none';
    else {
      captionEl.style.display = 'flex';
      if (captionBox.dataset.cue !== String(cue.index)) {
        captionBox.dataset.cue = String(cue.index);
        captionBox.replaceChildren(...cue.lines.map((line) => { const d = document.createElement('div'); d.textContent = line; return d; }));
      }
      captionEl.style.opacity = Math.min(clamp((t - cue.start) / 0.12), clamp((cue.end - t) / 0.12));
    }
    const fadeOut = timeline.fadeOut ?? 0.6;
    fadeEl.style.opacity = clamp((t - (timeline.duration - fadeOut)) / fadeOut);
  }

  window.initScene = init;
  window.renderAt = renderAt;
})();
