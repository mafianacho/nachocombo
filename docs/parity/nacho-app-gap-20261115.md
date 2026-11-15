# 나초 앱 ↔ 나초콤보 기능 차이 표

이슈: NACHO-265 (상위 NACHO-264 W1). 조사·문서 전용, 제품 코드 변경 없음.

## 기준 (조사 시작 시 origin/main)

| 레포 | SHA | 비고 |
|---|---|---|
| mafianacho/nacho-app | `69e1dd46b960c70cc954a15115173aa28abb6571` | 라우트 `app/**`, API `src/api/real/*-calls.ts`, `real-server.ts` |
| mafianacho/nachocombo | `342c8e7` (v0.10.2) | `Sources/NachoComboCore/Pet/*`, `Sources/NachoCombo/Pet/*`, README |
| mafianacho/nacho-server | `3b3c547855422c6e23b753d028eb55d44fcb5eaf` | `crates/adapters/http/assets/openapi.json` 의 경로·메서드 288개와 대조 |

진행 중(아래 표에서 "진행 중"으로 따로 표시): nachocombo #47 연결 탭 개편(NACHO-239/131), nacho-server #58 IDP-010(MAFI-18), 윈도우판 nachocombo-windows(열린 PR #8 NACHO-177 위젯 보드; NACHO-170 이름의 PR은 찾지 못함, 아래 "확인 못 한 것").

## 요약

기능 64행(화면·기능 묶음 기준. 서버 API 호출은 부록 A에 212개를 전부 나열).

| 나초콤보 상태 | 건수 |
|---|---|
| 있음 | 13 |
| 일부 | 5 |
| 없음 | 33 |
| 진행 중 | 4 |
| 제외 | 9 |

(`있음(읽기)`는 있음으로 센다.)

**서버 쪽 추가가 필요한 항목:** 표의 모든 기능이 쓰는 REST 경로는 nacho-server origin/main openapi에 존재한다(부록 A: 앱 호출 212개 중 211개 일치, 나머지 1개는 `/rooms/{id}/{files|links}` 로 경로가 합쳐진 호출이라 둘 다 존재). 새로 만들어야 하는 서버 API는 이 조사에서 찾지 못했다. 서버 쪽 확인이 남는 것은 다음 둘이다.

1. 통합 Keycloak 토큰 수용: nacho-server #58 IDP-010, 기본 꺼짐, 진행 중 (A1).
2. 도구 켜기/끄기 운영 반영(NACHO-132): openapi에는 `PUT /tools/{id}/switch` 있음, 운영 반영은 확인 못 함 (E6).

또 하나 일반 주의: 라우트가 있어도 나초콤보가 쓰는 Keycloak 클라이언트(`nacho-gadget-app`)로 그 경로를 부를 수 있는지는 서버 인증 설정 문제라 이 조사에서 확인하지 못했다. 새로 붙이는 기능마다 시험 요청으로 확인한다.

## 보스 결정 항목 (별도 표시)

범주: ① 파괴적 DB 마이그레이션 ② 시크릿 추가·변경 ③ 유료 서비스 ④ 서명·공증 변경 ⑤ Mac 내용(클립보드·화면·파일)을 서버로 보내는 새 행동.

| 행 | 기능 | 범주 | 이유 |
|---|---|---|---|
| B15 | 음성 통화 | ③ | 분당 과금·운영 LiveKit 자격 필요 (`docs/pet-server-gap.md` §2-1) |
| H3 | 크레딧 구매 | ③ | 결제·비용 |
| E3 | 앱 비밀번호 입력 연동 | ② 인접 | 사용자 자격 증명을 맥에서 서버로 보낸다(서버 시크릿 변경은 아님). 판단 요청 |
| B14 | 카드 /step·/security-code | ② 인접 | 비밀 입력 단계. 현재 폰 앱 전용 |
| F3, C3 | 사진 만들기·예약 지금 실행 | ③ 확인 | 크레딧 소모. 유료 서비스 범주인지 판단 요청 |
| A4, D3 | 계정 삭제·기억 전체 삭제 | 해당 없음(주의) | 5개 범주 밖이지만 되돌릴 수 없는 삭제 |

① 파괴적 DB 마이그레이션, ④ 서명·공증 변경에 걸리는 기능은 찾지 못했다(표의 어떤 기능도 서버 스키마·서명 변경을 요구하지 않음). ⑤는 새 행동으로는 없다. 이미 있는 것은 받아쓰기(B13)의 마이크 소리, 캡처·선반 첨부(B10)이고, 이번 표의 새 기능에는 맥 화면·클립보드를 서버로 보내는 항목이 없다.

## 기능 차이 표

열: 기능 | 나초 앱 위치(file:line) | 나초콤보 상태 + file | 쓰는 서버 API | 서버 쪽 추가 필요 | 보스 결정. 앱 경로는 `app/(app)/` 아래이거나 표기된 경로다.

"일부"는 `—`로 빠진 것을 한 줄로 적었다. 나초콤보 `있음/일부` 근거는 `file:line`, 근거 없는 행은 없다(`없음`은 해당 코드가 없음을 뜻하며 근거는 `git grep` 결과 0건).

### 계정

| ID | 기능 | 나초 앱 위치 | 나초콤보 상태 · 근거/빠진 것 | 쓰는 서버 API | 서버 추가 필요 | 보스 결정·비고 |
|---|---|---|---|---|---|---|
| A1 | 로그인 (Keycloak) | `app/login.tsx:3` | **있음** · `Sources/NachoComboCore/Pet/PetAuth.swift:208` (PKCE, 클라이언트 `nacho-gadget-app`) | Keycloak OIDC(서버 REST 아님) | 불명: 통합 토큰 수용은 nacho-server #58(IDP-010) 진행 중, 기본 꺼짐 |  |
| A2 | 온보딩(약관 동의·프로필·캐릭터 고르기·초대코드·대기열) | `app/onboarding/[step].tsx:3`, `app/index.tsx:3`, `app/consent-update.tsx:3` | **없음** · 가입은 폰 앱에서 끝낸 계정만 로그인 가능(PetAuth만 있음) | GET /api/v1/me/onboarding, POST /api/v1/me/onboarding/submit·back·region-waitlist·invite-waitlist (`real-server.ts:459-613`) | 불필요(존재) |  |
| A3 | 로그아웃 | `settings/account.tsx:3` | **있음** · `Sources/NachoCombo/Pet/PetSettingsCard.swift:5` (설정 탭·우클릭 메뉴) | 없음(토큰 폐기는 로컬) | 불필요 |  |
| A4 | 계정 삭제·삭제 취소·내 데이터 내보내기 | `settings/my-data.tsx:6`, `settings/account.tsx:3` | **없음** · — | DELETE /api/v1/me, GET /me/deletion-preview·deletion-status·export, POST /me/deletion/cancel (`settings-calls.ts:62-95`) | 불필요(존재) | 삭제는 되돌릴 수 없음: 맥에서 새로 열면 보스 확인 권장 |
| A5 | 이름·핸들·생일 수정 | `settings/name.tsx:3`, `settings/handle.tsx:3`, `settings/birthday.tsx:3` | **없음** · — | GET·PATCH /api/v1/me, GET /me/handle-check (`settings-calls.ts:20-37`) | 불필요(존재) |  |
| A6 | 개인정보·안전 설정(친구 찾기 허용 등), 연락처 일치 삭제 | `settings/privacy-safety.tsx:3`, `settings/data-privacy.tsx:3` | **없음** · — | GET·PATCH /api/v1/me/privacy-settings, DELETE /me/contact-matches (`social-calls.ts:141-149`) | 불필요(존재) |  |
| A7 | 알림 설정·알림 목록·활동 피드 | `settings/notifications.tsx:3`, `notifications.tsx:4`, `activity.tsx:1` | **일부** · WS `notification` 프레임 중 크레딧·커넥터 종류만 한 줄로 표시(`PetFrames.swift:99`). 목록·읽음·설정 화면 없음 | GET·PATCH /me/notification-settings, GET /me/notifications, POST /me/notifications/{id}/read, GET /activity, POST /activity/seen (`settings-calls.ts:41-54`, `explore-calls.ts:40-44`) | 불필요(존재) |  |
| A8 | 푸시 토큰 등록·해제 | `src/api/real/notification-calls.ts:62,81` | **제외** · 모바일 푸시(FCM) 전용. 맥은 앱이 떠 있을 때 WS로 받음 | POST /api/v1/me/push-tokens, DELETE /me/push-tokens/{token} | 불필요 | 제외: 푸시 권한은 모바일 전용 |
| A9 | 약관·법적 고지·라이선스 화면 | `settings/legal.tsx:3` | **없음** · — | 없음(정적 화면) | 불필요 |  |
| A10 | 이슈 신고·사용자 신고 | `settings/issue-report.tsx:3`, `report.tsx:1` | **없음** · — | POST /api/v1/issue-reports, POST /users/{id}/report (`settings-calls.ts:58`, `explore-calls.ts:49`) | 불필요(존재) |  |
| A11 | 화면 모양·글자 크기 | `settings/appearance.tsx:3`, `settings/text-size.tsx:3` | **제외** · 모바일 접근성 설정. 맥은 시스템 설정을 따른다 | 없음 | 불필요 | 제외: 모바일 전용 UI 설정 |
| A12 | 홈 화면 위젯 안내 | `widget.tsx:1`, `settings/widget-guide.tsx:1` | **제외** · 안드로이드 홈 위젯(`modules/nacho-system/android/.../NachoWidgetProvider.kt`). 맥은 펫이 상시 표시 | 없음 | 불필요 | 제외: 안드로이드 위젯 |

### 대화

| ID | 기능 | 나초 앱 위치 | 나초콤보 상태 · 근거/빠진 것 | 쓰는 서버 API | 서버 추가 필요 | 보스 결정·비고 |
|---|---|---|---|---|---|---|
| B1 | 1:1 대화(보내기·스트리밍 답·도구 진행 표시) | `app/(tabs)/chat.tsx:19`, `rooms/[room_id]/index.tsx:16`, `src/features/chat/room-screen.tsx` | **있음** · `Sources/NachoComboCore/Pet/PetChatClient.swift:44` (`/ws/chat`), `PetChatWindow.swift`(말풍선), `PetFrames.swift:69-106`(프레임) | WS /ws/chat, POST /api/v1/rooms/{id}/messages (`real-server.ts:661`) | 불필요(존재) |  |
| B2 | 답 멈추기 | `real-server.ts:691` | **있음** · `PetSession.swift:509`, `PetFrames.swift:131` (WS `stop`) | POST /api/v1/rooms/{id}/reply/stop | 불필요(존재) |  |
| B3 | 이전 대화 불러오기·끊긴 동안 답 채우기 | `real-server.ts:365,637`, `room-calls.ts:83` | **있음** · `PetServerAPI.swift:58,62`, `PetSession.swift:698` | GET /rooms/{id}/history, GET /rooms/{id}/delta | 불필요(존재) |  |
| B4 | 읽음 표시 | `room-calls.ts:33` | **있음** · `PetFrames.swift:133` (WS `read`) | PUT /rooms/{id}/read | 불필요(존재) |  |
| B5 | 마크다운·링크 렌더 | `src/features/chat/markdown-text.tsx`, `link-sheet.tsx` | **있음** · `Sources/NachoComboCore/Pet/PetMarkdown.swift` | 없음 | 불필요 |  |
| B6 | 대화방 목록·보관한 대화·방 전환 | `conversations/stored.tsx:4`, `room-calls.ts:17,29,96` | **없음** · 펫은 Nacho 한 방만 (`docs/pet-server-gap.md` §1 "보류") | GET /rooms/sync, GET /rooms?stored=, GET /rooms/{id} | 불필요(존재) |  |
| B7 | 대화 제목 바꾸기·보관·방 삭제 | `room-calls.ts:58-70` | **없음** · — | PATCH·DELETE /rooms/{id} | 불필요(존재) |  |
| B8 | 메시지 검색 | `room-calls.ts:75,104` | **없음** · — | POST /api/v1/messages/search | 불필요(존재) |  |
| B9 | 메시지 지우기(redact) | `room-calls.ts:39` | **없음** · — | POST /rooms/{id}/messages/{seq}/redact | 불필요(존재) |  |
| B10 | 파일·사진 첨부 보내기 | `src/features/chat/attach-sheet.tsx`, `archive-calls.ts:68` | **일부** · 캡처·선반·드롭·클립(최대 4개)은 있음(`PetMedia.swift:52,144`). 카메라·갤러리 선택기 없음(모바일 전용이라 제외 대상) | POST /api/v1/media/uploads | 불필요(존재) |  |
| B11 | 받은 파일 열기·파일 뷰어·문서 페이지 | `file-viewer.tsx:7`, `pages/[id].tsx:5`, `archive-calls.ts:54-59` | **일부** · 나초가 만든 파일은 눌러 열기(서명 URL, `docs/pet-server-gap.md` §1). 앱 안 뷰어·페이지(`pages`) 화면·마크다운 내려받기 없음 | GET /pages/{id}, GET /pages/{id}/download, GET·DELETE /media/{id} | 불필요(존재) |  |
| B12 | 대화 미디어 모아보기·링크·파일 목록 | `rooms/[room_id]/media.tsx:5`, `archive-calls.ts:83-90` | **없음** · — | GET /rooms/{id}/media, /rooms/{id}/files, /rooms/{id}/links | 불필요(존재) |  |
| B13 | 받아쓰기(마이크 → 글) | `src/api/real/dictation-calls.ts:28` | **있음** · `PetServerAPI.swift:88`, `PetDictation.swift`, 서버가 꺼져 있으면 맥 음성 인식 | POST /api/v1/dictation | 불필요(존재) | 마이크 소리를 서버로 보냄(이미 출시된 동작, 새 행동 아님) |
| B14 | 선택·승인 카드, 제안 칩, 규칙 제안 | `src/features/cards/render-card.tsx`, `card-calls.ts:51` | **일부** · 선택·다중 선택·승인(실행/거절)·제안 칩·규칙 제안 있음(`PetCardRules.swift:66`, `PetServerAPI.swift:120`). 로그인·보안코드·카드 입력 단계는 폰 앱 전용 | POST /chat/requests/{id}/answer, /step, /security-code, GET /chat/requests(·/{id}) | 불필요(존재) | /step·/security-code는 비밀 입력: 맥에서 열면 보스 확인 |
| B15 | 음성 통화(LiveKit)·통화 화면 | `voice/[agent_id].tsx:8`, `call/[call_id].tsx:8`, `room-calls.ts:117-152` | **없음** · `docs/pet-server-gap.md` §2-1 보류(분당 과금) | POST /voice/calls, GET /voice/calls/active, GET·PATCH /voice/calls/{id}, POST /voice/calls/{id}/end | 불필요(존재). 운영 LiveKit·과금은 확인 못 함 | 유료 서비스(분당 과금)·마이크 상시: 보스 결정 |
| B16 | 전화 통화 모니터링·메모·끊기 | `call/[call_id].tsx:8`, `task-calls.ts:21,25,32` | **없음** · — | POST /tasks/{id}/call/hangup, /call/note, GET /calls/{id} | 불필요(존재) |  |
| B17 | 그룹방 만들기·설정·멤버·초대 수락/거절 | `groups/new.tsx:1`, `groups/[room_id]/settings.tsx:5`, `invitations.tsx:3`, `invite-room/[invitation_id].tsx:8`, `agent-calls.ts:203-223`, `invite-calls.ts:54-105` | **없음** · 펫은 1:1만(`docs/pet-server-gap.md` §1 "불필요/보류") | POST /rooms/agent-group, GET·PATCH·DELETE /rooms/{id}/agent-group, POST /rooms/{id}/members·invitations, GET /invitations, POST /invitations/{id}/accept·decline, GET /rooms/{room}/my-invitation | 불필요(존재) |  |
| B18 | 대화 요청(모르는 사람이 보낸 요청) 수락/거절 | `pair/[room_id].tsx:7`, `room-calls.ts:45,53` | **없음** · — | POST /rooms/{id}/request/accept·decline, POST /social/message-requests | 불필요(존재) |  |

### 작업

| ID | 기능 | 나초 앱 위치 | 나초콤보 상태 · 근거/빠진 것 | 쓰는 서버 API | 서버 추가 필요 | 보스 결정·비고 |
|---|---|---|---|---|---|---|
| C1 | 작업 진행 표시·시작·취소(채팅 안) | `tasks/[task_id]/index.tsx:5`, `real-server.ts:701-710` | **있음** · `PetServerAPI.swift:125-138`, `PetSession.swift:990,1015`, 프레임 `task_update`(`PetFrames.swift:95`) | GET /tasks/{id}, POST /tasks/{id}/start·cancel | 불필요(존재) |  |
| C2 | 작업 목록·이어하기·로그·계획 화면 | `tasks/index.tsx:5`, `tasks/[task_id]/plan.tsx:12`, `real-server.ts:697,715`, `task-calls.ts:17,39` | **일부** · 채팅 말풍선 안 진행만. 목록·로그·이어하기·루틴 만들기·계획 화면 없음 | GET /tasks, GET /tasks/{id}/logs, POST /tasks/{id}/continue·routine-draft·instruction | 불필요(존재) |  |
| C3 | 예약 작업(목록·상세·일시정지·지금 실행·전달·삭제) | `schedules/index.tsx:4`, `schedules/[schedule_id]/index.tsx:4`, `brief.tsx:4`, `runs/[run_id].tsx:4`, `schedule-calls.ts:31-69` | **없음** · — | GET·DELETE /scheduled-actions(/{id}), POST /scheduled-actions/{id}/confirm·pause·run-now·test·transfer, GET /scheduled-actions/{id}/runs/{run_id} | 불필요(존재) | 지금 실행·테스트는 크레딧 소모 |
| C4 | 브라우저 작업 보기(라이브 뷰) | `browser/[task_id].tsx:1`, `browser/help.tsx:1`, `connection-calls.ts:156` | **없음** · — | POST /live-view/sessions, POST /connections/attempts/{id}/viewer-ticket | 불필요(존재) | 서버 → 맥 방향 화면 보기. 맥 화면을 서버로 보내는 행동 아님 |

### 기억

| ID | 기능 | 나초 앱 위치 | 나초콤보 상태 · 근거/빠진 것 | 쓰는 서버 API | 서버 추가 필요 | 보스 결정·비고 |
|---|---|---|---|---|---|---|
| D1 | 기억했어요 줄 + 잊어 줘·되돌리기 + 기억이 틀렸어요 | `src/features/memory/*`, `memory-calls.ts:137-156` | **있음** · `PetServerAPI.swift:98-110`, `PetChatState.swift:83,271` | POST /memory/feedback, DELETE /memory/facts|episodes/{id}, POST /memory/{id}/restore | 불필요(존재) |  |
| D2 | 기억 목록·상세·편집·직접 추가 | `memory/index.tsx:5`, `memory/[id]/index.tsx:5`, `memory/[id]/edit.tsx:5`, `memory-calls.ts:47,111-143` | **없음** · `docs/pet-server-gap.md` §2-5 보류(프라이버시 UI 결정) | GET·POST /memory/facts, GET·PATCH·DELETE /memory/facts/{id}, GET·PATCH·DELETE /memory/episodes(/{id}), POST /memory/facts/seen | 불필요(존재) |  |
| D3 | 기억 일시정지·표시 켜기/끄기·전체 삭제 | `memory-calls.ts:161-174` | **없음** · — | GET·PATCH /me/memory-settings, DELETE /me/memories | 불필요(존재) | 전체 삭제는 되돌릴 수 없음 |

### 연결

| ID | 기능 | 나초 앱 위치 | 나초콤보 상태 · 근거/빠진 것 | 쓰는 서버 API | 서버 추가 필요 | 보스 결정·비고 |
|---|---|---|---|---|---|---|
| E1 | 연결·도구 목록 읽기 | `connections/enabled.tsx:5`, `connections/index.tsx:8` | **진행 중** · 현재 읽기 전용 글 목록(`PetConnectors.swift:174-175`). nachocombo #47 이 도구/커넥터/가젯 3섹션 목록·검색·상세로 바꾼다 | GET /connections, GET /tools, GET /connections/catalog | 불필요(존재) |  |
| E2 | 커넥터 켜기/끄기·읽기/쓰기 범위·연결 해제 | `connections/[source]/index.tsx:10`, `connection-calls.ts:185-213` | **진행 중** · nachocombo #47 (PATCH /connections/{id}, PATCH …/scope, DELETE) | PATCH·DELETE /connections/{id}, PATCH /connections/{id}/scope, POST /connections/disconnect-all | 불필요(존재). 참고: 앱은 서비스 켜기/끄기에 `PUT /connections/{id}/switch`를 쓴다(`connection-calls.ts:147`). 이 경로는 nacho-server openapi에 있다(#47 본문은 "스펙에 없다"고 적고 `PATCH /connections/{id}`로 구현). 둘 다 존재하므로 코드카포가 어느 쪽을 쓸지 정하면 된다 |  |
| E3 | 서비스 추가(OAuth·앱 비밀번호) | `connections/[source]/app-password.tsx:5`, `connections/complete.tsx:6`, `connection-calls.ts:57,237` | **진행 중** · nachocombo #47: OAuth는 기본 브라우저, 앱 비밀번호는 맥 앱 안 입력. QR·사이트 로그인형은 맥에서 안내만 | POST /connections/begin, POST·DELETE /connections/attempts/{id}/app-password(/delegate), GET /connections/oauth/return, POST /connections/catalog/requests | 불필요(존재) | 앱 비밀번호(자격 증명)를 맥에서 서버로 보내는 새 행동: 보스 확인(시크릿 인접) |
| E4 | QR·사이트 로그인형 연동, 기기 권한 전달 | `connection-calls.ts:156,221,268` | **제외** · QR 스캔·카메라·모바일 기기 권한(`/connections/device`)은 모바일 전용. #47도 안내만 | POST /connections/attempts/{id}/viewer-ticket, POST /connections/device | 불필요 | 제외: 카메라·모바일 기기 권한 |
| E5 | 연결별 Nacho 허용·공유 대상 | `connections/sharing.tsx:6`, `connection-calls.ts:226-248` | **없음** · — | GET·PUT /connections/{id}/agents, GET /connections/sharing, PUT /connections/{id}/sharing | 불필요(존재) |  |
| E6 | 도구 켜기/끄기(사용자별) | `connection-calls.ts` 외 `src/features/connections/*` | **진행 중** · nachocombo #47 (PUT /tools/{id}/switch, 잠김 409). 서버 반영(NACHO-132) 전에는 되돌림 안내 | GET·POST /tools, PUT /tools/{id}/switch, DELETE /tools/{id} | 불명: openapi에는 PUT /tools/{id}/switch 존재, 운영 반영은 확인 못 함 |  |
| E7 | 자격 증명 사용 기록(금고 활동) | `vault/activity.tsx:9`, `trust-calls.ts:17` | **없음** · — | GET /api/v1/secure/log | 불필요(존재) |  |
| E8 | 승인 규칙 목록·삭제·한도 | `approval-rules.tsx:6`, `trust-calls.ts:21-30` | **없음** · 카드의 규칙 제안 적용만 있음(`PetCardRules.swift:66`) | GET·PATCH /me/approval-rules, DELETE /me/approval-rules/{id} | 불필요(존재) |  |

### 나초

| ID | 기능 | 나초 앱 위치 | 나초콤보 상태 · 근거/빠진 것 | 쓰는 서버 API | 서버 추가 필요 | 보스 결정·비고 |
|---|---|---|---|---|---|---|
| F1 | 캐릭터(종류별 그림·표정) 표시 | `assets/nacho/*`, `src/features/character/*` | **있음** · `PetCharacterAssets.swift:84` (서버 캐릭터 에셋), `PetCharacterView.swift` | GET /api/v1/character-assets(/files/{file}) | 불필요(존재) |  |
| F2 | Nacho 프로필·이름·말투·목소리 고르기 | `nacho/[agent_id]/index.tsx:7`, `name.tsx:5`, `speech.tsx:5`, `voice.tsx:5`, `edit.tsx:5` | **없음** · — | GET·PATCH /agents/{id}, GET /agents/{id}/voices, /voices, GET·POST /agents/{id}/traits(/refresh), DELETE …/traits/{id} | 불필요(존재) |  |
| F3 | Nacho 사진 만들기·고르기·지우기 | `nacho/[agent_id]/photo.tsx:5`, `agent-calls.ts:255-283` | **없음** · — | GET·POST /agents/{id}/photos, POST …/photos/{key}/select, DELETE …/photos/{key}, POST …/avatar/clear | 불필요(존재) | 사진 만들기는 크레딧 소모(유료 여부 확인 필요) |
| F4 | Nacho 목록·만들기·휴식·깨우기·삭제·권한(한도) | `agents/index.tsx:3`, `agents/new.tsx:5`, `agents/[agent_id]/permissions.tsx:5`, `agent-calls.ts:139-198` | **없음** · `PetConnectorClient.swift:36` 이 에이전트 하나에 커넥터를 붙이는 것만. 여러 Nacho 관리 없음 | GET·POST /agents, GET /agent-templates, PUT /agents/{id}/limits, POST /agents/{id}/default·rest·wake·restore, GET /agents/{id}/removal-preview, DELETE /agents/{id} | 불필요(존재) |  |
| F5 | 사용자·상대 프로필, 상대 캐릭터 | `users/[user_id]/index.tsx:3`, `users/[user_id]/character.tsx:3` | **없음** · — | GET /users/{id}/profile | 불필요(존재) |  |

### 친구

| ID | 기능 | 나초 앱 위치 | 나초콤보 상태 · 근거/빠진 것 | 쓰는 서버 API | 서버 추가 필요 | 보스 결정·비고 |
|---|---|---|---|---|---|---|
| G1 | 친구 목록·요청 보내기/수락/거절/취소·친구 삭제·차단 | `friends/index.tsx:3`, `friends/add.tsx:3`, `friends/requests/index.tsx:3`, `friends/requests/[user_id].tsx:3`, `friends/blocked.tsx:3`, `friends/[user_id].tsx:3`, `social-calls.ts:45-73` | **없음** · — | GET /social/summary, POST /social/friend-requests(·/{id}/accept|decline|cancel), DELETE /social/friends/{id}, POST·DELETE /social/blocks, GET /users/lookup | 불필요(존재) |  |
| G2 | 연락처에서 친구 찾기 | `friends/contacts.tsx:3`, `social-calls.ts:87` | **제외** · 주소록 권한·전화번호 해시 전송은 모바일 기능 | POST /social/contacts/match | 불필요 | 제외: 모바일 연락처 권한 |
| G3 | 전화번호 인증 | `phone.tsx:22`, `phone-calls.ts:34,49` | **제외** · SMS 인증 번호는 폰에서 받는 흐름. 맥은 폰 앱에서 끝낸 계정을 쓴다 | POST /me/phone/request·verify | 불필요 | 제외: 모바일 SMS 인증 |
| G4 | 친구 초대 코드·초대 링크·가입자 목록 | `invite/index.tsx:3`, `invite/signups.tsx:3`, `i/[code].tsx:6`, `social-calls.ts:104-117` | **없음** · — | GET /me/invites, POST /social/invites/{id}/dismiss, GET /i/{code}, POST /me/onboarding/invite/redeem | 불필요(존재) | 외부 발송(초대 문자·공유)이 붙으면 보스 확인 |
| G5 | 공유 설정(친구·낯선 사람·사람별 메모·제외 목록) | `sharing/index.tsx:3`, `sharing/friends.tsx:3`, `sharing/strangers.tsx:3`, `sharing/people/index.tsx:3`, `sharing/people/[user_id].tsx:5`, `sharing/people/pick.tsx:3`, `sharing/exclusions.tsx:3`, `sharing-calls.ts:34-52` | **없음** · — | GET·PATCH /sharing, PUT /sharing/exclusions, GET·PUT /sharing/people/{user_id} | 불필요(존재) |  |

### 사용량

| ID | 기능 | 나초 앱 위치 | 나초콤보 상태 · 근거/빠진 것 | 쓰는 서버 API | 서버 추가 필요 | 보스 결정·비고 |
|---|---|---|---|---|---|---|
| H1 | 크레딧 잔량·가벼운 대화 표시 | `usage.tsx:3`, `real-server.ts:629` | **있음(읽기)** · `PetServerAPI.swift:66`, `PetFrames.swift:85` | GET /me/usage | 불필요(존재) |  |
| H2 | 사용 내역(원장) | `usage.tsx:3`, `billing-calls.ts:14` | **없음** · `docs/pet-server-gap.md` 보류 | GET /me/usage/ledger | 불필요(존재) |  |

### 결제

| ID | 기능 | 나초 앱 위치 | 나초콤보 상태 · 근거/빠진 것 | 쓰는 서버 API | 서버 추가 필요 | 보스 결정·비고 |
|---|---|---|---|---|---|---|
| H3 | 요금제 보기·크레딧 팩 구매(토스)·구매 내역·영수증 | `plans.tsx:3`, `billing/history.tsx:6`, `billing/receipt.tsx:6`, `billing-calls.ts:18-64` | **없음** · `docs/pet-server-gap.md` §2-2: 펫은 잔량 표시만, 구매는 폰 앱 | GET /plans, GET·POST /credits/purchases, POST /credits/toss/confirm, GET /billing/purchases(/{id}) | 불필요(존재) | 결제·비용: 보스 결정 |
| H4 | 앱스토어 인앱 결제 구매·확인·복원 | `billing-calls.ts:24-35` | **제외** · Google Play 결제 전용(`STORE`) | POST /billing/purchases, /billing/purchases/{id}/confirm, POST /billing/restore | 불필요 | 제외: 스토어 결제(모바일) |

### 탐색

| ID | 기능 | 나초 앱 위치 | 나초콤보 상태 · 근거/빠진 것 | 쓰는 서버 API | 서버 추가 필요 | 보스 결정·비고 |
|---|---|---|---|---|---|---|
| I1 | 탐색 탭(추천 카드·제안 수락/거절) | `app/(tabs)/explore.tsx:3`, `explore-calls.ts:13-36` | **없음** · — | GET /explore/sections, POST /explore/offers/{id}/accept·reject·reject/undo | 불필요(존재) |  |
| I2 | 보관함(파일 목록·삭제·만들기 옵션) | `app/(tabs)/archive.tsx:3`, `archive-calls.ts:41-50` | **없음** · — | GET /archive/files, DELETE /archive/files/{id}, GET /archive/create-options | 불필요(존재) |  |

### 시스템

| ID | 기능 | 나초 앱 위치 | 나초콤보 상태 · 근거/빠진 것 | 쓰는 서버 API | 서버 추가 필요 | 보스 결정·비고 |
|---|---|---|---|---|---|---|
| J1 | 서버 점검·종료 안내, 서버 오류 한국어 문구 | `src/features/boot/boot-screens.tsx`, `src/api/real/real-server.ts:481` | **있음** · `PetSession.swift:29` (`/client/config`), `PetChatState.swift:376` 부근 오류 문구 | GET /client/config | 불필요(존재) |  |
| J2 | 공유 시트·딥링크·안드로이드 공유 인텐트 | `share.tsx:1`, `app/+native-intent.ts:1` | **제외** · 맥 대응은 "Give to Nacho"·드롭(맥 전용, 있음) | 없음 | 불필요 | 제외: 모바일 OS 인텐트 |
| J3 | 통화 알림·포그라운드 서비스·MediaProjection 계열 | `native/nacho-call/android/*` | **제외** · 안드로이드 전용 | 없음 | 불필요 | 제외: 안드로이드 전용 |

## 나초콤보에만 있는 것 (앱에 없음)

- 맥 가젯 13종과 콤보, 창·앱·소리·화면 밝기를 나초가 대신 조작(`PetCommands.swift:85`, `/ws/connector`, `PetConnectorClient.swift:36`).
- 눌러서 말하기(`PetVoice.swift:9`), 캡처·선반 파일을 나초에게 건네기, 선택한 글 바 (`PetSelection.swift`).
- Computer Use MCP, NachoCombo MCP (`docs/NACHOCOMBO-MCP.md`).

## 확인 못 한 것

- 운영 서버는 호출하지 않았다(코드·openapi 읽기만). 위 "존재"는 라우트가 openapi에 있다는 뜻이다.
- 윈도우판: `nachocombo-windows` 열린 PR은 #8(NACHO-177 위젯 보드)만 확인했고, NACHO-170 이름의 PR은 찾지 못했다. 윈도우판 기능은 이 표에 넣지 않았다(맥 기준).
- 실물 맥·실기기 동작은 확인하지 않았다.
- 경로 대조는 openapi의 경로 모양(`{}` 치환)·메서드 일치만 본다. 응답 모양·필드는 보지 않았다.

## 부록 A. 나초 앱의 서버 API 호출 전부 (`src/api/real/*.ts`, `request(...)` 기준)

호출 212개. 서버 열: openapi에 같은 메서드·경로가 있으면 존재. 콤보 열: 나초콤보가 이미 쓰는 경로면 사용. 같은 경로를 여러 곳에서 부르면 각각 한 줄.

| 앱 위치 | 메서드 | 경로 | nacho-server | 나초콤보 |
|---|---|---|---|---|
| `src/api/real/agent-calls.ts:50` | GET | `/api/v1/agents/{}` | 존재 |  |
| `src/api/real/agent-calls.ts:97` | GET | `/api/v1/rooms/{}/agent-group` | 존재 |  |
| `src/api/real/agent-calls.ts:129` | GET | `/api/v1/agents/{}/photos` | 존재 |  |
| `src/api/real/agent-calls.ts:139` | GET | `/api/v1/agents` | 존재 |  |
| `src/api/real/agent-calls.ts:152` | GET | `/api/v1/agent-templates` | 존재 |  |
| `src/api/real/agent-calls.ts:158` | POST | `/api/v1/agents` | 존재 |  |
| `src/api/real/agent-calls.ts:161` | PUT | `/api/v1/agents/{}/limits` | 존재 |  |
| `src/api/real/agent-calls.ts:168` | PATCH | `/api/v1/agents/{}` | 존재 |  |
| `src/api/real/agent-calls.ts:172` | PUT | `/api/v1/agents/{}/limits` | 존재 |  |
| `src/api/real/agent-calls.ts:176` | POST | `/api/v1/agents/{}/default` | 존재 |  |
| `src/api/real/agent-calls.ts:180` | POST | `/api/v1/agents/{}/rest` | 존재 |  |
| `src/api/real/agent-calls.ts:184` | POST | `/api/v1/agents/{}/wake` | 존재 |  |
| `src/api/real/agent-calls.ts:188` | POST | `/api/v1/agents/{}/restore` | 존재 |  |
| `src/api/real/agent-calls.ts:192` | GET | `/api/v1/agents/{}/removal-preview` | 존재 |  |
| `src/api/real/agent-calls.ts:198` | DELETE | `/api/v1/agents/{}` | 존재 |  |
| `src/api/real/agent-calls.ts:203` | POST | `/api/v1/rooms/agent-group` | 존재 |  |
| `src/api/real/agent-calls.ts:207` | GET | `/api/v1/rooms/{}/agent-group` | 존재 |  |
| `src/api/real/agent-calls.ts:212` | PATCH | `/api/v1/rooms/{}/agent-group` | 존재 |  |
| `src/api/real/agent-calls.ts:218` | POST | `/api/v1/rooms/{}/members` | 존재 |  |
| `src/api/real/agent-calls.ts:223` | DELETE | `/api/v1/rooms/{}/agent-group` | 존재 |  |
| `src/api/real/agent-calls.ts:233` | POST | `/api/v1/rooms/{}/runs/{}/stop` | 존재 |  |
| `src/api/real/agent-calls.ts:237` | GET | `/api/v1/voices` | 존재 |  |
| `src/api/real/agent-calls.ts:241` | GET | `/api/v1/agents/{}/traits` | 존재 |  |
| `src/api/real/agent-calls.ts:245` | POST | `/api/v1/agents/{}/traits/refresh` | 존재 |  |
| `src/api/real/agent-calls.ts:249` | DELETE | `/api/v1/agents/{}/traits/{}` | 존재 |  |
| `src/api/real/agent-calls.ts:255` | GET | `/api/v1/agents/{}/photos` | 존재 |  |
| `src/api/real/agent-calls.ts:260` | POST | `/api/v1/agents/{}/photos` | 존재 |  |
| `src/api/real/agent-calls.ts:271` | POST | `/api/v1/agents/{}/photos/{}/select` | 존재 |  |
| `src/api/real/agent-calls.ts:275` | DELETE | `/api/v1/agents/{}/photos/{}` | 존재 |  |
| `src/api/real/agent-calls.ts:283` | POST | `/api/v1/agents/{}/avatar/clear` | 존재 |  |
| `src/api/real/archive-calls.ts:41` | GET | `/api/v1/archive/files` | 존재 |  |
| `src/api/real/archive-calls.ts:45` | DELETE | `/api/v1/archive/files/{}` | 존재 |  |
| `src/api/real/archive-calls.ts:50` | GET | `/api/v1/archive/create-options` | 존재 |  |
| `src/api/real/archive-calls.ts:54` | GET | `/api/v1/pages/{}` | 존재 |  |
| `src/api/real/archive-calls.ts:59` | GET | `/api/v1/pages/{}/download` | 존재 |  |
| `src/api/real/archive-calls.ts:68` | POST | `/api/v1/media/uploads` | 존재 | 사용 |
| `src/api/real/archive-calls.ts:78` | DELETE | `/api/v1/media/{}` | 존재 |  |
| `src/api/real/archive-calls.ts:83` | GET | `/api/v1/rooms/{}/media` | 존재 |  |
| `src/api/real/archive-calls.ts:90` | GET | `/api/v1/rooms/{}/{}` | 존재(경로 합침) |  |
| `src/api/real/billing-calls.ts:14` | GET | `/api/v1/me/usage/ledger` | 존재 |  |
| `src/api/real/billing-calls.ts:18` | GET | `/api/v1/plans` | 존재 |  |
| `src/api/real/billing-calls.ts:24` | POST | `/api/v1/billing/purchases` | 존재 |  |
| `src/api/real/billing-calls.ts:31` | POST | `/api/v1/billing/purchases/{}/confirm` | 존재 |  |
| `src/api/real/billing-calls.ts:35` | POST | `/api/v1/billing/restore` | 존재 |  |
| `src/api/real/billing-calls.ts:40` | GET | `/api/v1/credits/purchases` | 존재 |  |
| `src/api/real/billing-calls.ts:46` | GET | `/api/v1/billing/purchases` | 존재 |  |
| `src/api/real/billing-calls.ts:51` | GET | `/api/v1/billing/purchases/{}` | 존재 |  |
| `src/api/real/billing-calls.ts:56` | POST | `/api/v1/credits/purchases` | 존재 |  |
| `src/api/real/billing-calls.ts:64` | POST | `/api/v1/credits/toss/confirm` | 존재 |  |
| `src/api/real/card-calls.ts:51` | POST | `/api/v1/chat/requests/{}/answer` | 존재 | 사용 |
| `src/api/real/card-calls.ts:76` | POST | `/api/v1/chat/requests/{}/step` | 존재 |  |
| `src/api/real/card-calls.ts:90` | POST | `/api/v1/chat/requests/{}/security-code` | 존재 |  |
| `src/api/real/card-calls.ts:104` | GET | `/api/v1/chat/requests` | 존재 |  |
| `src/api/real/card-calls.ts:111` | GET | `/api/v1/chat/requests/{}` | 존재 | 사용 |
| `src/api/real/card-calls.ts:116` | GET | `/api/v1/rooms/{}/state` | 존재 |  |
| `src/api/real/connection-calls.ts:57` | POST | `/api/v1/connections/begin` | 존재 |  |
| `src/api/real/connection-calls.ts:62` | DELETE | `/api/v1/connections/attempts/{}` | 존재 |  |
| `src/api/real/connection-calls.ts:66` | GET | `/api/v1/connections/attempts/{}` | 존재 |  |
| `src/api/real/connection-calls.ts:70` | GET | `/api/v1/connections/{}` | 존재 |  |
| `src/api/real/connection-calls.ts:76` | GET | `/api/v1/connections/catalog` | 존재 |  |
| `src/api/real/connection-calls.ts:80` | GET | `/api/v1/connections` | 존재 | 사용 |
| `src/api/real/connection-calls.ts:107` | GET | `/api/v1/connections/attempts/{}` | 존재 |  |
| `src/api/real/connection-calls.ts:115` | GET | `/api/v1/connections` | 존재 | 사용 |
| `src/api/real/connection-calls.ts:143` | GET | `/api/v1/connections/{}/notice` | 존재 |  |
| `src/api/real/connection-calls.ts:147` | PUT | `/api/v1/connections/{}/switch` | 존재 |  |
| `src/api/real/connection-calls.ts:156` | POST | `/api/v1/connections/attempts/{}/viewer-ticket` | 존재 |  |
| `src/api/real/connection-calls.ts:165` | GET | `/api/v1/connections/attempts/{}` | 존재 |  |
| `src/api/real/connection-calls.ts:185` | PATCH | `/api/v1/connections/{}/scope` | 존재 |  |
| `src/api/real/connection-calls.ts:198` | PATCH | `/api/v1/connections/{}` | 존재 |  |
| `src/api/real/connection-calls.ts:205` | DELETE | `/api/v1/connections/{}` | 존재 |  |
| `src/api/real/connection-calls.ts:213` | POST | `/api/v1/connections/disconnect-all` | 존재 |  |
| `src/api/real/connection-calls.ts:221` | POST | `/api/v1/connections/device` | 존재 |  |
| `src/api/real/connection-calls.ts:226` | GET | `/api/v1/connections/{}/agents` | 존재 |  |
| `src/api/real/connection-calls.ts:230` | PUT | `/api/v1/connections/{}/agents` | 존재 |  |
| `src/api/real/connection-calls.ts:237` | POST | `/api/v1/connections/catalog/requests` | 존재 |  |
| `src/api/real/connection-calls.ts:244` | GET | `/api/v1/connections/sharing` | 존재 |  |
| `src/api/real/connection-calls.ts:248` | PUT | `/api/v1/connections/{}/sharing` | 존재 |  |
| `src/api/real/connection-calls.ts:268` | POST | `/api/v1/connections/attempts/{}/wrong-account` | 존재 |  |
| `src/api/real/dictation-calls.ts:28` | POST | `/api/v1/dictation` | 존재 | 사용 |
| `src/api/real/explore-calls.ts:13` | GET | `/api/v1/explore/sections` | 존재 |  |
| `src/api/real/explore-calls.ts:18` | POST | `/api/v1/explore/offers/{}/accept` | 존재 |  |
| `src/api/real/explore-calls.ts:32` | POST | `/api/v1/explore/offers/{}/reject` | 존재 |  |
| `src/api/real/explore-calls.ts:36` | POST | `/api/v1/explore/offers/{}/reject/undo` | 존재 |  |
| `src/api/real/explore-calls.ts:40` | GET | `/api/v1/activity` | 존재 |  |
| `src/api/real/explore-calls.ts:44` | POST | `/api/v1/activity/seen` | 존재 |  |
| `src/api/real/explore-calls.ts:49` | POST | `/api/v1/users/{}/report` | 존재 |  |
| `src/api/real/invite-calls.ts:54` | POST | `/api/v1/rooms/{}/invitations` | 존재 |  |
| `src/api/real/invite-calls.ts:58` | GET | `/api/v1/rooms/{}` | 존재 |  |
| `src/api/real/invite-calls.ts:67` | GET | `/api/v1/rooms/{}/my-invitation` | 존재 |  |
| `src/api/real/invite-calls.ts:72` | GET | `/api/v1/invitations/{}` | 존재 |  |
| `src/api/real/invite-calls.ts:80` | GET | `/api/v1/invitations` | 존재 |  |
| `src/api/real/invite-calls.ts:88` | POST | `/api/v1/invitations/{}/accept` | 존재 |  |
| `src/api/real/invite-calls.ts:92` | POST | `/api/v1/rooms/{}/my-invitation/accept` | 존재 |  |
| `src/api/real/invite-calls.ts:95` | POST | `/api/v1/invitations/{}/decline` | 존재 |  |
| `src/api/real/invite-calls.ts:97` | POST | `/api/v1/rooms/{}/my-invitation/decline` | 존재 |  |
| `src/api/real/invite-calls.ts:105` | DELETE | `/api/v1/invitations/{}` | 존재 |  |
| `src/api/real/memory-calls.ts:47` | GET | `/api/v1/memory/facts` | 존재 |  |
| `src/api/real/memory-calls.ts:48` | GET | `/api/v1/memory/facts` | 존재 |  |
| `src/api/real/memory-calls.ts:74` | GET | `/api/v1/me/memory-settings` | 존재 |  |
| `src/api/real/memory-calls.ts:78` | GET | `/api/v1/memory/episodes/{}` | 존재 |  |
| `src/api/real/memory-calls.ts:111` | GET | `/api/v1/memory/episodes` | 존재 |  |
| `src/api/real/memory-calls.ts:118` | PATCH | `/api/v1/memory/episodes/{}` | 존재 |  |
| `src/api/real/memory-calls.ts:122` | DELETE | `/api/v1/memory/episodes/{}` | 존재 | 사용 |
| `src/api/real/memory-calls.ts:137` | POST | `/api/v1/memory/facts` | 존재 |  |
| `src/api/real/memory-calls.ts:143` | PATCH | `/api/v1/memory/facts/{}` | 존재 |  |
| `src/api/real/memory-calls.ts:147` | DELETE | `/api/v1/memory/facts/{}` | 존재 | 사용 |
| `src/api/real/memory-calls.ts:151` | POST | `/api/v1/memory/facts/seen` | 존재 |  |
| `src/api/real/memory-calls.ts:156` | POST | `/api/v1/memory/{}/restore` | 존재 | 사용 |
| `src/api/real/memory-calls.ts:161` | DELETE | `/api/v1/me/memories` | 존재 |  |
| `src/api/real/memory-calls.ts:170` | GET | `/api/v1/me/memory-settings` | 존재 |  |
| `src/api/real/memory-calls.ts:174` | PATCH | `/api/v1/me/memory-settings` | 존재 |  |
| `src/api/real/memory-calls.ts:192` | GET | `/api/v1/memory/episodes/{}` | 존재 |  |
| `src/api/real/notification-calls.ts:62` | POST | `/api/v1/me/push-tokens` | 존재 |  |
| `src/api/real/notification-calls.ts:81` | DELETE | `/api/v1/me/push-tokens/{}` | 존재 |  |
| `src/api/real/phone-calls.ts:26` | GET | `/api/v1/me` | 존재 | 사용 |
| `src/api/real/phone-calls.ts:34` | POST | `/api/v1/me/phone/request` | 존재 |  |
| `src/api/real/phone-calls.ts:49` | POST | `/api/v1/me/phone/verify` | 존재 |  |
| `src/api/real/real-server.ts:239` | GET | `/api/v1/rooms/{}` | 존재 |  |
| `src/api/real/real-server.ts:365` | GET | `/api/v1/rooms/{}/delta` | 존재 | 사용 |
| `src/api/real/real-server.ts:429` | GET | `/api/v1/me/usage` | 존재 | 사용 |
| `src/api/real/real-server.ts:459` | POST | `/api/v1/me/onboarding/submit` | 존재 |  |
| `src/api/real/real-server.ts:581` | POST | `/api/v1/me/onboarding/region-waitlist` | 존재 |  |
| `src/api/real/real-server.ts:586` | POST | `/api/v1/me/onboarding/invite-waitlist` | 존재 |  |
| `src/api/real/real-server.ts:591` | GET | `/api/v1/me/onboarding` | 존재 |  |
| `src/api/real/real-server.ts:596` | GET | `/api/v1/me/onboarding` | 존재 |  |
| `src/api/real/real-server.ts:603` | POST | `/api/v1/me/onboarding/submit` | 존재 |  |
| `src/api/real/real-server.ts:613` | POST | `/api/v1/me/onboarding/back` | 존재 |  |
| `src/api/real/real-server.ts:622` | GET | `/api/v1/agents` | 존재 |  |
| `src/api/real/real-server.ts:629` | GET | `/api/v1/me/usage` | 존재 | 사용 |
| `src/api/real/real-server.ts:637` | GET | `/api/v1/rooms/{}/history` | 존재 | 사용 |
| `src/api/real/real-server.ts:661` | POST | `/api/v1/rooms/{}/messages` | 존재 | 사용 |
| `src/api/real/real-server.ts:691` | POST | `/api/v1/rooms/{}/reply/stop` | 존재 | 사용 |
| `src/api/real/real-server.ts:697` | GET | `/api/v1/tasks` | 존재 |  |
| `src/api/real/real-server.ts:701` | GET | `/api/v1/tasks/{}` | 존재 | 사용 |
| `src/api/real/real-server.ts:706` | POST | `/api/v1/tasks/{}/start` | 존재 | 사용 |
| `src/api/real/real-server.ts:710` | POST | `/api/v1/tasks/{}/cancel` | 존재 | 사용 |
| `src/api/real/real-server.ts:715` | POST | `/api/v1/tasks/{}/continue` | 존재 |  |
| `src/api/real/room-calls.ts:17` | GET | `/api/v1/rooms/sync` | 존재 |  |
| `src/api/real/room-calls.ts:21` | GET | `/api/v1/rooms/{}` | 존재 |  |
| `src/api/real/room-calls.ts:29` | GET | `/api/v1/rooms` | 존재 |  |
| `src/api/real/room-calls.ts:33` | PUT | `/api/v1/rooms/{}/read` | 존재 | 사용 |
| `src/api/real/room-calls.ts:39` | POST | `/api/v1/rooms/{}/messages/{}/redact` | 존재 |  |
| `src/api/real/room-calls.ts:45` | POST | `/api/v1/rooms/{}/request/accept` | 존재 |  |
| `src/api/real/room-calls.ts:53` | POST | `/api/v1/rooms/{}/request/decline` | 존재 |  |
| `src/api/real/room-calls.ts:58` | PATCH | `/api/v1/rooms/{}` | 존재 |  |
| `src/api/real/room-calls.ts:66` | PATCH | `/api/v1/rooms/{}` | 존재 |  |
| `src/api/real/room-calls.ts:70` | DELETE | `/api/v1/rooms/{}` | 존재 |  |
| `src/api/real/room-calls.ts:75` | POST | `/api/v1/messages/search` | 존재 |  |
| `src/api/real/room-calls.ts:83` | GET | `/api/v1/rooms/{}/history` | 존재 | 사용 |
| `src/api/real/room-calls.ts:96` | GET | `/api/v1/rooms` | 존재 |  |
| `src/api/real/room-calls.ts:104` | POST | `/api/v1/messages/search` | 존재 |  |
| `src/api/real/room-calls.ts:117` | POST | `/api/v1/voice/calls` | 존재 |  |
| `src/api/real/room-calls.ts:133` | GET | `/api/v1/voice/calls/{}` | 존재 |  |
| `src/api/real/room-calls.ts:138` | GET | `/api/v1/voice/calls/active` | 존재 |  |
| `src/api/real/room-calls.ts:148` | PATCH | `/api/v1/voice/calls/{}` | 존재 |  |
| `src/api/real/room-calls.ts:152` | POST | `/api/v1/voice/calls/{}/end` | 존재 |  |
| `src/api/real/schedule-calls.ts:31` | GET | `/api/v1/scheduled-actions` | 존재 |  |
| `src/api/real/schedule-calls.ts:35` | GET | `/api/v1/scheduled-actions/{}` | 존재 |  |
| `src/api/real/schedule-calls.ts:39` | GET | `/api/v1/scheduled-actions/{}/runs/{}` | 존재 |  |
| `src/api/real/schedule-calls.ts:43` | POST | `/api/v1/scheduled-actions/{}/confirm` | 존재 |  |
| `src/api/real/schedule-calls.ts:47` | POST | `/api/v1/scheduled-actions/{}/pause` | 존재 |  |
| `src/api/real/schedule-calls.ts:51` | POST | `/api/v1/scheduled-actions/{}/transfer` | 존재 |  |
| `src/api/real/schedule-calls.ts:55` | POST | `/api/v1/scheduled-actions/{}/run-now` | 존재 |  |
| `src/api/real/schedule-calls.ts:65` | POST | `/api/v1/scheduled-actions/{}/test` | 존재 |  |
| `src/api/real/schedule-calls.ts:69` | DELETE | `/api/v1/scheduled-actions/{}` | 존재 |  |
| `src/api/real/settings-calls.ts:20` | GET | `/api/v1/me` | 존재 | 사용 |
| `src/api/real/settings-calls.ts:27` | PATCH | `/api/v1/me` | 존재 |  |
| `src/api/real/settings-calls.ts:37` | GET | `/api/v1/me/handle-check` | 존재 |  |
| `src/api/real/settings-calls.ts:41` | GET | `/api/v1/me/notification-settings` | 존재 |  |
| `src/api/real/settings-calls.ts:45` | PATCH | `/api/v1/me/notification-settings` | 존재 |  |
| `src/api/real/settings-calls.ts:50` | GET | `/api/v1/me/notifications` | 존재 |  |
| `src/api/real/settings-calls.ts:54` | POST | `/api/v1/me/notifications/{}/read` | 존재 |  |
| `src/api/real/settings-calls.ts:58` | POST | `/api/v1/issue-reports` | 존재 |  |
| `src/api/real/settings-calls.ts:62` | GET | `/api/v1/me/deletion-preview` | 존재 |  |
| `src/api/real/settings-calls.ts:70` | DELETE | `/api/v1/me` | 존재 |  |
| `src/api/real/settings-calls.ts:76` | GET | `/api/v1/me/export` | 존재 |  |
| `src/api/real/settings-calls.ts:87` | GET | `/api/v1/me/deletion-status` | 존재 |  |
| `src/api/real/settings-calls.ts:95` | POST | `/api/v1/me/deletion/cancel` | 존재 |  |
| `src/api/real/sharing-calls.ts:34` | GET | `/api/v1/sharing` | 존재 |  |
| `src/api/real/sharing-calls.ts:39` | PATCH | `/api/v1/sharing` | 존재 |  |
| `src/api/real/sharing-calls.ts:43` | PUT | `/api/v1/sharing/exclusions` | 존재 |  |
| `src/api/real/sharing-calls.ts:48` | GET | `/api/v1/sharing/people/{}` | 존재 |  |
| `src/api/real/sharing-calls.ts:52` | PUT | `/api/v1/sharing/people/{}` | 존재 |  |
| `src/api/real/social-calls.ts:45` | GET | `/api/v1/social/summary` | 존재 |  |
| `src/api/real/social-calls.ts:49` | POST | `/api/v1/social/friend-requests` | 존재 |  |
| `src/api/real/social-calls.ts:53` | POST | `/api/v1/social/friend-requests/{}/accept` | 존재 |  |
| `src/api/real/social-calls.ts:57` | POST | `/api/v1/social/friend-requests/{}/decline` | 존재 |  |
| `src/api/real/social-calls.ts:61` | POST | `/api/v1/social/friend-requests/{}/cancel` | 존재 |  |
| `src/api/real/social-calls.ts:65` | DELETE | `/api/v1/social/friends/{}` | 존재 |  |
| `src/api/real/social-calls.ts:69` | POST | `/api/v1/social/blocks` | 존재 |  |
| `src/api/real/social-calls.ts:73` | DELETE | `/api/v1/social/blocks/{}` | 존재 |  |
| `src/api/real/social-calls.ts:78` | GET | `/api/v1/users/lookup` | 존재 |  |
| `src/api/real/social-calls.ts:87` | POST | `/api/v1/social/contacts/match` | 존재 |  |
| `src/api/real/social-calls.ts:95` | GET | `/api/v1/users/{}/profile` | 존재 |  |
| `src/api/real/social-calls.ts:104` | POST | `/api/v1/social/invites/{}/dismiss` | 존재 |  |
| `src/api/real/social-calls.ts:109` | GET | `/api/v1/me/invites` | 존재 |  |
| `src/api/real/social-calls.ts:117` | POST | `/api/v1/social/message-requests` | 존재 |  |
| `src/api/real/social-calls.ts:131` | POST | `/api/v1/social/chats` | 존재 |  |
| `src/api/real/social-calls.ts:141` | GET | `/api/v1/me/privacy-settings` | 존재 |  |
| `src/api/real/social-calls.ts:145` | PATCH | `/api/v1/me/privacy-settings` | 존재 |  |
| `src/api/real/social-calls.ts:149` | DELETE | `/api/v1/me/contact-matches` | 존재 |  |
| `src/api/real/task-calls.ts:13` | GET | `/api/v1/tasks/{}` | 존재 | 사용 |
| `src/api/real/task-calls.ts:17` | GET | `/api/v1/tasks/{}/logs` | 존재 |  |
| `src/api/real/task-calls.ts:21` | POST | `/api/v1/tasks/{}/call/hangup` | 존재 |  |
| `src/api/real/task-calls.ts:25` | POST | `/api/v1/tasks/{}/call/note` | 존재 |  |
| `src/api/real/task-calls.ts:32` | GET | `/api/v1/calls/{}` | 존재 |  |
| `src/api/real/task-calls.ts:34` | GET | `/api/v1/tasks/{}` | 존재 | 사용 |
| `src/api/real/task-calls.ts:39` | POST | `/api/v1/tasks/{}/routine-draft` | 존재 |  |
| `src/api/real/trust-calls.ts:17` | GET | `/api/v1/secure/log` | 존재 |  |
| `src/api/real/trust-calls.ts:21` | GET | `/api/v1/me/approval-rules` | 존재 |  |
| `src/api/real/trust-calls.ts:25` | DELETE | `/api/v1/me/approval-rules/{}` | 존재 |  |
| `src/api/real/trust-calls.ts:30` | PATCH | `/api/v1/me/approval-rules` | 존재 |  |

경로의 `{}` 는 id 자리. 쿼리스트링은 뺐다. 이 표는 `git grep -n "request(METHOD" origin/main -- src/api/real` 결과를 스크립트로 정리한 것이다.
