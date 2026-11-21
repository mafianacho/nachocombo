#!/usr/bin/env bash
# Privacy check of a finished video: frames every 2 s, contact sheets, metadata dump, forbidden-string scans, checklist.
#   privacy/run.sh <video.mp4> [<gif>] [--out <dir>] [--interval 2]
# <dir> must be inside the video's folder (it is the one folder mounted into the ffmpeg container); default <video dir>/privacy.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VIDEO_DIR_ROOT="$(cd "$HERE/.." && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
source "$VIDEO_DIR_ROOT/tools/ffmpeg.sh"

VIDEO="" GIF="" OUTSUB="privacy" INTERVAL=2
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUTSUB="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    -h|--help) sed -n '2,5p' "$0"; exit 0 ;;
    *) if [ -z "$VIDEO" ]; then VIDEO="$1"; else GIF="$1"; fi; shift ;;
  esac
done
[ -f "$VIDEO" ] || { echo "run.sh: video not found: $VIDEO" >&2; exit 2; }
VIDEO="$(realpath "$VIDEO")"; DIR="$(dirname "$VIDEO")"; BASE="$(basename "$VIDEO")"
case "$OUTSUB" in /*) OUTSUB="$(realpath --relative-to="$DIR" "$OUTSUB")" ;; esac
case "$OUTSUB" in ../*|..) echo "run.sh: --out must be inside $DIR" >&2; exit 2 ;; esac
OUT="$DIR/$OUTSUB"
rm -rf "$OUT"; mkdir -p "$OUT/frames"

DURATION=$(fp "$DIR" -v error -show_entries format=duration -of csv=p=0 "$BASE" | awk '{printf "%.2f", $1}')
# Exactly every INTERVAL seconds (frame numbers, not the fps filter: that one takes the last frame of each interval, a second late).
FPS=$(fp "$DIR" -v error -select_streams v:0 -show_entries stream=avg_frame_rate -of csv=p=0 "$BASE" | awk -F/ '{printf "%.4f", $1/$2}')
STEP=$(awk -v f="$FPS" -v i="$INTERVAL" 'BEGIN{printf "%d", f*i+0.5}')
SELECT="select=not(mod(n\\,$STEP))"
echo "== frames every ${INTERVAL}s of $BASE (${DURATION}s, ${FPS} fps, every ${STEP}th frame)"
ff "$DIR" -y -loglevel error -i "$BASE" -vf "$SELECT" -fps_mode vfr "$OUTSUB/frames/f_%04d.png"
FRAMES=$(ls "$OUT/frames" | wc -l)
NEEDED=$(awk -v d="$DURATION" -v i="$INTERVAL" 'BEGIN{n=int(d/i); if (n*i<d) n++; print n}')
echo "   $FRAMES frames (needed at least $NEEDED)"
[ "$FRAMES" -ge "$NEEDED" ] || { echo "run.sh: too few frames" >&2; exit 1; }

echo "== contact sheets (4 x 5 frames per sheet, time stamp on each frame)"
ff "$DIR" --font-dir "$REPO_ROOT/Resources/Fonts" -y -loglevel error -i "$BASE" \
  -vf "$SELECT,scale=480:270,drawtext=fontfile=/fonts/IBMPlexMono-Medium.ttf:text='%{pts\:hms}':x=8:y=8:fontsize=22:fontcolor=white:box=1:boxcolor=black@0.7:boxborderw=4,tile=4x5:padding=4:margin=4:color=black" \
  -fps_mode vfr "$OUTSUB/contact-sheet-%02d.png"
ls "$OUT"/contact-sheet-*.png | sed "s|$DIR/||"

echo "== metadata dump"
fp "$DIR" -v error -show_format -show_streams -show_chapters -show_programs -of json "$BASE" > "$OUT/ffprobe.json"
node -e '
const p = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const lines = [];
const dump = (where, tags) => Object.entries(tags || {}).forEach(([k, v]) => lines.push(`${where}: ${k} = ${v}`));
dump("format", p.format.tags); p.streams.forEach((s, i) => dump(`stream ${i} (${s.codec_type})`, s.tags));
(p.chapters || []).forEach((c, i) => dump(`chapter ${i}`, c.tags));
const structural = /^format: (major_brand|minor_version|compatible_brands) =|^stream \d+ \(\w+\): (language = und|vendor_id = |handler_name = (VideoHandler|SoundHandler)?$)/;
const risky = lines.filter((l) => !structural.test(l));
console.log(lines.join("\n") || "(no tags)");
console.log(`\nformat: ${p.format.format_name}, streams: ${p.streams.map((s) => s.codec_type + "/" + s.codec_name).join(", ")}, chapters: ${(p.chapters || []).length}`);
console.log(risky.length ? "RISKY TAGS:\n" + risky.join("\n") : "no tags beyond container defaults (brand, language und, generic handler name)");
process.exit(risky.length ? 1 : 0);
' "$OUT/ffprobe.json" | tee "$OUT/metadata.txt" && META="clean: no title, encoder, comment, path or user name" || META="TAGS FOUND, see metadata.txt"

echo "== forbidden strings in the media bytes"
MEDIA=("$VIDEO"); [ -n "$GIF" ] && MEDIA+=("$(realpath "$GIF")")
if node "$HERE/scan-forbidden.mjs" "${MEDIA[@]}" | tee "$OUT/scan-media.txt"; then SM="0 hits"; else SM="HITS, see scan-media.txt"; fi
echo "== forbidden strings in the source material"
SRC=("$VIDEO_DIR_ROOT/tools" "$VIDEO_DIR_ROOT/timeline.json" "$VIDEO_DIR_ROOT/captions.en.srt" "$VIDEO_DIR_ROOT/capture-manifest.json" "$VIDEO_DIR_ROOT/build.sh" "$VIDEO_DIR_ROOT/capture.sh" "$HERE")
[ -n "${CAPTURES_DIR:-}" ] && SRC+=("$CAPTURES_DIR")
if node "$HERE/scan-forbidden.mjs" "${SRC[@]}" | tee "$OUT/scan-source.txt"; then SS="0 hits"; else SS="HITS, see scan-source.txt"; fi

sed -e "s|{{video}}|$BASE|g" -e "s|{{date}}|$(date +%F)|g" -e "s|{{interval}}|$INTERVAL|g" -e "s|{{frames}}|$FRAMES|g" \
    -e "s|{{duration}}|$DURATION|g" -e "s|{{needed}}|$NEEDED|g" -e "s|{{frames_dir}}|$OUTSUB/frames|g" \
    -e "s|{{metadata_result}}|$META|g" -e "s|{{scan_media_result}}|$SM|g" -e "s|{{scan_source_result}}|$SS|g" \
    "$HERE/CHECKLIST.template.md" > "$OUT/CHECKLIST.md"
echo
echo "privacy: $FRAMES frames, metadata: $META, media scan: $SM, source scan: $SS"
echo "next: look at $OUT/contact-sheet-*.png and the frames, then fill in the 'By eye' rows of $OUT/CHECKLIST.md"
