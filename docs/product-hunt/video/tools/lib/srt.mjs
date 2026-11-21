// Minimal SRT parser shared by the renderer and the caption checker.
export function parseTime(s) {
  const m = /^(\d{2}):(\d{2}):(\d{2})[,.](\d{3})$/.exec(s.trim());
  if (!m) throw new Error(`bad SRT time "${s}"`);
  return Number(m[1]) * 3600 + Number(m[2]) * 60 + Number(m[3]) + Number(m[4]) / 1000;
}

export function parseSrt(text) {
  const cues = [];
  for (const block of text.replace(/\r\n/g, '\n').trim().split(/\n{2,}/)) {
    const lines = block.split('\n');
    const index = Number(lines[0]);
    const m = /^(\S+)\s+-->\s+(\S+)$/.exec(lines[1] || '');
    if (!Number.isInteger(index) || !m) throw new Error(`bad SRT block: ${JSON.stringify(block.slice(0, 60))}`);
    cues.push({ index, start: parseTime(m[1]), end: parseTime(m[2]), lines: lines.slice(2) });
  }
  return cues;
}
