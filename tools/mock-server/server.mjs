#!/usr/bin/env node
// Mock nacho-server + stand-in Keycloak for Nacho Pet (dev/test only, zero dependencies, loopback only).
// Ported from nacho-gadget-app (PR #1 @1d685fa) tools/mock-server and extended for Nacho Combo:
//   - OIDC: /realms/nachotown/protocol/openid-connect/{auth,token,logout} with PKCE S256 checks for the public client
//     `nacho-gadget-app` and redirect `nachogadget://auth/callback` (the login page auto-approves: no password).
//   - REST: /api/v1/me, /api/v1/connections, /api/v1/tools, POST /api/v1/media/uploads (JSON),
//     POST /api/v1/agents/{id}/connector-binding, GET /client/config, GET /api/v1/me/usage,
//     GET /api/v1/rooms/{id}/history|delta (view=app, X-Has-More), POST /api/v1/dictation (multipart),
//     POST /api/v1/memory/feedback, DELETE /api/v1/memory/facts/{id}, POST /api/v1/memory/{id}/restore (10 s),
//     GET|POST /api/v1/chat/requests/{id}[/answer] (expected_version, 409s).
//   - WS: /ws/chat (ready, turn_started, activity, text_delta, message, usage, turn_meta, done, error, pong, stop,
//     client_msg_id idempotency, attachments) and /ws/connector (hello → ready, request/response, replaced).
// Contract source (read only): nacho-server docs/ws-protocol.md, spec/media.tsp, docs/keycloak-nacho-gadget-app.md.
// The model is NOT real: replies are canned. Tool use is simulated with keyword rules (see `planTool`) so the
// connector round trip runs end to end; pictures are "seen" by reading the PNG header (width × height).
//
// usage: node tools/mock-server/server.mjs [--port 8787] [--log path.jsonl] [--delay-ms 60] [--access-ttl 300]
// magic texts: "/error" -> error frame, "/drop" -> server closes socket mid-stream but finishes and stores the answer,
// "/long" -> long answer (for stop), "/task …" -> handed to a task (task_update, interim, choice card, task_result),
// "/remember …" -> memory_update + an answer that used a memory, "/search …" -> tool call with an interim line.
// The room keeps every message (seq) so history/delta answer like nacho-server; 3 earlier messages are seeded.
import http from 'node:http';
import crypto from 'node:crypto';
import fs from 'node:fs';

const args = process.argv.slice(2);
const opt = (name, dflt) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && args[i + 1] !== undefined ? args[i + 1] : dflt;
};
const PORT = Number(opt('port', '8787'));
const HOST = '127.0.0.1';
const LOG = opt('log', '');
const DELAY = Number(opt('delay-ms', '60'));
const ACCESS_TTL = Number(opt('access-ttl', '300'));
if (!Number.isInteger(PORT) || PORT < 1 || PORT > 65535) throw new Error('--port must be 1..65535');

const CLIENT_ID = 'nacho-gadget-app';
const REDIRECT = 'nachogadget://auth/callback';
const REALM = '/realms/nachotown/protocol/openid-connect';
const ROOM = '0193aaaa-0000-7000-8000-000000000003';
const AGENT = '0193aaaa-0000-7000-8000-000000000002';
const USER = '0193aaaa-0000-7000-8000-000000000001';
const uuid = () => crypto.randomUUID();
const now = () => new Date().toISOString();
const b64url = (buf) => buf.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const rand = (n = 24) => b64url(crypto.randomBytes(n));

// Never log secrets: tokens, codes, verifiers and file bytes are replaced by their length.
const SECRET_KEYS = new Set(['access_token', 'refresh_token', 'id_token', 'code', 'code_verifier', 'token', 'bytes_base64', 'authorization']);
const scrub = (v) => {
  if (Array.isArray(v)) return v.map(scrub);
  if (v && typeof v === 'object') {
    const o = {};
    for (const [k, x] of Object.entries(v)) o[k] = SECRET_KEYS.has(k) && typeof x === 'string' ? `<${x.length} chars>` : scrub(x);
    return o;
  }
  return v;
};
function log(dir, obj) {
  const line = JSON.stringify({ t: now(), dir, ...scrub(obj) });
  if (LOG) fs.appendFileSync(LOG, line + '\n');
  else console.log(line);
}

// ---- stand-in Keycloak ----
const codes = new Map();     // code -> { challenge, expires }
const access = new Map();    // access token -> expires (ms)
const refreshes = new Map(); // refresh token -> true
const issue = () => {
  const at = 'mock-at-' + rand(), rt = 'mock-rt-' + rand();
  access.set(at, Date.now() + ACCESS_TTL * 1000);
  refreshes.set(rt, true);
  return { access_token: at, token_type: 'Bearer', expires_in: ACCESS_TTL, refresh_token: rt, refresh_expires_in: 1800, id_token: 'mock-id-' + rand(8), scope: 'openid' };
};
const bearerOf = (req) => {
  const m = /^Bearer ([A-Za-z0-9._~+/=-]{1,4096})$/.exec(req.headers['authorization'] || '');
  return m ? m[1] : null;
};
const bearerOk = (req) => {
  const t = bearerOf(req);
  const exp = t && access.get(t);
  return !!exp && exp > Date.now();
};

const readBody = (req, limit = 30_000_000) => new Promise((resolve, reject) => {
  const chunks = []; let n = 0;
  req.on('data', (c) => { n += c.length; if (n > limit) { reject(new Error('too large')); req.destroy(); } else chunks.push(c); });
  req.on('end', () => resolve(Buffer.concat(chunks)));
  req.on('error', reject);
});

// ---- data ----
const CONNECTIONS = [
  { id: uuid(), user_id: USER, source: 'google_calendar', connect_kind: 'oauth', status: 'connected', enabled: true,
    label: 'Google 캘린더', account_label: 'm***@example.com', scope_summary: '읽기만 · 모든 캘린더',
    link: `http://${HOST}:${PORT}/mock/manage/google_calendar` },
  { id: uuid(), user_id: USER, source: 'naver_mail', connect_kind: 'app_password', status: 'needs_reauth', enabled: true,
    label: '네이버 메일', account_label: 'n***@naver.com', scope_summary: '읽기만', needs_attention: 'needs_reauth' },
  { id: uuid(), user_id: USER, source: 'notion', connect_kind: 'oauth', status: 'connected', enabled: true,
    label: 'Notion', scope_summary: '읽기/쓰기 · 고른 페이지 2개', needs_attention: 'expiring' },
];
const TOOLS = {
  tools: [
    { id: uuid(), name: 'get_current_time', search_description: '현재 시각을 알려준다', config: { kind: 'builtin' }, enabled: true },
    { id: uuid(), name: 'search_web', search_description: '웹을 검색한다', config: { kind: 'builtin' }, enabled: true },
    { id: uuid(), name: 'calendar_list_events', search_description: '캘린더 일정을 읽는다', config: { kind: 'connection', source: 'google_calendar' }, source: 'google_calendar', enabled: true },
    { id: uuid(), name: 'mail_search', search_description: '메일을 검색한다', config: { kind: 'connection', source: 'naver_mail' }, source: 'naver_mail', enabled: false },
  ],
};
const media = new Map();      // attachment_id -> { kind, name, mime, bytes, png?, text? }
// ---- the 1:1 room (shared by every /ws/chat socket = "devices") ----
let roomSeq = 0;
const roomMsgs = [];
const chatSockets = new Set(); // out functions
const storeMsg = (m) => { const full = { id: uuid(), room_id: ROOM, seq: ++roomSeq, sender_kind: m.role === 'user' ? 'user' : 'agent', client_msg_id: `srv-${uuid()}`, content: { type: 'text', text: m.text || '' }, used_memory_ids: [], redactions: [], attachments: [], created_at: now(), ...m }; roomMsgs.push(full); return full; };
const hub = (obj) => { for (const o of chatSockets) o(obj); };
storeMsg({ role: 'user', text: '어제 파스타집 알아봐 줬지?', client_msg_id: 'seed-1' });
storeMsg({ role: 'assistant', text: '네, 강남역 근처 세 곳을 찾아 드렸어요.' });
storeMsg({ role: 'system', sender_kind: 'system', text: '나초가 문서를 만들었어요', content: { type: 'system_note', kind: 'page_created', text: '나초가 문서를 만들었어요' } });
const facts = new Map();       // memory id -> { text, forgottenAt? }
const cards = new Map();       // card id -> CardRequest
const taskWaiters = new Map(); // card id -> (answer) => void
const appView = (m) => ['text', 'card', 'system_note'].includes(m.content.type);
const bindings = new Map();   // nct token -> agent id
let connector = null;         // { socket, out, capabilities, pending: Map(id -> resolve) }

const USAGE = () => ({ plan_id: 'free', plan_rank: 0, allowance: 200, period: 'day', remaining: 180, available_to_start: 170, reset_at: now(),
  exhausted: false, low_balance: false, limits: [{ kind: 'light_chat', used: 3, cap: 50, reset_at: now() }], pools: [], billing_enabled: false, credit_packs_enabled: false });
const pngSize = (buf) => (buf.length > 24 && buf.readUInt32BE(0) === 0x89504e47 && buf.toString('ascii', 12, 16) === 'IHDR')
  ? { width: buf.readUInt32BE(16), height: buf.readUInt32BE(20) } : null;

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${HOST}`);
  const send = (code, body, headers = {}) => {
    res.writeHead(code, { 'content-type': 'application/json; charset=utf-8', ...headers });
    res.end(typeof body === 'string' ? body : JSON.stringify(body));
  };
  log('http', { method: req.method, path: url.pathname });
  try {
    if (url.pathname === '/health') return send(200, { status: 'ok', mock: true });
    if (url.pathname.startsWith('/mock/manage/')) {
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
      return res.end('<h1>모의 연결 관리 페이지</h1>');
    }
    // OIDC authorize: validate like Keycloak would for this client, then "log in" without a form.
    if (req.method === 'GET' && url.pathname === `${REALM}/auth`) {
      const q = Object.fromEntries(url.searchParams);
      const bad = (why) => { log('oidc', { event: 'authorize_rejected', why }); res.writeHead(400, { 'content-type': 'text/plain' }); res.end(why); };
      if (q.client_id !== CLIENT_ID) return bad('Client not found');
      if (q.redirect_uri !== REDIRECT) return bad('Invalid parameter: redirect_uri');
      if (q.response_type !== 'code') return bad('Unsupported response_type');
      if (q.code_challenge_method !== 'S256' || !/^[A-Za-z0-9_-]{43}$/.test(q.code_challenge || '')) return bad('Missing parameter: code_challenge_method');
      if (!q.state) return bad('missing state');
      const code = 'mock-code-' + rand();
      codes.set(code, { challenge: q.code_challenge, expires: Date.now() + 60_000 });
      log('oidc', { event: 'authorized', client_id: q.client_id, redirect_uri: q.redirect_uri, code_challenge_method: q.code_challenge_method });
      const loc = `${REDIRECT}?state=${encodeURIComponent(q.state)}&session_state=${uuid()}&code=${encodeURIComponent(code)}`;
      res.writeHead(302, { location: loc });
      return res.end();
    }
    if (req.method === 'POST' && url.pathname === `${REALM}/token`) {
      const f = Object.fromEntries(new URLSearchParams((await readBody(req, 100_000)).toString('utf8')));
      if (f.client_id !== CLIENT_ID) return send(401, { error: 'invalid_client' });
      if (f.grant_type === 'authorization_code') {
        const c = codes.get(f.code); codes.delete(f.code);
        if (!c || c.expires < Date.now()) return send(400, { error: 'invalid_grant', error_description: 'Code not valid' });
        if (f.redirect_uri !== REDIRECT) return send(400, { error: 'invalid_grant', error_description: 'Incorrect redirect_uri' });
        const expect = b64url(crypto.createHash('sha256').update(f.code_verifier || '').digest());
        if (expect !== c.challenge) { log('oidc', { event: 'pkce_mismatch' }); return send(400, { error: 'invalid_grant', error_description: 'PKCE verification failed' }); }
        log('oidc', { event: 'token_issued', grant: 'authorization_code', pkce: 'S256 verified' });
        return send(200, issue());
      }
      if (f.grant_type === 'refresh_token') {
        if (!refreshes.has(f.refresh_token)) return send(400, { error: 'invalid_grant', error_description: 'Token is not active' });
        refreshes.delete(f.refresh_token);
        log('oidc', { event: 'token_issued', grant: 'refresh_token' });
        return send(200, issue());
      }
      return send(400, { error: 'unsupported_grant_type' });
    }
    if (req.method === 'POST' && url.pathname === `${REALM}/logout`) {
      const f = Object.fromEntries(new URLSearchParams((await readBody(req, 100_000)).toString('utf8')));
      const known = refreshes.delete(f.refresh_token);
      log('oidc', { event: 'logout', known_session: known });
      res.writeHead(204); return res.end();
    }
    if (req.method === 'GET' && url.pathname === '/client/config') {
      return send(200, { min_version: '0.0.0', update_notes: [], service_status: { state: 'ok' }, invite_only: false, billing_enabled: false,
        credit_packs_enabled: false, features: {}, dictation: { enabled: true, max_sec: 60, max_bytes: 2_000_000 }, voice: { enabled: false },
        media_max_bytes: 20_971_520, message_requests_enabled: false });
    }
    if (!bearerOk(req)) return send(401, { error: { code: 'unauthorized', message: 'invalid token' } });
    if (req.method === 'GET' && url.pathname === '/api/v1/me/usage') return send(200, USAGE());
    const hist = /^\/api\/v1\/rooms\/([0-9a-f-]{36})\/(history|delta)$/.exec(url.pathname);
    if (req.method === 'GET' && hist) {
      if (hist[1] !== ROOM) return send(404, { error: { code: 'not_member', message: 'not your room' } });
      const view = url.searchParams.get('view');
      if (view !== null && view !== 'app' && view !== 'full') return send(400, { error: { code: 'validation_error', message: 'view' } });
      const visible = roomMsgs.filter((m) => view !== 'app' || appView(m));
      if (hist[2] === 'delta') {
        const since = Number(url.searchParams.get('since_seq') || 0);
        const msgs = visible.filter((m) => m.seq > since).slice(0, 500);
        log('room', { event: 'delta', since, count: msgs.length });
        return send(200, { room_id: ROOM, messages: msgs, last_seq: roomSeq, read_seq: 0, has_more: false });
      }
      const limit = Math.min(Number(url.searchParams.get('limit') || 100), view === 'app' ? 1000 : 500);
      const before = url.searchParams.get('before_seq');
      if (before !== null && Number(before) < 1) return send(400, { error: { code: 'validation_error', message: 'before_seq' } });
      const pool = before !== null ? visible.filter((m) => m.seq < Number(before)) : visible;
      const page = pool.slice(Math.max(0, pool.length - limit));
      log('room', { event: 'history', before: before === null ? null : Number(before), limit, count: page.length });
      return send(200, JSON.stringify(page), { 'x-has-more': String(pool.length > page.length) });
    }
    if (req.method === 'POST' && url.pathname === '/api/v1/dictation') {
      const ct = String(req.headers['content-type'] || '');
      const bm = /^multipart\/form-data;\s*boundary=(.+)$/.exec(ct);
      if (!bm) return send(400, { error: { code: 'invalid_input', message: 'multipart required' } });
      const raw = await readBody(req, 3_000_000);
      const parts = {};
      for (const chunk of raw.toString('latin1').split('--' + bm[1])) {
        const head = /^\r\nContent-Disposition: form-data; name="([^"]+)"(?:; filename="[^"]*")?\r\n(?:Content-Type: ([^\r]+)\r\n)?\r\n/.exec(chunk);
        if (head) parts[head[1]] = { type: head[2] || null, body: Buffer.from(chunk.slice(head[0].length, chunk.length - 2), 'latin1') };
      }
      const f = parts.file;
      if (!f || f.body.length === 0) return send(400, { error: { code: 'invalid_input', message: 'file missing' } });
      if (f.body.length > 2_000_000) return send(413, { error: { code: 'payload_too_large', message: 'too large' } });
      const base = String(f.type || '').split(';')[0].trim();
      if (!['audio/mp4', 'audio/m4a', 'audio/x-m4a', 'audio/aac', 'audio/wav', 'audio/webm', 'audio/mpeg'].includes(base)) {
        return send(415, { error: { code: 'unsupported_media_type', message: 'audio type' } });
      }
      const dur = parts.duration_sec ? Number(parts.duration_sec.body.toString()) : null;
      if (dur !== null && !(dur > 0 && dur <= 61)) return send(400, { error: { code: 'invalid_input', message: 'duration' } });
      const language = parts.language ? parts.language.body.toString().toLowerCase() : 'ko';
      // Same rule as nacho-server's mock provider: "NACHO-STT:<text>" -> that text.
      const s = f.body.toString('utf8');
      const text = s.startsWith('NACHO-STT:') ? s.slice(10) : '모의 받아쓰기 문장이에요';
      log('dictation', { event: 'transcribed', type: base, bytes: f.body.length, language, duration_sec: dur });
      return send(200, { text, language, ...(dur !== null ? { duration_sec: dur } : {}) });
    }
    if (req.method === 'POST' && url.pathname === '/api/v1/memory/feedback') {
      let body; try { body = JSON.parse((await readBody(req, 100_000)).toString('utf8')); } catch { return send(400, { error: { code: 'validation_error', message: 'json' } }); }
      if (typeof body.text !== 'string' || !body.text.trim()) return send(400, { error: { code: 'validation_error', message: 'text' } });
      const ids = Array.isArray(body.memory_ids) ? body.memory_ids : [];
      for (const id of ids) if (!facts.has(id)) return send(404, { error: { code: 'not_found', message: 'memory' } });
      if (ids.length === 1 && body.kind === 'correction') facts.get(ids[0]).text = body.text;
      log('memory', { event: 'feedback', kind: body.kind || 'unclassified', memory_ids: ids, room_id: body.room_id || null, idempotency_key: req.headers['idempotency-key'] ? 'present' : 'missing', text_chars: body.text.length });
      return send(201, { id: uuid(), kind: body.kind || 'unclassified', classified_by: body.kind ? 'client' : 'rule', actions: ids.length ? ids.map((id) => ({ action: 'updated', memory_id: id })) : [{ action: 'created', memory_id: uuid() }], created_at: now() });
    }
    const forget = /^\/api\/v1\/memory\/(facts|episodes)\/([0-9a-f-]{36})$/.exec(url.pathname);
    if (req.method === 'DELETE' && forget) {
      const f = facts.get(forget[2]);
      if (!f || f.forgottenAt) return send(404, { error: { code: 'not_found', message: 'memory' } });
      f.forgottenAt = Date.now();
      log('memory', { event: 'forgotten', id: forget[2] });
      hub({ type: 'memory_update', room_id: ROOM, update: { update_id: uuid(), action: 'forgotten', memory_ids: [forget[2]], kind: 'fact', preview: '', source: 'user', always_show: true, items: [{ memory_id: forget[2], kind: 'fact', preview: '' }] } });
      res.writeHead(204); return res.end();
    }
    const restore = /^\/api\/v1\/memory\/([0-9a-f-]{36})\/restore$/.exec(url.pathname);
    if (req.method === 'POST' && restore) {
      const f = facts.get(restore[1]);
      if (!f || !f.forgottenAt) return send(404, { error: { code: 'not_found', message: 'memory' } });
      if (Date.now() - f.forgottenAt > 10_000) return send(410, { error: { code: 'restore_expired', message: 'too late' } });
      delete f.forgottenAt;
      log('memory', { event: 'restored', id: restore[1] });
      hub({ type: 'memory_update', room_id: ROOM, update: { update_id: uuid(), action: 'restored', memory_ids: [restore[1]], kind: 'fact', preview: f.text, source: 'user', always_show: true, items: [{ memory_id: restore[1], kind: 'fact', preview: f.text }] } });
      return send(200, { kind: 'fact', item: { id: restore[1], text: f.text } });
    }
    const card = /^\/api\/v1\/chat\/requests\/([0-9a-f-]{36})(\/answer)?$/.exec(url.pathname);
    if (card && (req.method === 'GET' || (req.method === 'POST' && card[2]))) {
      const c = cards.get(card[1]);
      if (!c) return send(404, { error: { code: 'not_found', message: 'card' } });
      if (req.method === 'GET') return send(200, c);
      let body; try { body = JSON.parse((await readBody(req, 100_000)).toString('utf8')); } catch { return send(400, { error: { code: 'validation_error', message: 'json' } }); }
      if (c.status !== 'pending') return send(409, { error: { code: c.status === 'answered' ? 'already_answered' : c.status, message: 'closed' } });
      if (body.expected_version !== c.version) return send(409, { error: { code: 'version_conflict', message: 'version' } });
      const okAction = c.kind === 'choice' ? ['choose', 'dismiss'] : ['approve', 'deny', 'dismiss'];
      if (!okAction.includes(body.action)) return send(400, { error: { code: 'validation_error', message: 'action' } });
      if (body.action === 'choose' && !c.payload.options.some((o) => o.id === body.option_id)) return send(400, { error: { code: 'validation_error', message: 'option' } });
      Object.assign(c, { status: body.action === 'dismiss' ? 'dismissed' : 'answered', answered_action: body.action, version: c.version + 1, answer: { action: body.action, option_id: body.option_id, answered_at: now() }, answered_at: now() });
      log('card', { event: 'answered', id: c.id, action: body.action, option_id: body.option_id || null });
      hub({ type: 'card_update', room_id: ROOM, request: c });
      const w = taskWaiters.get(c.id); if (w) { taskWaiters.delete(c.id); w(c); }
      return send(200, c);
    }
    if (req.method === 'GET' && url.pathname === '/api/v1/me') return send(200, { id: USER, display_name: '모의 사용자' });
    if (req.method === 'GET' && url.pathname === '/api/v1/connections') return send(200, CONNECTIONS);
    if (req.method === 'GET' && url.pathname === '/api/v1/tools') {
      return send(200, { ...TOOLS, connector_capabilities: connector ? connector.capabilities : [] });
    }
    if (req.method === 'POST' && url.pathname === '/api/v1/media/uploads') {
      let body;
      try { body = JSON.parse((await readBody(req)).toString('utf8')); } catch { return send(400, { error: { code: 'validation_error', message: 'json' } }); }
      const mime = String(body.mime || '').toLowerCase();
      const allowed = mime.startsWith('image/') || mime === 'video/mp4' || mime === 'application/pdf' || mime.startsWith('text/');
      if (!allowed) return send(400, { error: { code: 'validation_error', message: 'mime not allowed' } });
      const bytes = Buffer.from(String(body.bytes_base64 || '').replace(/^data:[^,]*,/, ''), 'base64');
      if (bytes.length === 0) return send(400, { error: { code: 'validation_error', message: 'empty' } });
      if (bytes.length > 20_000_000) return send(413, { error: { code: 'payload_too_large', message: 'too large' } });
      const kind = mime.startsWith('image/') ? 'image' : mime === 'video/mp4' ? 'video' : 'file';
      if (body.kind && body.kind !== kind) return send(400, { error: { code: 'validation_error', message: 'kind/mime mismatch' } });
      const id = uuid();
      const item = { kind, name: String(body.name || 'file').slice(0, 200), mime, bytes: bytes.length, png: pngSize(bytes),
                     text: mime.startsWith('text/') ? bytes.toString('utf8').slice(0, 200) : null };
      media.set(id, item);
      log('media', { event: 'stored', id, kind, mime, bytes: bytes.length, png: item.png });
      return send(201, { attachment_id: id, kind, path: `/api/v1/media/${id}`, url: `http://${HOST}:${PORT}/api/v1/media/${id}?sig=mock`, name: item.name, mime, bytes: bytes.length });
    }
    const bind = /^\/api\/v1\/agents\/([0-9a-f-]{36})\/connector-binding$/.exec(url.pathname);
    if (req.method === 'POST' && bind) {
      if (bind[1] !== AGENT) return send(404, { error: { code: 'not_found', message: 'agent' } });
      const b = JSON.parse((await readBody(req, 10_000)).toString('utf8') || '{}');
      const token = 'nct_' + crypto.randomBytes(32).toString('hex');
      bindings.set(token, AGENT);
      log('connector', { event: 'binding_issued', kind: b.kind, label: b.label });
      return send(200, { binding: { id: uuid(), agent_id: AGENT, kind: String(b.kind || 'chrome'), label: b.label || null }, token, endpoint: '/ws/connector' });
    }
    send(404, { error: { code: 'not_found', message: 'no such route' } });
  } catch (e) {
    send(500, { error: { code: 'internal', message: String(e.message) } });
  }
});

// ---- WebSocket (RFC 6455, text frames only) ----
const GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

function encodeFrame(opcode, payload) {
  const body = Buffer.from(payload);
  let head;
  if (body.length < 126) head = Buffer.from([0x80 | opcode, body.length]);
  else if (body.length < 65536) { head = Buffer.alloc(4); head[0] = 0x80 | opcode; head[1] = 126; head.writeUInt16BE(body.length, 2); }
  else { head = Buffer.alloc(10); head[0] = 0x80 | opcode; head[1] = 127; head.writeBigUInt64BE(BigInt(body.length), 2); }
  return Buffer.concat([head, body]);
}

function* parseFrames(state) {
  for (;;) {
    const b = state.buf;
    if (b.length < 2) return;
    const fin = (b[0] & 0x80) !== 0, opcode = b[0] & 0x0f, masked = (b[1] & 0x80) !== 0;
    let len = b[1] & 0x7f, off = 2;
    if (len === 126) { if (b.length < 4) return; len = b.readUInt16BE(2); off = 4; }
    else if (len === 127) { if (b.length < 10) return; len = Number(b.readBigUInt64BE(2)); off = 10; }
    if (len > 1_000_000) throw new Error('frame too large');
    if (!masked) throw new Error('client frames must be masked');
    if (b.length < off + 4 + len) return;
    const mask = b.subarray(off, off + 4);
    const data = Buffer.from(b.subarray(off + 4, off + 4 + len));
    for (let i = 0; i < data.length; i++) data[i] ^= mask[i % 4];
    state.buf = b.subarray(off + 4 + len);
    yield { fin, opcode, data };
  }
}

function wsAccept(req, socket) {
  const key = req.headers['sec-websocket-key'];
  if (!key) { socket.end('HTTP/1.1 400 Bad Request\r\n\r\n'); return false; }
  const accept = crypto.createHash('sha1').update(key + GUID).digest('base64');
  socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
  return true;
}

function frameLoop(socket, onText) {
  const state = { buf: Buffer.alloc(0) };
  let fragments = [];
  socket.on('data', (chunk) => {
    state.buf = Buffer.concat([state.buf, chunk]);
    try {
      for (const f of parseFrames(state)) {
        if (f.opcode === 8) { socket.end(encodeFrame(8, Buffer.alloc(0))); return; }
        if (f.opcode === 9) { socket.write(encodeFrame(10, f.data)); continue; }
        if (f.opcode === 10) continue;
        fragments.push(f.data);
        if (f.fin) { onText(Buffer.concat(fragments).toString('utf8')); fragments = []; }
      }
    } catch (e) { log('ws', { event: 'protocol_error', message: String(e.message) }); socket.destroy(); }
  });
  socket.on('error', () => {});
}

server.on('upgrade', (req, socket) => {
  const url = new URL(req.url, `http://${HOST}`);
  if (url.pathname === '/ws/connector') {
    if (!wsAccept(req, socket)) return;
    return handleConnector(socket);
  }
  if (url.pathname !== '/ws/chat') { socket.end('HTTP/1.1 404 Not Found\r\n\r\n'); return; }
  if (!bearerOk(req)) {
    log('ws', { event: 'rejected', status: 401 });
    socket.end('HTTP/1.1 401 Unauthorized\r\ncontent-type: application/json\r\n\r\n{"error":{"code":"unauthorized"}}');
    return;
  }
  if (!wsAccept(req, socket)) return;
  handleChat(socket);
});

function handleConnector(socket) {
  const out = (obj) => { log('connector-out', obj); if (!socket.destroyed) socket.write(encodeFrame(1, JSON.stringify(obj))); };
  let session = null;
  const timer = setTimeout(() => { if (!session) { out({ type: 'error', code: 'unauthorized', message: 'hello timeout' }); socket.end(); } }, 10_000);
  log('ws', { event: 'connector_open' });
  frameLoop(socket, (txt) => {
    let m; try { m = JSON.parse(txt); } catch { return out({ type: 'error', code: 'bad_frame', message: 'json' }); }
    log('connector-in', m.type === 'hello' ? { type: 'hello', token: m.token, capabilities: (m.capabilities || []).map((c) => c.name) } : m);
    if (!session) {
      if (m.type !== 'hello' || !bindings.has(m.token)) { out({ type: 'error', code: 'unauthorized', message: 'first frame must be {type:hello, token, capabilities}' }); return socket.end(); }
      clearTimeout(timer);
      if (connector) { connector.out({ type: 'error', code: 'replaced', message: 'another connector session took over' }); connector.socket.end(); }
      session = { socket, out, capabilities: Array.isArray(m.capabilities) ? m.capabilities : [], pending: new Map() };
      connector = session;
      return out({ type: 'ready', agent_id: AGENT, kind: 'nacho_combo' });
    }
    if (m.type === 'ping') return out({ type: 'pong' });
    if (m.type === 'capabilities') { session.capabilities = m.capabilities || []; return; }
    if (m.type === 'response') {
      const p = session.pending.get(m.id);
      if (p) { session.pending.delete(m.id); p({ result: m.result, error: m.error }); }
    }
  });
  socket.on('close', () => { clearTimeout(timer); if (connector === session) connector = null; log('ws', { event: 'connector_close' }); });
}

const callConnector = (capability, params) => new Promise((resolve) => {
  if (!connector || !connector.capabilities.some((c) => c.name === capability)) return resolve({ error: 'connector_unavailable' });
  const id = uuid();
  const c = connector;
  const t = setTimeout(() => { c.pending.delete(id); resolve({ error: 'connector did not answer within 10s' }); }, 10_000);
  c.pending.set(id, (r) => { clearTimeout(t); resolve(r); });
  c.out({ type: 'request', id, capability, params });
});

// Keyword rules standing in for the model's tool choice (Korean and English).
const GADGETS = [
  [/(창 ?스냅|윈도우 ?스냅|window ?snap)/i, 'windowSnap'], [/(킵 ?어웨이크|잠자기 ?방지|keep ?awake)/i, 'keepAwake'],
  [/(포커스 ?딤|focus ?dim)/i, 'focusDim'], [/(클립보드|clipboard)/i, 'clipboard'], [/(선반|file ?shelf)/i, 'fileShelf'],
  [/(컴퓨터 ?사용|computer ?use)/i, 'computerUse'],
];
function planTool(text) {
  if (/가젯 ?목록|list gadgets/i.test(text)) return { name: 'combo_list_gadgets', params: {} };
  if (/창|window/i.test(text) && !/스냅|snap/i.test(text)) {
    if (/왼쪽|left/i.test(text)) return { name: 'combo_arrange_window', params: { position: 'left' } };
    if (/오른쪽|right/i.test(text)) return { name: 'combo_arrange_window', params: { position: 'right' } };
    if (/최대|크게|maximi/i.test(text)) return { name: 'combo_arrange_window', params: { position: 'maximize' } };
  }
  for (const [re, gadget] of GADGETS) {
    if (re.test(text) && /(켜|꺼|\bon\b|\boff\b)/i.test(text)) return { name: 'combo_set_gadget', params: { gadget, on: /켜|\bon\b/i.test(text) } };
  }
  return null;
}

function handleChat(socket) {
  let active = null;               // { clientId, timer, partial }
  const seen = new Map();          // client_msg_id -> true (idempotency)
  const out = (obj) => {
    log('out', obj);
    if (!socket.destroyed) socket.write(encodeFrame(1, JSON.stringify(obj)));
  };
  log('ws', { event: 'open' });
  chatSockets.add(out);
  out({ type: 'ready', user_id: USER, agent_id: AGENT, agent_name: '나초', room_id: ROOM });
  const activity = (kind, clientId, tool = null) => out({ type: 'activity', room_id: ROOM, activity: { room_id: ROOM, agent_id: AGENT, kind, tool, tool_used: !!tool, updated_at: now() }, client_id: clientId });

  const finish = (stopped) => {
    if (!active) return;
    const active0 = active;
    const { clientId, timer, partial, turnId } = active;
    clearInterval(timer);
    active = null;
    activity('idle', clientId);
    const stored = storeMsg({ role: 'assistant', text: partial, used_memory_ids: active0.used || [] });
    const mid = stored.id;
    out({ type: 'message', room_id: ROOM, message: stored, client_id: clientId });
    for (const u of active0.memory || []) out({ type: 'memory_update', room_id: ROOM, update: u, client_id: clientId });
    out({ type: 'usage', room_id: ROOM, remaining: 180, available_to_start: 170, light_chat_used: 4, light_chat_cap: 50, state: USAGE(), client_id: clientId });
    out({ type: 'turn_meta', room_id: ROOM, turn_id: turnId, message_id: mid, model: 'mock', stopped, client_id: clientId });
    out({ type: 'done', room_id: ROOM, message_id: mid, task_id: null, stopped, client_id: clientId });
  };

  const stream = (reply, clientId, turnId, text, extra = {}) => {
    const chunks = reply.match(/.{1,8}/gsu) || [reply];
    active = { clientId, turnId, partial: '', timer: null, ...extra };
    let i = 0, typing = false;
    active.timer = setInterval(() => {
      if (!active) return;
      if (text === '/drop' && i === 3) {
        // The socket goes away; like nacho-server, the turn still runs to the end and is stored.
        clearInterval(active.timer); active = null;
        storeMsg({ role: 'assistant', text: reply });
        log('ws', { event: 'drop', stored_seq: roomSeq });
        socket.destroy(); return;
      }
      if (i >= chunks.length) { finish(false); return; }
      if (!typing) { typing = true; activity('typing', clientId); }
      active.partial += chunks[i];
      out({ type: 'text_delta', room_id: ROOM, agent_id: AGENT, text: chunks[i], client_id: clientId });
      i++;
    }, DELAY);
  };

  const startTurn = async (text, clientId, items) => {
    const turnId = uuid();
    const isTask = text.startsWith('/task');
    const taskId = isTask ? uuid() : null;
    out({ type: 'turn_started', room_id: ROOM, turn_id: turnId, user_message_id: uuid(), agent_id: AGENT, task_id: taskId, duplicate: false, client_id: clientId });
    const userMsg = storeMsg({ role: 'user', client_msg_id: clientId, text, attachments: items.map((a) => ({ attachment_id: a.id, kind: a.kind, name: a.name, mime: a.mime, bytes: a.bytes })) });
    out({ type: 'message', room_id: ROOM, message: userMsg, client_id: clientId });
    if (isTask) return void runTask(text, clientId, taskId);
    activity('thinking', clientId);
    if (text === '/error') {
      activity('idle', clientId);
      out({ type: 'error', room_id: ROOM, code: 'upstream_error', message: 'external service mock: boom', reason: null, client_id: clientId });
      return;
    }
    let reply;
    const tool = planTool(text);
    if (tool) {
      active = { clientId, turnId, partial: '', timer: null }; // busy while the tool runs
      activity('tool', clientId, tool.name);
      const callId = 'call_' + rand(6);
      out({ type: 'tool_call_started', room_id: ROOM, call_id: callId, name: tool.name, arguments: tool.params, client_id: clientId });
      const r = await callConnector(tool.name, tool.params);
      out({ type: 'tool_call_finished', room_id: ROOM, call_id: callId, name: tool.name, preview: JSON.stringify(r).slice(0, 200), meta: { source: 'connector', is_error: !!r.error }, client_id: clientId });
      log('tool', { name: tool.name, params: tool.params, result: r });
      active = null;
      reply = r.error ? `(모의) ${tool.name} 을 쓰려 했는데 안 됐어요: ${r.error}` : `(모의) ${tool.name} 결과: ${r.result && r.result.message ? r.result.message : JSON.stringify(r.result)}`;
    } else if (items.length) {
      const desc = items.map((a) => a.png ? `${a.name} (사진 ${a.png.width}×${a.png.height}, ${a.bytes}바이트)` : a.text !== null ? `${a.name} (글: "${a.text.slice(0, 20)}")` : `${a.name} (${a.mime}, 내용은 못 열어요)`).join(', ');
      reply = `(모의) 받은 첨부: ${desc}. 질문: "${text}"`;
    } else if (text.startsWith('/remember')) {
      const what = text.replace('/remember', '').trim() || '매운 음식을 좋아함';
      const id = uuid();
      facts.set(id, { text: what });
      const used = [...facts.entries()].filter(([, f]) => !f.forgottenAt).map(([k]) => k);
      reply = `알겠어요. "${what}" 기억해 둘게요.`;
      return void stream(reply, clientId, turnId, text, { used, memory: [{ update_id: uuid(), action: 'created', memory_ids: [id], kind: 'fact', preview: what, source: 'chat', always_show: false, after_seq: userMsg.seq, items: [{ memory_id: id, kind: 'fact', preview: what }] }] });
    } else if (text.startsWith('/search')) {
      activity('tool', clientId, 'search_web');
      const callId = 'call_' + rand(6);
      out({ type: 'tool_call_started', room_id: ROOM, call_id: callId, name: 'search_web', arguments: { query: '(redacted)' }, client_id: clientId });
      const interim = storeMsg({ role: 'assistant', text: '웹에서 찾아보고 있어요', interim: true });
      out({ type: 'message', room_id: ROOM, message: interim, client_id: clientId });
      await new Promise((r) => setTimeout(r, DELAY * 2));
      out({ type: 'tool_call_finished', room_id: ROOM, call_id: callId, name: 'search_web', preview: '결과 3건', meta: { source: 'builtin', is_error: false, duration_ms: DELAY * 2 }, client_id: clientId });
      reply = '(모의) 찾아봤어요. 결과는 3건이에요.';
    } else if (text === '/long') {
      reply = Array.from({ length: 200 }, (_, i) => `문장 ${i + 1}. `).join('');
    } else {
      reply = `모의 나초예요. "${text}" 라고 말씀하셨네요. 지금은 모의 서버라 실제 답은 못 드리지만, 스트리밍이 잘 보이는지 확인해 주세요.`;
    }
    stream(reply, clientId, turnId, text);
  };

  // Like nacho-server's task path: the turn ends at once (done{task_id}); the work and its answer come through the hub.
  const runTask = (text, clientId, taskId) => {
    out({ type: 'usage', room_id: ROOM, remaining: 180, available_to_start: 160, state: USAGE(), client_id: clientId });
    out({ type: 'done', room_id: ROOM, message_id: null, task_id: taskId, stopped: false, client_id: clientId });
    const task = (state, extra = {}) => hub({ type: 'task_update', room_id: ROOM, task: { id: taskId, agent_id: AGENT, room_id: ROOM, kind: 'task', state, title: '파스타집 예약', request_text: text, plan_mode: 'inline', steps: [], credit: { used: 0, refund_status: 'none' }, accessed_items: [], plan_blocks: [], result_blocks: [], version: 1, ...extra } });
    setTimeout(() => {
      task('running', { current_step: { text: '자리 찾는 중', index: 1, total: 2 } });
      const interim = storeMsg({ role: 'assistant', text: '자리를 알아보고 있어요', interim: true, task_id: taskId });
      hub({ type: 'message', room_id: ROOM, message: interim });
      const cardId = uuid();
      const c = { id: cardId, request_id: cardId, user_id: USER, room_id: ROOM, task_id: taskId, kind: 'choice', status: 'pending', version: 1,
                  payload: { question: '어느 시간이 좋아요?', options: [{ id: 'seven', label: '저녁 7시' }, { id: 'eight', label: '저녁 8시' }] }, created_at: now() };
      cards.set(cardId, c);
      storeMsg({ role: 'assistant', text: '', content: { type: 'card', request_id: cardId, kind: 'choice' }, card: c, task_id: taskId });
      task('waiting', { wait_reason: 'input', pending_request_id: cardId });
      hub({ type: 'card_update', room_id: ROOM, request: c });
      taskWaiters.set(cardId, (answered) => {
        const opt = answered.payload.options.find((o) => o.id === answered.answer.option_id);
        task('running', { current_step: { text: '예약하는 중', index: 2, total: 2 } });
        setTimeout(() => {
          const result = storeMsg({ role: 'assistant', text: `${opt ? opt.label : '고른 시간'}으로 예약했어요.`, task_id: taskId, task_result: true });
          hub({ type: 'message', room_id: ROOM, message: result });
          task('done');
        }, DELAY);
      });
    }, DELAY);
  };

  frameLoop(socket, (txt) => {
    let m;
    try { m = JSON.parse(txt); } catch { return out({ type: 'error', code: 'bad_frame', message: 'invalid json' }); }
    log('in', m);
    switch (m && m.type) {
      case 'ping': return out({ type: 'pong' });
      case 'read': log('room', { event: 'read', seq: m.seq }); return;
      case 'stop': return finish(true);
      case 'message': {
        const text = typeof m.text === 'string' ? m.text.trim() : '';
        const id = typeof m.client_msg_id === 'string' ? m.client_msg_id : '';
        const att = Array.isArray(m.attachments) ? m.attachments : [];
        if ((!text && att.length === 0) || !id) return out({ type: 'error', code: 'invalid_input', message: 'text and client_msg_id required', reason: null, client_id: id || null });
        const items = [];
        for (const a of att) {
          const item = a && media.get(a.attachment_id);
          if (!item) return out({ type: 'error', code: 'not_found', message: 'attachment not found', reason: null, client_id: id });
          items.push({ id: a.attachment_id, ...item });
        }
        if (seen.has(id)) {
          out({ type: 'turn_started', room_id: ROOM, turn_id: uuid(), user_message_id: uuid(), duplicate: true, client_id: id });
          return out({ type: 'done', room_id: ROOM, message_id: null, task_id: null, stopped: false, client_id: id });
        }
        seen.set(id, true);
        if (active) return out({ type: 'error', code: 'invalid_input', message: 'turn in progress', reason: null, client_id: id });
        return void startTurn(text, id, items);
      }
      default: return out({ type: 'error', code: 'bad_frame', message: 'unknown type' });
    }
  });
  socket.on('close', () => { chatSockets.delete(out); if (active && active.timer) clearInterval(active.timer); log('ws', { event: 'close' }); });
}

server.listen(PORT, HOST, () => log('server', { event: 'listening', url: `http://${HOST}:${PORT}` }));
