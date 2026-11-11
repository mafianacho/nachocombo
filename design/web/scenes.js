// Nacho Pet web mockup: every scene the app shows, built from small DOM helpers. Static: no network, no state.
// URL: index.html?scene=<id>&theme=light|dark   ·   &pair=1 → light and dark side by side   ·   no scene → index.
// Texts are the app's (Sources/NachoComboCore/Pet, Sources/NachoCombo/Pet). Art: Resources/Nacho (© Mafianacho).
const ART = '../../Resources/Nacho/';
const FACE = { idle: 'idle', listening: 'calling', thinking: 'thinking', speaking: 'working', happy: 'happy', waiting: 'waiting',
  tired: 'tired', sleeping: 'eyes-closed' };

// 24×24 stroke icons (stand-ins for SF Symbols in the app; see the port table in the PR).
const PATHS = {
  clip: 'M20 11.5l-7.8 7.8a5 5 0 01-7.1-7.1l8.5-8.5a3.3 3.3 0 014.7 4.7l-8.5 8.5a1.7 1.7 0 01-2.4-2.4l7.8-7.8',
  mic: 'M12 3a3 3 0 00-3 3v6a3 3 0 006 0V6a3 3 0 00-3-3zM6 11a6 6 0 0012 0M12 17v4',
  send: 'M12 19V5M6 11l6-6 6 6',
  stop: 'M7 7h10v10H7z',
  wrench: 'M14.5 6.5a4 4 0 00-5.3 5.3L4 17l3 3 5.2-5.2a4 4 0 005.3-5.3l-2.4 2.4-2.6-.5-.5-2.6z',
  check: 'M5 12.5l4.5 4.5L19 7.5',
  x: 'M6 6l12 12M18 6L6 18',
  doc: 'M7 3h7l4 4v14H7zM14 3v4h4',
  image: 'M4 5h16v14H4zM4 16l5-5 4 4 3-3 4 4M15 9.5h.01',
  task: 'M9 6h11M9 12h11M9 18h11M4 6l1 1 2-2M4 12l1 1 2-2M4 18l1 1 2-2',
  question: 'M12 21a9 9 0 100-18 9 9 0 000 18zM9.5 9a2.5 2.5 0 015 .5c0 1.5-2.5 2-2.5 3.5M12 16.5h.01',
  memory: 'M12 4a4 4 0 00-4 2.6A3.5 3.5 0 005.5 13 3.5 3.5 0 009 18.5h3V4zm0 0a4 4 0 014 2.6A3.5 3.5 0 0118.5 13 3.5 3.5 0 0115 18.5h-3',
  bell: 'M6 16V11a6 6 0 0112 0v5l2 2H4zM10 20a2 2 0 004 0',
  warn: 'M12 4l9 16H3zM12 10v4M12 17h.01',
  person: 'M12 12a4 4 0 100-8 4 4 0 000 8zM4 21a8 8 0 0116 0',
  up: 'M6 15l6-6 6 6',
  down: 'M6 9l6 6 6-6',
  phone: 'M8 3h8v18H8zM11 18h2',
  spark: 'M12 3v4M12 17v4M3 12h4M17 12h4M6 6l2.5 2.5M15.5 15.5L18 18M6 18l2.5-2.5M15.5 8.5L18 6',
  credit: 'M12 21a9 9 0 100-18 9 9 0 000 18zM12 7v10M9 9.5h4.5a1.5 1.5 0 010 3h-3a1.5 1.5 0 000 3H15',
  bubble: 'M4 5h16v11H9l-4 4v-4H4zM8 10.5h.01M12 10.5h.01M16 10.5h.01',
  link: 'M10 14a4 4 0 005.7 0l3-3a4 4 0 00-5.7-5.7l-1 1M14 10a4 4 0 00-5.7 0l-3 3a4 4 0 005.7 5.7l1-1',
};
const icon = (name) => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="${PATHS[name]}"/></svg>`;
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

// ---------- pieces ----------
const pet = (face = 'idle', extra = '') => {
  let badge = '';
  if (face === 'listening') badge = `<span class="badge rec">${icon('mic')}</span>`;
  if (face === 'thinking') badge = '<span class="badge dots"><i></i><i></i><i></i></span>';
  if (face === 'speaking') badge = `<span class="badge">${icon('bubble')}</span>`;
  if (face === 'sleeping') badge = '<span class="badge">z</span>';
  return `<div class="pet ${face} ${extra}" data-face="${face}" role="button" aria-label="나초 펫"><img src="${ART}${FACE[face]}.png" alt="">${badge}</div>`;
};
const head = ({ status = '연결됨', dot = '', credits = '크레딧 180', tab = 0 } = {}) => `
  <header class="chat-head">
    <img class="avatar" src="${ART}idle.png" alt="">
    <div class="who"><b>나초</b><span class="status"><i class="sdot ${dot}"></i>${esc(status)}${credits ? ` <span class="sep">·</span> ${credits}` : ''}</span></div>
    <div class="seg"><button aria-pressed="${tab === 0}">대화</button><button aria-pressed="${tab === 1}">연결</button></div>
  </header>`;
const mine = (text, attach = '') => `<div class="row mine"><div class="bubble">${esc(text)}${attach}</div></div>`;
const nacho = (html, past = false) => `<div class="row nacho"><div class="bubble ${past ? 'past' : ''}">${html}</div></div>`;
const line = (kind, ic, html) => `<div class="line ${kind}">${ic ? icon(ic) : ''}<span>${html}</span></div>`;
const file = (name, by = true, kind = 'doc') => `<a class="file" href="#">${icon(kind)}<span>${esc(name)}</span>${by ? '<span class="by">· 나초가 만듦</span>' : ''}</a>`;
const composer = ({ text = '', focus = true, send = 'off', mic = '', listening = false } = {}) => `
  <div class="composer">
    <button class="ibtn" title="파일 주기">${icon('clip')}</button>
    <div class="field ${focus ? 'focus' : ''}">${listening
      ? `<span class="listen">${wave()}<span class="ell">듣고 있어요</span></span>`
      : text ? esc(text) : '<span class="ph">나초에게 말하기…</span>'}</div>
    <button class="ibtn ${mic}" title="${listening ? '다 말하면 다시 누르세요' : '받아쓰기'}">${icon('mic')}</button>
    <button class="send ${send}" title="${send === 'stop' ? '멈추기' : '보내기'}">${icon(send === 'stop' ? 'stop' : 'send')}</button>
  </div>`;
const wave = () => `<span class="wave">${[6, 12, 9, 15, 7, 11].map((h) => `<i style="height:${h}px"></i>`).join('')}</span>`;
const chat = ({ headOpts, banner = '', log = '', pending = '', comp = {} } = {}) => `
  <div class="chat" role="dialog" aria-label="나초와 대화">${head(headOpts)}${banner}<div class="log">${log}</div>${pending}${composer(comp)}</div>`;
const desk = (inner, { w = 420, h = 700, window = true } = {}) =>
  `<div class="stage" style="width:${w}px;height:${h}px">${inner}</div>`;
const chatScene = (c, face = 'idle') => desk(chat(c) + pet(face));

// ---------- scenes ----------
const S = {};
const scene = (id, title, render) => { S[id] = { title, render }; };

scene('desktop', '바탕화면 오른쪽 아래 펫 (대기)', () => desk(pet('idle'), { w: 360, h: 240 }));
scene('pet-states', '펫 상태: 대기 · 듣기 · 생각 · 답변 · 완료 · 장기대기', () => {
  const tiles = [['idle', '대기', '아무것도 안 할 때'], ['listening', '듣기', '받아쓰는 중'], ['thinking', '생각', '생각·도구 쓰는 중'],
    ['speaking', '답변', '답이 나오는 중'], ['happy', '완료', '답이 끝나고 4초'], ['tired', '장기대기', '10분 넘게 조용할 때']];
  return `<div class="stage" style="width:952px;height:208px"><div class="states">${tiles.map(([f, n, d]) =>
    `<div class="state-tile">${pet(f)}<div class="cap"><b>${n}</b>${d}</div></div>`).join('')}</div></div>`;
});
scene('hover', '호버 (이름표 · 살짝 떠오름) · 파일 끌어다 놓기', () => desk(
  `<div class="nametag"><b>나초</b><span class="k">· 대기 · 클릭: 대화</span></div>${pet('idle', 'hover')}`
  + `<div style="position:absolute;left:56px;bottom:24px;width:112px;height:112px">${pet('happy').replace('class="pet happy ', 'class="pet happy " style="right:0;bottom:0"')}<div class="drop-ring"></div></div>`
  + `<div class="nametag" style="right:auto;left:112px;transform:translateX(-50%)"><b>나초에게 주기</b><span class="k">· 놓으면 첨부돼요</span></div>`,
  { w: 420, h: 260 }));
scene('chat-empty', '입력 말풍선 (처음 열었을 때)', () => chatScene({
  log: `<div class="hello"><b>무엇을 도와드릴까요?</b>
        <div class="examples"><button class="ex">창 왼쪽으로 붙여 줘</button><button class="ex">킵 어웨이크 켜 줘</button><button class="ex">이 캡처 뭐야?</button></div></div>`,
}));
scene('dictation', '받아쓰기 (듣는 중)', () => chatScene({
  log: mine('창 왼쪽으로 붙여 줘') + nacho('앞의 창을 왼쪽 절반에 붙였어요.') + line('', 'wrench', '<span title="combo_arrange_window">창 배치</span> <span class="ok">✓</span>'),
  comp: { listening: true, mic: 'rec', send: 'off' },
}, 'listening'));
scene('streaming', '스트리밍 답 (멈추기 버튼)', () => chatScene({
  headOpts: { status: '답하는 중', dot: 'busy' },
  log: mine('내일 강남역 근처 파스타집 알려줘') + nacho('강남역 11번 출구 쪽에 세 곳이 있어요. 첫째, “파스타 리코”는 생면 파스타로 유명하고<span class="caret"></span>'),
  comp: { send: 'stop', focus: false },
}, 'speaking'));
scene('tools', '도구 진행 줄 · 중간 답', () => chatScene({
  headOpts: { status: '웹에서 찾는 중', dot: 'busy' },
  log: mine('요즘 맥북 배터리 오래 쓰는 법 찾아줘')
    + line('', 'wrench', '<span title="search_web">웹 검색</span> <span class="ok">✓</span> <span class="sep">·</span> <span title="read_page">페이지 읽기</span> …')
    + line('', 'spark', '웹에서 찾아보고 있어요')
    + line('', 'spark', '두 군데 더 읽고 있어요'),
  comp: { send: 'stop', focus: false },
}, 'thinking'));
scene('task', '일 턴 진행 (선택 질문 대기)', () => chatScene({
  headOpts: { status: '답을 기다려요', dot: 'wait' },
  log: mine('내일 저녁 파스타집 예약해 줘')
    + nacho('일로 맡았어요. 진행 상황은 여기에 보여 드릴게요.')
    + line('', 'spark', '자리를 알아보고 있어요')
    + `<div class="card"><div class="q">${icon('question')}<span>어느 시간이 좋아요?</span></div>
        <div class="opts"><button class="opt">저녁 7시</button><button class="opt">저녁 8시</button></div>
        <div class="st wait">골라 주세요</div></div>`
    + line('task', 'task', '파스타집 예약 <span class="sep">·</span> 답을 기다려요'),
}, 'idle'));
scene('task-done', '일 턴 결과', () => chatScene({
  log: mine('내일 저녁 파스타집 예약해 줘')
    + nacho('일로 맡았어요. 진행 상황은 여기에 보여 드릴게요.')
    + `<div class="card"><div class="q">${icon('question')}<span>어느 시간이 좋아요?</span></div>
        <div class="opts"><button class="opt chosen">저녁 7시</button><button class="opt">저녁 8시</button></div>
        <div class="st">골랐어요</div></div>`
    + nacho('내일 저녁 7시, 파스타 리코에 2명으로 예약했어요. 취소는 오후 5시까지 돼요.')
    + line('task', 'task', '파스타집 예약 <span class="sep">·</span> 끝냈어요 <span class="ok">✓</span>'),
}, 'happy'));
scene('choice', '선택 질문 · 승인 요청(폰에서)', () => chatScene({
  log: mine('주말에 부모님 선물 보내 줘')
    + `<div class="card"><div class="q">${icon('question')}<span>어떤 걸로 할까요?</span></div>
        <div class="opts"><button class="opt">과일 바구니</button><button class="opt">홍삼 세트</button><button class="opt">꽃다발</button></div>
        <div class="st wait">골라 주세요</div></div>`
    + `<div class="card"><div class="q">${icon('phone')}<span>결제할까요?</span></div>
        <div class="detail">선물가게 · 39,000원 · 배송 전까지 취소할 수 있어요</div>
        <div class="st wait">휴대폰의 나초 앱에서 승인해 주세요</div></div>`,
}, 'idle'));
scene('attach', '첨부: 캡처 → 펫 · 선반 → 펫', () => chatScene({
  log: mine('이 그림 뭐야?', `<div class="attach-line"><span class="file">${icon('image')}<span>캡처 14.32.05.png</span></span></div>`)
    + nacho('맥의 “시스템 설정 ▸ 배터리” 화면이에요. 지난 24시간 배터리 사용량 그래프가 보여요.'),
  pending: `<div class="pending">
      <span class="chip"><span class="thumb"></span><span class="nm"><b>캡처 14.40.11.png</b><span>그림 · 보여요</span></span><span class="x">${icon('x')}</span></span>
      <span class="chip"><span class="thumb doc">${icon('doc')}</span><span class="nm"><b>회의 메모.md</b><span>글 · 읽어요</span></span><span class="x">${icon('x')}</span></span>
    </div>`,
  comp: { text: '두 개 같이 정리해 줘', send: '' },
}, 'idle'));
scene('files', '나초가 만든 파일 링크', () => chatScene({
  log: mine('회의 메모를 표로 정리해 줘')
    + nacho('정리했어요. 결정 3개, 할 일 5개예요.')
    + `<div class="row nacho" style="gap:var(--space-xs);flex-wrap:wrap">${file('회의 정리.csv')}${file('회의 요약')}</div>`
    + `<div class="row nacho"><span class="file gone">${icon('image')}<span>예전 캡처.png (지워짐)</span></span></div>`,
}, 'happy'));
scene('memory', '기억 줄 · 잊어 줘 · 되돌리기 · 기억이 틀렸어요', () => chatScene({
  log: mine('나 요즘 고양이 키워')
    + nacho('와, 좋겠어요! 이름이 뭐예요?')
    + line('memory', 'memory', '기억했어요: 고양이를 키워요 <span class="sep">·</span> <a class="link">잊어 줘</a>')
    + mine('내가 좋아하는 음식 알아?')
    + nacho('매운 음식을 좋아하신다고 기억해요.')
    + line('memory', 'memory', '잊었어요: 매운 음식을 좋아함 <span class="sep">·</span> <a class="link">되돌리기</a> <span class="sep">(10초)</span>')
    + line('memory', 'memory', '이 답에 기억 1개를 썼어요 <span class="sep">·</span> <a class="link">기억이 틀렸어요</a>'),
}, 'idle'));
scene('history', '이전 대화 이어보기 · 폰에서 보낸 말', () => chatScene({
  log: `<button class="older">${icon('up')}이전 대화 더 보기</button>`
    + mine('어제 파스타집 알아봐 줬지?').replace('class="bubble"', 'class="bubble past"')
    + nacho('네, 강남역 근처 세 곳을 찾아 드렸어요.', true)
    + `<div class="note">나초가 문서를 만들었어요</div>`
    + mine('폰에서: 7시로 해 줘').replace('class="bubble"', 'class="bubble past"')
    + `<div class="divider">이번 대화</div>`
    + mine('예약 확인해 줘') + nacho('내일 저녁 7시, 파스타 리코에 예약돼 있어요.'),
}, 'idle'));
scene('signin', '로그인 요청', () => desk(`<div class="chat" role="dialog">${head({ status: '로그인 전', dot: 'off', credits: '' })}
  <div class="signin"><img src="${ART}happy.png" alt=""><h2>안녕하세요, 나초예요.</h2>
  <p>나초 계정으로 로그인하면 여기서 대화할 수 있어요. 캡처나 선반의 파일을 건네거나, 창 배치와 가젯 켜기·끄기도 부탁할 수 있어요.</p>
  <button class="primary">${icon('person')}나초 계정으로 로그인</button>
  <small>로그인은 브라우저 창(auth.nachotown.com)에서 해요. 비밀번호는 콤보가 보지 않아요.</small></div></div>${pet('waiting')}`));
scene('error', '오류 · 점검 안내', () => chatScene({
  headOpts: { status: '연결됨', dot: 'wait' },
  banner: `<div class="banner warn">${icon('warn')}<span>나초 서버 점검 중이에요. 오후 3시까지예요.</span></div>`,
  log: mine('오늘 일정 알려줘')
    + line('danger', 'warn', '서버가 답을 만들지 못했어요. 잠시 뒤 다시 시도해 주세요.')
    + mine('다시 알려줘')
    + line('danger', 'warn', '연결이 끊겨 답이 끝나지 않았어요. 다시 연결되면 이어서 보여 드려요.')
    + line('notice', 'mic', '잠시 너무 많이 요청했어요. 오후 3:05에 다시 해 주세요.'),
}, 'waiting'));
scene('credits', '크레딧 (표시만 · 모자랄 때)', () => chatScene({
  headOpts: { credits: '크레딧 12' },
  log: mine('이번 주 회의록 다 정리해 줘')
    + line('danger', 'credit', '지금은 일을 맡길 수 없어요. 크레딧이 모자라요.')
    + line('', 'bell', '크레딧 — 10 받았어요')
    + line('usage', 'credit', '크레딧 12/200 <span class="sep">·</span> 가벼운 대화 48/50 <span class="sep">·</span> 얼마 안 남았어요'),
}, 'idle'));
scene('settings', '설정의 나초 펫 카드', () => `<div class="stage" style="width:640px;height:484px"><div class="settings">
  <div class="titlebar"><i></i><i></i><i></i><span>Nacho Combo</span></div>
  <div class="gadget-head"><img src="${ART}idle.png" alt=""><div><b>Nacho Pet</b><span>Signed in as your Nacho account · Connected · can arrange windows</span></div><span class="toggle"></span></div>
  <div class="scard">
    <h3>Nacho Account</h3>
    <div class="srow"><span class="grow">Signed in as your Nacho account · Connected</span><button class="btn">Sign Out</button></div>
    <h3>Server</h3>
    <span class="popup">Production (nacho.nachotown.com) ${icon('down')}</span>
    <span class="cap2">https://nacho.nachotown.com · login https://auth.nachotown.com/realms/nachotown</span>
    <h3>On This Mac</h3>
    <span class="check"><i>${icon('check')}</i>Let Nacho snap windows and switch gadgets on this Mac</span>
    <span class="cap2">Nacho can snap the front window (Window Snap's Accessibility permission) and switch other gadgets on or off. Never Computer Use, never Nacho Pet itself, and never a gadget that still needs a permission.</span>
    <button class="btn" style="align-self:flex-start">Put Nacho Back in the Corner</button>
    <span class="cap3">The Nacho character is © Mafianacho, all rights reserved: it is not part of the MIT-licensed source code (see TRADEMARKS.md).</span>
  </div></div></div>`);

// ---------- page ----------
const q = new URLSearchParams(location.search);
const id = q.get('scene');
const theme = q.get('theme') === 'dark' ? 'dark' : 'light';
const root = document.getElementById('root');
if (q.get('still') !== '0') document.body.classList.add('still');  // captures: freeze animations at their rest pose
if (!id || !S[id]) {
  document.documentElement.dataset.theme = 'light';
  root.innerHTML = `<div class="index"><h1>Nacho Pet — 웹 시안 (${Object.keys(S).length}장면)</h1><ol>${Object.entries(S).map(([k, v]) =>
    `<li><a href="?scene=${k}">${esc(v.title)}</a> · <a href="?scene=${k}&theme=dark">다크</a> · <a href="?scene=${k}&pair=1">나란히</a> · <a href="?scene=${k}&still=0">움직임</a></li>`).join('')}</ol></div>`;
} else if (q.get('pair')) {
  root.innerHTML = `<div class="pair" id="capture">${['light', 'dark'].map((th) =>
    `<div class="stage-wrap" data-theme="${th}">${S[id].render()}<div class="scene-label">${th === 'light' ? '라이트' : '다크'} · ${esc(S[id].title)}</div></div>`).join('')}</div>`;
} else {
  document.documentElement.dataset.theme = theme;
  root.innerHTML = `<div id="capture" style="display:inline-block">${S[id].render()}</div>`;
}
window.SCENES = Object.fromEntries(Object.entries(S).map(([k, v]) => [k, v.title]));
