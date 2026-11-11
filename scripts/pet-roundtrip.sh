#!/bin/bash
# Real round trip between tools/mock-server (mock nacho-server + stand-in Keycloak) and nacho-pet-cli (the same
# PetSession the app uses): PKCE login → /api/v1/me, /ws/chat streaming and stop, capture → pet (picture upload),
# shelf → pet (file upload), refused file type, window arrangement and gadget switches through /ws/connector,
# Computer Use refused, server features (config/usage, history, delta recovery, tool progress, task + card,
# memory forget/undo/feedback, server dictation, read mark), token refresh, logout. Output: build/pet-roundtrip/*.log, server*.jsonl, summary.txt.
# Exit 0 only if every check passes. Needs Swift and Node >= 18 (Linux: run inside the swift container, see README).
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=build/pet-roundtrip
rm -rf "$OUT"; mkdir -p "$OUT"
PORT="${PET_PORT:-8791}"
PORT2="${PET_PORT2:-8792}"
S1="http://127.0.0.1:$PORT"
S2="http://127.0.0.1:$PORT2"
swift build --product nacho-pet-cli 2>&1 | tail -2
CLI="$(swift build --show-bin-path)/nacho-pet-cli"
node tools/mock-server/server.mjs --port "$PORT" --log "$OUT/server.jsonl" --delay-ms 15 &
SRV1=$!
node tools/mock-server/server.mjs --port "$PORT2" --log "$OUT/server-refresh.jsonl" --delay-ms 15 --access-ttl 62 &
SRV2=$!
trap 'kill $SRV1 $SRV2 2>/dev/null' EXIT
for _ in $(seq 1 50); do curl -s "$S1/health" >/dev/null 2>&1 && curl -s "$S2/health" >/dev/null 2>&1 && break; sleep 0.2; done
STORE="$OUT/store"
fail=0
check() { # name, 0 = pass
  if [ "$2" -eq 0 ]; then echo "PASS $1" | tee -a "$OUT/summary.txt"; else echo "FAIL $1" | tee -a "$OUT/summary.txt"; fail=1; fi
}
cnt() { grep -c -- "$1" "$2" 2>/dev/null || true; }
run() { local name="$1"; shift; "$CLI" "$@" > "$OUT/$name.log" 2>&1; echo $?; }

rc=$(run login login --server "$S1" --store "$STORE")
check "login: PKCE S256 + state, token stored, GET /api/v1/me 200" $(( rc != 0 || $(cnt 'GET /api/v1/me -> 200' "$OUT/login.log") != 1 || $(cnt '"pkce":"S256 verified"' "$OUT/server.jsonl") != 1 ))
perm_dir=$(stat -c %a "$STORE"); perm_files=$(find "$STORE" -type f -printf '%m\n' | sort -u | tr '\n' ' ')
[ "$perm_dir" = 700 ] && [ "$perm_files" = "600 " ]; check "secret store is 0700 with 0600 files ($perm_dir / $perm_files)" $?

rc=$(run chat chat --server "$S1" --store "$STORE" "안녕 나초")
check "chat: Bearer token on /ws/chat, streamed deltas, done" $(( rc != 0 || $(cnt ' delta ' "$OUT/chat.log") < 2 || $(cnt '\] done text=' "$OUT/chat.log") != 1 ))

rc=$(run stop stop --server "$S1" --store "$STORE" "/long")
check "stop: partial text kept, turn stopped" $(( rc != 0 || $(cnt 'stopped partial=' "$OUT/stop.log") != 1 ))

rc=$(run ask-image ask-image --server "$S1" --store "$STORE" Resources/Nacho/idle.png "이 그림 뭐야?")
check "capture -> pet: picture uploaded, attachment id in the message, server read 440x440" $(( rc != 0 || $(cnt 'uploading 1 file' "$OUT/ask-image.log") < 1 || $(cnt '440×440' "$OUT/ask-image.log") < 1 || $(cnt '"attachments":\[{"attachment_id"' "$OUT/server.jsonl") < 1 ))

printf '# 회의 메모\n- 금요일 배포\n' > "$OUT/notes.md"
rc=$(run send-file send-file --server "$S1" --store "$STORE" "$OUT/notes.md" "요약해 줘")
check "shelf -> pet: text file uploaded and read" $(( rc != 0 || $(cnt '글: \\"# 회의 메모' "$OUT/send-file.log") < 1 ))

printf 'echo hi\n' > "$OUT/run.sh"
rc=$(run send-refused send-file --server "$S1" --store "$STORE" "$OUT/run.sh" "실행해 줘")
check "shelf -> pet: unsupported file type refused before upload" $(( rc == 0 || $(cnt '이 파일 형식은 보낼 수 없어요' "$OUT/send-refused.log") != 1 ))

rc=$(run cmd-window command --server "$S1" --store "$STORE" "지금 창 왼쪽으로 붙여 줘")
check "chat -> window arrangement: connector binding, hello, request/response, reply" $(( rc != 0 || $(cnt 'mac: arrange window left' "$OUT/cmd-window.log") != 1 || $(cnt 'combo_arrange_window 결과' "$OUT/cmd-window.log") < 1 || $(cnt '"event":"binding_issued","kind":"nacho_combo"' "$OUT/server.jsonl") != 1 ))

rc=$(run cmd-gadget command --server "$S1" --store "$STORE" "킵 어웨이크 켜 줘")
check "chat -> gadget on (binding token reused, no second binding)" $(( rc != 0 || $(cnt 'mac: gadget keepAwake -> on' "$OUT/cmd-gadget.log") != 1 || $(cnt '"event":"binding_issued"' "$OUT/server.jsonl") != 1 ))

rc=$(run cmd-off command --server "$S1" --store "$STORE" "포커스 딤 꺼 줘")
check "chat -> gadget off" $(( rc != 0 || $(cnt 'mac: gadget focusDim -> off' "$OUT/cmd-off.log") != 1 ))

rc=$(run cmd-list command --server "$S1" --store "$STORE" "가젯 목록 보여줘")
check "chat -> gadget list" $(( rc != 0 || $(cnt 'mac: list gadgets' "$OUT/cmd-list.log") != 1 ))

rc=$(run cmd-cu command --server "$S1" --store "$STORE" "컴퓨터 사용 켜 줘")
check "chat -> Computer Use refused by the app (never reaches the Mac)" $(( rc != 0 || $(cnt 'mac: gadget computerUse' "$OUT/cmd-cu.log") != 0 || $(cnt 'not allowed: Computer Use' "$OUT/server.jsonl") < 1 ))

# --- nacho-server LLM features (history, recovery, task path, cards, memory, dictation, usage) ---
rc=$(run usage usage --server "$S1" --store "$STORE")
check "client config (no token) + GET /api/v1/me/usage shown" $(( rc != 0 || $(cnt 'config dictation=true max_sec=60' "$OUT/usage.log") != 1 || $(cnt 'usage 크레딧 180/200 · 가벼운 대화 3/50' "$OUT/usage.log") != 1 ))

rc=$(run history history --server "$S1" --store "$STORE")
check "history: earlier messages of the room (view=app, seeded note shown, X-Has-More)" $(( rc != 0 || $(cnt "history seq=1 role=user type=text text=\"어제 파스타집 알아봐 줬지?\"" "$OUT/history.log") != 1 || $(cnt 'type=system_note' "$OUT/history.log") != 1 || $(cnt '"event":"history","before":null' "$OUT/server.jsonl") < 1 ))

rc=$(run recover recover --server "$S1" --store "$STORE")
check "dropped socket: turn interrupted, reconnect, GET delta fills in the answer the server finished" $(( rc != 0 || $(cnt 'interrupted (socket dropped)' "$OUT/recover.log") != 1 || $(cnt 'recovered from delta text="모의 나초예요' "$OUT/recover.log") != 1 || $(cnt '"event":"delta"' "$OUT/server.jsonl") < 1 ))

rc=$(run search search --server "$S1" --store "$STORE")
check "tool progress: tool_call_started/finished + interim line shown as progress, not as the answer" $(( rc != 0 || $(cnt 'tools search_web:ok' "$OUT/search.log") != 1 || $(cnt 'progress \["웹에서 찾아보고 있어요"\]' "$OUT/search.log") != 1 ))

rc=$(run task task --server "$S1" --store "$STORE")
check "task path: done{task_id}, hub task_update/interim, choice card answered (expected_version), task_result joins the turn" $(( rc != 0 || $(cnt 'card choice "어느 시간이 좋아요?"' "$OUT/task.log") != 1 || $(cnt 'task done answer="저녁 7시으로 예약했어요."' "$OUT/task.log") != 1 || $(cnt '"event":"answered","id"' "$OUT/server.jsonl") != 1 ))

rc=$(run remember remember --server "$S1" --store "$STORE")
check "memory: line shown, forget (DELETE) + undo within 10 s (restore), feedback with used memory ids" $(( rc != 0 || $(cnt 'memory 기억했어요: 고양이를 키워요 used=1' "$OUT/remember.log") != 1 || $(cnt 'restored after' "$OUT/remember.log") != 1 || $(cnt 'feedback ok' "$OUT/remember.log") != 1 || $(cnt '"event":"feedback","kind":"correction","memory_ids":\["' "$OUT/server.jsonl") != 1 || $(cnt '"idempotency_key":"present"' "$OUT/server.jsonl") != 1 ))

printf 'NACHO-STT:내일 일정 알려줘' > "$OUT/voice.m4a"
rc=$(run dictate dictate --server "$S1" --store "$STORE" "$OUT/voice.m4a" audio/mp4)
check "dictation: multipart to POST /api/v1/dictation, text back (not sent by itself)" $(( rc != 0 || $(cnt 'dictation text="내일 일정 알려줘"' "$OUT/dictate.log") != 1 || $(cnt '"event":"transcribed","type":"audio/mp4"' "$OUT/server.jsonl") != 1 ))
rc=$(run dictate-refused dictate --server "$S1" --store "$STORE" "$OUT/voice.m4a" video/mp4)
check "dictation: unsupported audio type refused before upload" $(( rc != 2 || $(cnt '"event":"transcribed"' "$OUT/server.jsonl") != 1 ))
check "read mark sent as WS read frame after answers" $(( $(cnt '"event":"read","seq":' "$OUT/server.jsonl") < 1 ))

rc=$(run refresh-login login --server "$S2" --store "$OUT/store2")
sleep 3
rc2=$(run refresh-chat chat --server "$S2" --store "$OUT/store2" "토큰 갱신 시험")
check "token refresh: stale access token refreshed before /ws/chat" $(( rc != 0 || rc2 != 0 || $(cnt '"grant":"refresh_token"' "$OUT/server-refresh.jsonl") != 1 ))

rc=$(run logout logout --server "$S1" --store "$STORE")
rc2=$(run after-logout chat --server "$S1" --store "$STORE" "아직 있니?")
check "logout: Keycloak session ended, secrets deleted, chat refused" $(( rc != 0 || rc2 == 0 || $(cnt '"known_session":true' "$OUT/server.jsonl") != 1 || $(find "$STORE" -type f | wc -l) != 0 ))

leaks=$(cat "$OUT"/*.log | grep -c -E 'mock-at-|mock-rt-|nct_[0-9a-f]{8}' || true)
leaks2=$(cat "$OUT"/*.jsonl | grep -c -E 'mock-at-|mock-rt-|nct_[0-9a-f]{8}|mock-code-' || true)
check "no token, code or binding secret in any log ($leaks / $leaks2)" $(( leaks + leaks2 ))

echo "---- summary ----"; cat "$OUT/summary.txt"
exit $fail
