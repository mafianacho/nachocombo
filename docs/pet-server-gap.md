# Nacho Pet ↔ nacho-server: gap analysis (LLM features)

Basis: nacho-server `origin/main` **2db5f4e** (2026-11-11), read only: `spec/*.tsp`, `docs/ws-protocol.md`,
`docs/error-codes.md`, ADR 0004·0011·0014·0020–0026, `docs/app-gap-*.md`, `docs/app-server-answers.md`,
`docs/app-sync-4e3b0a46.md`. The server was not run; "구현" = route registered in the server's router (code read), runtime
behaviour on production is not verified. The pet's REST routes are pinned in
`Tests/NachoComboCoreTests/PetServerContractTests.swift`; `scripts/check-server-contract.sh <nacho-server>` re-checks them.

Legend — 결정: **구현** = done in this change · **유지** = already used · **보류** = analysed only, needs a boss decision ·
**불필요** = not for a desktop pet.

## 1. Table

| 영역 | 엔드포인트 / 프레임 | 펫 쓸모 | 결정 | 의존 (플래그·결제·권한) |
|---|---|---|---|---|
| 대화 | WS `/ws/chat` `message`·`stop`·`ping` | 대화 본체 | 유지 | Keycloak azp `nacho-gadget-app` 허용(L2) |
| 대화 | WS `read {room_id,seq}` | 펫에서 본 답을 폰 앱이 안 읽음으로 세지 않게 | **구현** | — |
| 이어보기 | `GET /api/v1/rooms/{id}/history?view=app&limit&before_seq` (+`X-Has-More`) | 열면 이전 대화, 위로 더 보기 | **구현** | — |
| 이어보기 | `GET /api/v1/rooms/{id}/delta?view=app&since_seq` | 끊긴 동안 서버가 끝낸 답 채우기 | **구현** | — |
| 이어보기 | `GET /rooms/sync`, `/rooms`, `/rooms/{id}`, `/rooms/{id}/state` | 다른 방 목록·대기 카드 재조회 | 보류(1:1 방만 쓰는 지금은 불필요) | — |
| 진행 표시 | `activity{kind,tool}` 11종 | 상태 줄 한국어 | **구현**(라벨) | — |
| 진행 표시 | `tool_call_started/finished` | 🔧 도구 이름 ✓/✕ | **구현** | task 경로·단톡엔 없음(서버 설계) |
| 진행 표시 | 중간 답 `message{interim:true}` (ADR-0021) | "찾아보고 있어요" 줄, 답과 분리 | **구현** | `interim_reply` 설정(기본 3 s/30 s) |
| 진행 표시 | `turn_started/done{task_id}` + 허브 `task_update`·`message{task_result}` | 일로 넘어간 턴의 진행·결과를 그 턴에 붙임 | **구현** | Jev 라우팅(기본 ON) — 많은 턴이 이 경로 |
| 진행 표시 | `card_update` + `POST /api/v1/chat/requests/{id}/answer` | 선택 질문(choice·suggestions) 펫에서 답, 409 시 최신 카드 재조회 | **구현**(choice만) | `expected_version` |
| 진행 표시 | 승인 카드(결제·전화·발송·삭제) 답하기 | 맥에서 실행/거절 (번호·숫자키) | **구현** | 나초파더 결정 1570802313768083457 (선택 UI) |
| 첨부 | `POST /api/v1/media/uploads` → `{attachment_id}` | 캡처·선반·드롭 | 유지(공식 경로 확인) | 20 MB, MIME 허용목록 |
| 첨부 | 답의 `attachments[]`(`origin:"agent"`)·`attachment{page}` | 나초가 만든 파일 열기(서명 URL) | **구현** | 서명 URL 600 s |
| 첨부 | `GET/DELETE /api/v1/media/{id}` | 미리보기·삭제 | 보류(서명 URL로 충분) | — |
| 받아쓰기 | `GET /client/config` → `dictation{enabled,max_sec,max_bytes}` | 마이크 경로 선택 | **구현** | 비인증 |
| 받아쓰기 | `POST /api/v1/dictation` (multipart, ADR 0014) | 서버 받아쓰기(무과금) | **구현** | provider 운영값 미확인(기본 mock), 분 20·일 300 |
| 기억 | WS `memory_update` (`update_id` 중복 제거) | 🧠 기억했어요 줄 | **구현** | `memory_paused` 면 없음 |
| 기억 | `DELETE /api/v1/memory/facts/{id}`·`/episodes/{id}`, `POST /api/v1/memory/{id}/restore` | 잊어 줘 / 10초 되돌리기 | **구현** | 410 `restore_expired` |
| 기억 | `POST /api/v1/memory/feedback` (+`Idempotency-Key`) | "기억이 틀렸어요" 교정(`used_memory_ids`) | **구현** | — |
| 기억 | `GET /memory/facts?ids=`, `/facts` CRUD·검색, `/me/memory-settings`, `DELETE /me/memories` | 기억 목록·일시정지·전체 삭제 | 보류(프라이버시 UI 결정) | 전체 삭제는 되돌릴 수 없음 |
| 사용량 | WS `usage{…,state}`, `GET /api/v1/me/usage` | 크레딧·가벼운 대화 표시(읽기) | **구현** | — |
| 사용량 | `GET /me/usage/ledger`, `GET /api/v1/plans` | 사용 내역·요금제 | 보류(표시만이면 후속) | — |
| 결제 | `/credits/purchases`, `/billing/*`, `/toss/*` | 구매 | **보류** | `billing_enabled`, 스토어 provider, 보스 결정 |
| 오류 | `docs/error-codes.md` 전체 코드 + `reason` | 한국어 안내, 영어 `message` 미노출 | **구현** | 열린 집합(모르는 코드 = 일반 문구) |
| 서버 상태 | `client/config.service_status` | 점검·종료 안내 | **구현** | — |
| 음성 | `POST /api/v1/voice/calls` 등 (LiveKit) | 음성 통화 | **보류** | `[voice] provider`(기본 mock), `voice.enabled`, 분당 과금 |
| 단톡 | `/rooms/{id}/invitations`, `/invitations/*`, `room_invited` | 그룹방 초대 | **보류** | `caps.group_invites_per_day` |
| 단톡 | `/rooms/agent-group`, `/rooms/group`, run 이벤트 | 나초끼리·사람 단톡 | 불필요(펫 = 1:1) | ADR-0013 |
| 연결 | `GET /api/v1/connections`, `GET /api/v1/tools` | 연결 탭 | 유지 | — |
| 연결 | `/connections/begin`·`/attempts/*`·`/vault/*`·`/secure/*` | 연결 만들기·비밀 입력 | 불필요(폰 앱 담당, 비밀은 펫이 안 받음) | — |
| 커넥터 | `POST /agents/{id}/connector-binding`, WS `/ws/connector` | 창 배치·가젯 켜기 | 유지 | — |
| 작업 | `GET /api/v1/tasks…`, `POST /tasks/{id}/cancel`·`continue`·`instruction` | 작업 목록·취소 | 보류(취소는 후속 후보) | 409 `estimate_changed` |
| 기타 | `turn_meta` | 디버그 | 불필요(무시) | 비영속 |
| 기타 | `notification` | `credit_granted` 등 한 줄 | **구현**(크레딧·커넥터 종류만) | — |
| 기타 | 푸시 토큰, 소셜, 공유, 지식, 보관함, 예약, MCP(`POST /mcp`), admin | — | 불필요 | admin 은 realm role `admin` |

## 2. 보스 결정 항목 (구현 보류)

1. **음성 통화 (LiveKit):** 맥에서 나초와 통화. 서버 provider 기본 mock, 운영 LiveKit 자격·분당 과금 필요. 기본안: 보류.
2. **결제·구매:** 크레딧 팩·구독 구매. 기본안: 펫은 잔량 표시만, 구매는 폰 앱.
3. **그룹방 초대:** 기본안: 펫은 1:1 방만.
4. **승인 카드를 맥에서 답하기:** 결제·전화·발송·삭제 승인. → 구현: 실행(위)·거절(아래), 번호·숫자키 (나초파더 1570802313768083457).
5. **기억 관리 화면 (목록·일시정지·전체 삭제):** 기본안: 보류, 지금은 기억 줄의 잊어 줘/되돌리기/교정만.

## 3. 현재 펫과 서버 계약의 차이 → 이번에 고친 것

- 일로 넘어간 턴(`done{task_id}`)은 글 스트림이 없고, 답은 나중에 허브(`client_id` 없음)로 온다 → `task_id` 로 그 턴에 붙인다.
- 중간 답(`interim:true`)을 답 말풍선이 아니라 진행 줄로.
- 질문 echo(`message` role user)로 그 턴의 seq 를 잡고, 끊긴 뒤 `delta?since_seq` 로 이어 붙인다(질문 echo 가 이미 온 경우 delta 에 답만 있어도 붙는다).
- `memory_update` 는 턴 스트림과 허브 두 길로 올 수 있다 → `update_id` 로 한 줄.
- `usage` 는 `state`(UsageState 전체)·`light_chat_used/cap` 포함 → 표시.
- 오류: `docs/error-codes.md` 코드 전부 한국어, `too_many_requests` 는 `reason`(다시 가능한 시각) 표시.

## 4. 열린 질문 (운영 미확인)

- 운영 받아쓰기 provider(`openrouter` 인지)와 `client/config.dictation.enabled` 값.
- 운영 Keycloak 에 `nacho-gadget-app` 클라이언트·`allowed_azp` 반영(L2 담당).
- 허브 이벤트 유실(`Lagged`) 시 서버는 버린다 → 펫은 재접속마다 delta 로 메운다(이번 구현). 주기적 재조회는 후속.
- ADR-0021 본문의 "interim 은 와이어에 없다"는 낡음 — spec(`rooms.tsp`)과 코드는 싣는다. spec 을 따랐다.
