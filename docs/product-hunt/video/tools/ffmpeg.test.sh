#!/usr/bin/env bash
# Offline test of the container name and label that tools/ffmpeg.sh and tools/check-text-stability.mjs add to `docker run`
# when MULTICA_TASK_ID is set. A fake `docker` first on PATH records its arguments; no Docker daemon is contacted.
#   tools/ffmpeg.test.sh        prints one PASS/FAIL line per check, exit code 1 if any check fails
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/work" "$TMP/fonts" "$TMP/frames"
LOG="$TMP/docker.log"

# The fake docker logs one line per call (arguments shell-quoted). For the frame checker it also creates the empty raw file
# that the real ffmpeg would write into the folder mounted at /o.
cat >"$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%q ' "$@" >>"$DOCKER_TEST_LOG"; echo >>"$DOCKER_TEST_LOG"
for arg in "$@"; do case "$arg" in *:/o) : >"${arg%:/o}/chunk.raw" ;; esac; done
exit 0
EOF
printf '#!/usr/bin/env bash\necho "local $*" >>"$DOCKER_TEST_LOG.local"\n' >"$TMP/bin/ffmpeg"
chmod +x "$TMP/bin/docker" "$TMP/bin/ffmpeg"

export DOCKER_TEST_LOG="$LOG" FFMPEG_IMAGE="test/ffmpeg:1" PATH="$TMP/bin:$PATH"
unset MULTICA_TASK_ID FFMPEG_MODE FFMPEG_DOCKER_USER _FFRUN_SEQ

fails=0
check() { # check <description> <condition: 0 = ok>
  if [ "$2" -eq 0 ]; then echo "PASS  $1"; else echo "FAIL  $1"; fails=$((fails + 1)); fi
}
calls() { wc -l <"$LOG" 2>/dev/null | tr -d ' ' || echo 0; }
reset() { : >"$LOG"; rm -f "$LOG.local"; }
name_of() { sed -n 's/.* --name \([^ ]*\) .*/\1/p' <<<"$1"; }
# runsh <env assignments...> -- <bash snippet>: runs the snippet in a fresh bash that has sourced ffmpeg.sh
runsh() {
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  env "${envs[@]}" bash -c 'source "$1"; shift; eval "$1"' _ "$HERE/ffmpeg.sh" "$1"
}
DIR="$TMP/work"

echo "== ffmpeg.sh, MULTICA_TASK_ID unset: the command is exactly the old one"
reset
runsh X=1 -- "ff '$DIR' -i in.png out.mp4"
want="$(printf '%q ' run --rm -v "$DIR":/w -w /w --entrypoint ffmpeg "$FFMPEG_IMAGE" -hide_banner -i in.png out.mp4)"
[ "$(cat "$LOG")" = "$want" ]; check "ff without id: docker run --rm -v dir:/w -w /w --entrypoint ffmpeg image -hide_banner ... (no --label, no --name)" $?
reset
runsh X=1 MULTICA_TASK_ID= -- "fp '$DIR' -version"
want="$(printf '%q ' run --rm -v "$DIR":/w -w /w --entrypoint ffprobe "$FFMPEG_IMAGE" -hide_banner -version)"
[ "$(cat "$LOG")" = "$want" ]; check "fp with an empty id: unchanged" $?
reset
runsh FFMPEG_DOCKER_USER=1000:1000 -- "ff '$DIR' --font-dir '$TMP/fonts' -version"
want="$(printf '%q ' run --rm -v "$TMP/fonts":/fonts:ro -u 1000:1000 -v "$DIR":/w -w /w --entrypoint ffmpeg "$FFMPEG_IMAGE" -hide_banner -version)"
[ "$(cat "$LOG")" = "$want" ]; check "--font-dir and FFMPEG_DOCKER_USER without id: unchanged" $?

echo "== ffmpeg.sh, MULTICA_TASK_ID=task-123"
reset
runsh MULTICA_TASK_ID=task-123 -- "ff '$DIR' -i in.png out.mp4; fp '$DIR' -version; ff '$DIR' -version"
[ "$(calls)" = 3 ]; check "three calls made three docker runs" $?
n1="$(name_of "$(sed -n 1p "$LOG")")"; n2="$(name_of "$(sed -n 2p "$LOG")")"; n3="$(name_of "$(sed -n 3p "$LOG")")"
grep -qE '^nc-video-task-123-[0-9]+-[0-9]+$' <<<"$n1"; check "name is nc-video-<id>-<n>  ($n1)" $?
[ -n "$n1" ] && [ "$n1" != "$n2" ] && [ "$n2" != "$n3" ] && [ "$n1" != "$n3" ]; check "the name differs on every call  ($n1, $n2, $n3)" $?
[ "$(grep -c -- '--label mafianacho.owner=task-123 ' "$LOG")" = 3 ]; check "every call has --label mafianacho.owner=task-123" $?
first="$(sed -n 1p "$LOG")"
stripped="$(sed -E 's/--label [^ ]+ --name [^ ]+ //' <<<"$first")"
want="$(printf '%q ' run --rm -v "$DIR":/w -w /w --entrypoint ffmpeg "$FFMPEG_IMAGE" -hide_banner -i in.png out.mp4)"
[ "$stripped" = "$want" ]; check "without the label and name the arguments are the old ones (--rm, -v, -w, --entrypoint, image)" $?
grep -q -- '--rm ' <<<"$first"; check "--rm is kept" $?

reset
runsh MULTICA_TASK_ID=task-123 -- 'a=$(ff '"'$DIR'"' -version); b=$(fp '"'$DIR'"' -version); ff '"'$DIR'"' -version & ff '"'$DIR'"' -version & wait'
names="$(while read -r l; do name_of "$l"; done <"$LOG" | sort)"
[ "$(wc -l <<<"$names" | tr -d ' ')" = 4 ] && [ "$(sort -u <<<"$names" | wc -l | tr -d ' ')" = 4 ]; check "calls from subshells and background jobs also get different names" $?

reset
runsh MULTICA_TASK_ID=task-123 -- "ff '$DIR' -version"
runsh MULTICA_TASK_ID=task-123 -- "ff '$DIR' -version"
[ "$(while read -r l; do name_of "$l"; done <"$LOG" | sort -u | wc -l | tr -d ' ')" = 2 ]; check "two separate runs with the same id do not reuse a name" $?

reset
runsh 'MULTICA_TASK_ID=a/b c' -- "ff '$DIR' -version"
grep -q -- '--label mafianacho.owner=a/b\\ c ' "$LOG" && grep -qE -- ' --name nc-video-a_b_c-[0-9]+-1 ' "$LOG"; check "an id with odd characters: label keeps the value, name uses _" $?

echo "== ffmpeg.sh, FFMPEG_MODE=local: docker is not used"
reset
runsh MULTICA_TASK_ID=task-123 FFMPEG_MODE=local -- "ff '$DIR' -version"
[ ! -s "$LOG" ] && [ -s "$LOG.local" ]; check "local mode runs ffmpeg from PATH and never calls docker" $?

echo "== check-text-stability.mjs (frame decoder), fake docker, empty frame folder"
if command -v node >/dev/null 2>&1; then
  reset
  MULTICA_TASK_ID=task-123 node "$HERE/check-text-stability.mjs" "$TMP/frames" --tmp "$TMP/frames-tmp" >/dev/null 2>&1
  c="$(calls)"
  [ "$c" -ge 2 ]; check "the checker started $c containers" $?
  [ "$(grep -c -- '--label mafianacho.owner=task-123 ' "$LOG")" = "$c" ]; check "every container has the owner label" $?
  [ "$(while read -r l; do name_of "$l"; done <"$LOG" | grep -cE '^nc-video-task-123-[0-9]+-[0-9]+$')" = "$c" ] && \
  [ "$(while read -r l; do name_of "$l"; done <"$LOG" | sort -u | wc -l | tr -d ' ')" = "$c" ]; check "every container has its own nc-video-<id>-<n> name" $?
  first="$(sed -n 1p "$LOG")"
  grep -q -- '--rm ' <<<"$first" && grep -q -- ':/w:ro ' <<<"$first" && grep -q -- ':/o ' <<<"$first" && grep -q -- '--entrypoint ffmpeg test/ffmpeg:1 ' <<<"$first"; check "--rm, the two -v mounts, --entrypoint and the image are kept" $?
  reset
  env -u MULTICA_TASK_ID node "$HERE/check-text-stability.mjs" "$TMP/frames" --tmp "$TMP/frames-tmp" >/dev/null 2>&1
  [ "$(calls)" -ge 2 ] && ! grep -qE -- '--label|--name' "$LOG"; check "without id: no --label and no --name" $?
else
  echo "FAIL  node is needed for the frame checker part"; fails=$((fails + 1))
fi

echo
if [ "$fails" -eq 0 ]; then echo "ffmpeg.test.sh: all checks passed"; else echo "ffmpeg.test.sh: $fails check(s) FAILED"; exit 1; fi
