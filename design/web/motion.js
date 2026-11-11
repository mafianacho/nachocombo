// Nacho Pet motion model: which picture shows and how the character moves, as a pure function of time.
// Twin of Sources/NachoComboCore/Pet/PetMotion.swift: same rules, same numbers (design/tokens.json → tokens.js), and
// PetMotionTests replays scripts/motion-vectors.mjs's output to prove both give the same poses.
// Times in ms. Pose: dx/dy in points (+dy = up), scaleX/scaleY around the bottom centre, rotation in degrees (+ = clockwise).
(function (global) {
  const T = global.PET_TOKENS;
  const M = T.motion, A = T.motionAmount;
  const ASSET = { idle: 'idle', listening: 'calling', thinking: 'thinking', speaking: 'working', happy: 'happy',
    waiting: 'waiting', tired: 'tired', sleeping: 'eyes-closed' };
  const BLINK = { idle: 'eyes-closed', listening: 'calling-eyeless' };  // only where an eyes-shut twin of the same pose exists

  function bezier(spec) {
    const m = /^cubic-bezier\(([-\d.]+), ([-\d.]+), ([-\d.]+), ([-\d.]+)\)$/.exec(spec);
    const [x1, y1, x2, y2] = m.slice(1).map(Number);
    const bx = (u) => 3 * x1 * u * (1 - u) * (1 - u) + 3 * x2 * u * u * (1 - u) + u * u * u;
    const by = (u) => 3 * y1 * u * (1 - u) * (1 - u) + 3 * y2 * u * u * (1 - u) + u * u * u;
    return (x) => {
      if (x <= 0) return 0;
      if (x >= 1) return 1;
      let lo = 0, hi = 1;
      for (let i = 0; i < 40; i++) { const mid = (lo + hi) / 2; if (bx(mid) < x) lo = mid; else hi = mid; }
      return by((lo + hi) / 2);
    };
  }
  const standard = bezier(T.curve.standard), emphasized = bezier(T.curve.emphasized);

  // lowbias32 hash → [0, 1): the same blink times in Swift and JS for the same seed.
  function rand(seed, n) {
    let x = (seed ^ Math.imul(n + 1, 0x9e3779b9)) >>> 0;
    x ^= x >>> 16; x = Math.imul(x, 0x7feb352d) >>> 0;
    x ^= x >>> 15; x = Math.imul(x, 0x846ca68b) >>> 0;
    x ^= x >>> 16;
    return (x >>> 0) / 4294967296;
  }
  const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
  const wave = (phase) => 0.5 - 0.5 * Math.cos(2 * Math.PI * phase);  // 0 → 1 → 0 over one period

  class PetMotion {
    constructor({ face = 'idle', at = 0, reduceMotion = false, seed = 1 } = {}) {
      this.face = face; this.since = at; this.from = null; this.reduceMotion = reduceMotion; this.seed = seed >>> 0;
      this.pressedAt = null; this.releasedAt = null; this.pressDepth = 0;
      this.tiltFrom = 0; this.tiltTo = 0; this.tiltSince = at; this.landedAt = null;
    }
    setFace(face, at) {
      if (face === this.face) return;
      this.from = this.assetAt(at); this.face = face; this.since = at;
    }
    press(at) { this.pressedAt = at; this.releasedAt = null; }
    release(at) { this.pressDepth = this.pressAmount(at); this.pressedAt = null; this.releasedAt = at; }
    drag(velocityX, at) { this.tiltFrom = this.tiltAt(at); this.tiltTo = clamp(velocityX * A.dragTiltPerSpeed, -A.dragTiltMax, A.dragTiltMax); this.tiltSince = at; }
    drop(at) { this.tiltFrom = this.tiltAt(at); this.tiltTo = 0; this.tiltSince = at; this.landedAt = at; }

    // Picture without the transition: blinks and dozing swap to an eyes-shut twin.
    assetAt(t) {
      const base = ASSET[this.face];
      if (this.reduceMotion) return base;
      const age = t - this.since;
      if (BLINK[this.face]) {
        let b = this.since;
        for (let n = 0; ; n++) {
          b += M.blinkMin + rand(this.seed, n) * (M.blinkMax - M.blinkMin);
          if (b > t) break;
          if (t < b + M.blink) return BLINK[this.face];
        }
      }
      if (this.face === 'tired' && age % M.drowsePeriod >= M.drowsePeriod - M.drowseClosed) return 'eyes-closed';
      return base;
    }
    tiltAt(t) {
      const k = 1 - Math.exp(-(t - this.tiltSince) / 80);
      return this.tiltFrom + (this.tiltTo - this.tiltFrom) * clamp(k, 0, 1);
    }
    pressAmount(t) {
      if (this.pressedAt !== null) return standard(clamp((t - this.pressedAt) / M.press, 0, 1));
      if (this.releasedAt !== null) return this.pressDepth * (1 - emphasized(clamp((t - this.releasedAt) / (M.press * 2), 0, 1)));
      return 0;
    }

    pose(t) {
      const age = t - this.since;
      const p = { asset: this.assetAt(t), previous: null, mix: 1, dx: 0, dy: 0, scaleX: 1, scaleY: 1, rotation: 0 };
      if (this.from && age < M.transition) {
        const k = clamp(age / M.transition, 0, 1);
        p.previous = this.from; p.mix = standard(k);
        if (!this.reduceMotion) { const pop = A.transitionScale * Math.sin(Math.PI * k); p.scaleX += pop; p.scaleY += pop; }
      }
      if (this.reduceMotion) return round(p);
      const breath = (slow) => { const w = wave(age / (M.petBreath * slow)); p.dy += A.breathLift * w; p.scaleY *= 1 + A.breathScale * w; p.scaleX *= 1 - A.breathScale * 0.4 * w; };
      switch (this.face) {
        case 'idle': case 'waiting': breath(1); break;
        case 'listening': { const w = wave(age / M.listenPeriod); p.dy += A.listenLift * w; p.rotation += A.listenTilt * Math.sin(Math.PI * age / M.listenPeriod); break; }
        case 'thinking': p.rotation += A.thinkTilt * Math.sin(2 * Math.PI * age / M.thinkPeriod); p.dy += A.thinkLift * wave(age / M.thinkPeriod); break;
        case 'speaking': { const w = wave(age / M.speakPeriod); p.dy += A.speakLift * w; p.scaleY *= 1 + A.speakScale * w; p.scaleX *= 1 - A.speakScale * 0.5 * w; break; }
        case 'happy': {
          if (age < M.happyHop) { const k = age / M.happyHop; p.dy += A.happyHopHeight * 4 * k * (1 - k); }
          else if (age < M.happyHop + M.land) { const d = 1 - standard((age - M.happyHop) / M.land); p.scaleY *= 1 - A.landSquash * d; p.scaleX *= 1 + A.landSquash * d; }
          else breath(1);
          break;
        }
        case 'tired': {
          breath(A.tiredBreathSlow);
          const c = age % M.drowsePeriod, start = M.drowsePeriod - M.drowseClosed;
          if (c >= start) { const k = (c - start) / M.drowseClosed; const nod = Math.sin(Math.PI * k); p.dy -= 1.5 * nod; p.rotation += 2 * nod; }
          break;
        }
        case 'sleeping': breath(A.sleepBreathSlow); break;
      }
      const press = this.pressAmount(t);
      if (press) { const s = 1 - (1 - A.pressScale) * press; p.scaleX *= s; p.scaleY *= s; }
      p.rotation += this.tiltAt(t);
      if (this.landedAt !== null && t - this.landedAt < M.land) {
        const d = 1 - standard((t - this.landedAt) / M.land); p.scaleY *= 1 - A.landSquash * d; p.scaleX *= 1 + A.landSquash * d;
      }
      return round(p);
    }
    // Frames are needed while anything moves. With reduced motion only during a crossfade.
    isAnimating(t) { return !this.reduceMotion || (this.from !== null && t - this.since < M.transition); }
  }
  const round = (p) => { for (const k of ['mix', 'dx', 'dy', 'scaleX', 'scaleY', 'rotation']) p[k] = Math.round(p[k] * 1e4) / 1e4 + 0; return p; };
  // The 16-second preview (web motion scene, docs video) and the first timeline of scripts/motion-vectors.mjs.
  const preview = { seed: 5, length: 16000, events: [
    [0, 'face', 'idle', '대기 · 숨쉬기 · 눈 깜빡임'], [1200, 'press', null, '클릭: 눌림'], [1320, 'release'],
    [2800, 'face', 'listening', '듣기'], [5200, 'face', 'thinking', '생각'], [7200, 'face', 'speaking', '답변'],
    [8800, 'face', 'happy', '완료: 짧게 튐'], [9700, 'press', null, '끌기: 기울기'], [9760, 'drag', 700], [9960, 'drag', -500],
    [10160, 'drop', null, '놓기: 착지'], [10200, 'release'],
    [10700, 'face', 'tired', '장기 대기 (실제는 10분 뒤): 졸음'], [14600, 'face', 'sleeping', '조는 중 (실제는 30분 뒤)']] };
  global.PetMotion = PetMotion;
  global.PetMotionPreview = preview;
  global.PetMotionCurves = { standard, emphasized, rand };
})(globalThis);
