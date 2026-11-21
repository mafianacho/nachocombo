#!/usr/bin/env bash
# One command from captures to deliverables:  captures folder (PNG + capture-manifest.json) -> MP4 (H.264) + gallery GIF.
#
#   PLAYWRIGHT_CORE=<playwright-core dir> ./build.sh --captures <dir> --out <dir> [options]
#
#   --captures <dir>   folder with the PNGs named in capture-manifest.json (see make-standin for a dry run)
#   --out <dir>        output folder (created); keep it outside the repository
#   --name <base>      file base name (default: nachocombo-intro)
#   --draft            burn the DRAFT watermark into every frame (stand-in runs; the result is not a deliverable)
#   --audio <file>     optional voice-over (WAV/MP3/M4A) muxed as AAC; default is a silent, subtitle-only video
#   --workers <n>      parallel browser pages for rendering (default 1: one page draws every frame in order; about 4 minutes for 75 s.
#                      More pages are faster, but frame i is then drawn by page i mod n: tools/check-text-stability.mjs must PASS on the result)
#   --preview          also make <name>-preview.mp4: a copy under 10 MB (2-pass ABR, about 930 kbit/s, same size/fps/frames) for chat previews;
#                      PREVIEW_KBPS=<n> overrides the bit rate. It is a convenience copy, not the deliverable.
#   --reuse-frames     skip rendering and use the frames a previous run of this script left in <out>/work/frames (with --keep-frames; same inputs)
#                      so a long build can be split over two commands
#   --keep-frames      keep <out>/work/frames afterwards (about 1 GB for 75 s)
#   --standin          build the captures folder from the repo's docs/images first (dry run, implies --draft)
#   GIF_MAX_BYTES=<n>  GIF size target (default: the value in timeline.json)
#   GIF_PRESETS="w fps colors;w fps colors;..."   GIF size ladder, first one that fits is used (default: 960 12 192; 800 12 160; 800 10 128; ...)
#
# Needs: bash, Node 18+, a playwright-core directory with a Chromium in ~/.cache/ms-playwright (nothing is installed),
# and Docker for the ffmpeg image (tools/ffmpeg.sh). Typical time for 75 s with one page: about 6-8 minutes.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/tools/ffmpeg.sh"

CAPTURES="" OUT="" NAME="nachocombo-intro" DRAFT="" AUDIO="" WORKERS=1 KEEP=0 STANDIN=0 PREVIEW=0 REUSE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --captures) CAPTURES="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --draft) DRAFT="--draft"; shift ;;
    --audio) AUDIO="$2"; shift 2 ;;
    --workers) WORKERS="$2"; shift 2 ;;
    --preview) PREVIEW=1; shift ;;
    --reuse-frames) REUSE=1; shift ;;
    --keep-frames) KEEP=1; shift ;;
    --standin) STANDIN=1; DRAFT="--draft"; shift ;;
    -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
    *) echo "build.sh: unknown option $1" >&2; exit 2 ;;
  esac
done
[ -n "$OUT" ] || { echo "build.sh: --out is required" >&2; exit 2; }
mkdir -p "$OUT/work"; OUT="$(cd "$OUT" && pwd)"
if [ "$STANDIN" = 1 ]; then
  CAPTURES="${CAPTURES:-$OUT/work/captures-standin}"
  node "$HERE/tools/make-standin.mjs" "$CAPTURES"
fi
[ -n "$CAPTURES" ] || { echo "build.sh: --captures is required (or --standin)" >&2; exit 2; }
CAPTURES="$(cd "$CAPTURES" && pwd)"

command -v node >/dev/null || { echo "build.sh: Node 18+ is required" >&2; exit 1; }
if [ "${FFMPEG_MODE:-docker}" != "local" ]; then
  docker image inspect "$FFMPEG_IMAGE" >/dev/null 2>&1 || { echo "build.sh: pulling $FFMPEG_IMAGE"; docker pull "$FFMPEG_IMAGE" >/dev/null; }
fi
FPS=$(node -e "console.log(require('$HERE/timeline.json').fps)")
DURATION=$(node -e "console.log(require('$HERE/timeline.json').duration)")
GIF_MAX="${GIF_MAX_BYTES:-$(node -e "console.log(require('$HERE/timeline.json').gif.maxBytes)")}"
START=$(date +%s)
step() { echo; echo "== $*"; }

step "1/6 caption check"
node "$HERE/tools/check-captions.mjs" | tail -n 6

step "2/6 render frames (${DURATION}s at ${FPS} fps)"
if [ "$REUSE" = 1 ]; then
  N=$(ls "$OUT/work/frames" 2>/dev/null | grep -c '^[0-9]\{5\}\.png$' || true)
  [ "$N" -eq $((FPS * DURATION)) ] || { echo "build.sh: --reuse-frames needs $((FPS * DURATION)) frames in $OUT/work/frames, found $N" >&2; exit 1; }
  echo "   reusing $N frames from an earlier run"
else
  node "$HERE/tools/render.mjs" --captures "$CAPTURES" --out "$OUT/work/frames" --workers "$WORKERS" $DRAFT
fi

step "2b/6 text stability of the rendered PNG frames (exact: 0 px, consecutive frames identical)"
mkdir -p "$OUT/work/tmp"
node "$HERE/tools/check-text-stability.mjs" "$OUT/work/frames" --tmp "$OUT/work/tmp" --report "$OUT/$NAME.text-stability-frames.md" | tail -n 4

step "3/6 encode MP4 (H.264, yuv420p, faststart, metadata stripped)"
INPUTS=(-framerate "$FPS" -i work/frames/%05d.png)
AUDIO_ARGS=(-an)
if [ -n "$AUDIO" ]; then
  cp "$AUDIO" "$OUT/work/voice-over.${AUDIO##*.}"
  INPUTS+=(-i "work/voice-over.${AUDIO##*.}")
  AUDIO_ARGS=(-c:a aac -b:a 192k -ac 2 -shortest -map 0:v:0 -map 1:a:0)
fi
ff "$OUT" -y -loglevel error "${INPUTS[@]}" \
  -vf "scale=out_color_matrix=bt709:out_range=tv,format=yuv420p" \
  -c:v libx264 -preset slow -crf 18 -profile:v high -level 4.1 -r "$FPS" -g $((FPS * 2)) \
  -colorspace bt709 -color_primaries bt709 -color_trc bt709 \
  -map_metadata -1 -fflags +bitexact -flags:v +bitexact -flags:a +bitexact \
  "${AUDIO_ARGS[@]}" work/encoded.mp4
# Second pass without re-encoding: drops the container and stream metadata that the encoder pass adds (encoder name,
# muxer version) and the encoder's version string in the video stream (an H.264 SEI NAL unit, type 6).
ff "$OUT" -y -loglevel error -i work/encoded.mp4 -c copy -map 0 -map_metadata -1 -map_metadata:s -1 \
  -bsf:v filter_units=remove_types=6 -fflags +bitexact -movflags +faststart "$NAME.mp4"
rm -f "$OUT/work/encoded.mp4"

step "3b/6 text stability of the MP4 (decoded again)"
node "$HERE/tools/check-text-stability.mjs" "$OUT/$NAME.mp4" --tmp "$OUT/work/tmp" --report "$OUT/$NAME.text-stability.md" | tail -n 4

step "4/6 gallery GIF (silent loop, palette optimised, size ladder down to ${GIF_MAX} bytes)"
node "$HERE/tools/gif-frames.mjs" "$OUT/work/frames" "$OUT/work/gif-frames"
GIF_OK=0
# width fps colors
IFS=';' read -r -a LADDER <<< "${GIF_PRESETS:-960 12 192;800 12 160;800 10 128;720 10 128;640 10 96;640 8 96;560 8 64;480 8 48}"
for preset in "${LADDER[@]}"; do
  set -- $preset
  ff "$OUT" -y -loglevel error -framerate "$FPS" -i work/gif-frames/%05d.png \
    -vf "fps=$2,scale=$1:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=$3:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
    -map_metadata -1 -fflags +bitexact -loop 0 "$NAME.gif"
  SIZE=$(stat -c %s "$OUT/$NAME.gif")
  echo "   gif preset width=$1 fps=$2 colors=$3 -> $SIZE bytes"
  if [ "$SIZE" -le "$GIF_MAX" ]; then GIF_OK=1; echo "   chosen: width=$1 fps=$2 colors=$3"; break; fi
done
[ "$GIF_OK" = 1 ] || echo "   WARNING: even the smallest preset is over ${GIF_MAX} bytes; shorten gif.segments in timeline.json"

PREVIEW_ARGS=()
if [ "$PREVIEW" = 1 ]; then
  step "4b/6 preview copy under 10 MB (2-pass ABR, same frames)"
  KBPS="${PREVIEW_KBPS:-930}"
  PV="$NAME-preview"
  for attempt in 1 2 3 4; do
    COMMON=(-framerate "$FPS" -i work/frames/%05d.png
      -vf "scale=out_color_matrix=bt709:out_range=tv,format=yuv420p"
      -c:v libx264 -preset slow -b:v "${KBPS}k" -profile:v high -level 4.1 -r "$FPS" -g $((FPS * 2))
      -colorspace bt709 -color_primaries bt709 -color_trc bt709 -passlogfile work/preview-pass
      -map_metadata -1 -fflags +bitexact -flags:v +bitexact -an)
    ff "$OUT" -y -loglevel error "${COMMON[@]}" -pass 1 -f null /dev/null
    ff "$OUT" -y -loglevel error "${COMMON[@]}" -pass 2 work/preview-encoded.mp4
    ff "$OUT" -y -loglevel error -i work/preview-encoded.mp4 -c copy -map 0 -map_metadata -1 -map_metadata:s -1 \
      -bsf:v filter_units=remove_types=6 -fflags +bitexact -movflags +faststart "$PV.mp4"
    PSIZE=$(stat -c %s "$OUT/$PV.mp4")
    echo "   preview ${KBPS} kbit/s -> $PSIZE bytes"
    if [ "$PSIZE" -lt 10000000 ]; then break; fi
    KBPS=$(( KBPS * 92 / 100 ))
  done
  rm -f "$OUT/work/preview-encoded.mp4" "$OUT"/work/preview-pass*
  [ "$PSIZE" -lt 10000000 ] || { echo "build.sh: preview is still $PSIZE bytes" >&2; exit 1; }
  node "$HERE/tools/check-text-stability.mjs" "$OUT/$PV.mp4" --tmp "$OUT/work/tmp" --report "$OUT/$PV.text-stability.md" | tail -n 4
fi

step "5/6 ffprobe + verification"
fp "$OUT" -v error -show_format -show_streams -of json "$NAME.mp4" > "$OUT/$NAME.mp4.ffprobe.json"
fp "$OUT" -v error -show_format -show_streams -of json "$NAME.gif" > "$OUT/$NAME.gif.ffprobe.json"
VERIFY_ARGS=(--mp4 "$OUT/$NAME.mp4" --mp4-probe "$OUT/$NAME.mp4.ffprobe.json" --gif "$OUT/$NAME.gif" --gif-probe "$OUT/$NAME.gif.ffprobe.json" --gif-max "$GIF_MAX")
[ -n "$AUDIO" ] && VERIFY_ARGS+=(--audio)
if [ "$PREVIEW" = 1 ]; then
  fp "$OUT" -v error -show_format -show_streams -of json "$NAME-preview.mp4" > "$OUT/$NAME-preview.mp4.ffprobe.json"
  VERIFY_ARGS+=(--preview "$OUT/$NAME-preview.mp4" --preview-probe "$OUT/$NAME-preview.mp4.ffprobe.json" --preview-max 10000000)
fi
node "$HERE/tools/verify.mjs" "${VERIFY_ARGS[@]}" | tee "$OUT/$NAME.verify.md"

step "6/6 clean up"
rm -rf "$OUT/work/gif-frames" "$OUT/work/tmp"
if [ "$KEEP" = 0 ]; then rm -rf "$OUT/work/frames"; fi
echo "done in $(( $(date +%s) - START )) s: $OUT/$NAME.mp4  $OUT/$NAME.gif"
echo "next: privacy/run.sh $OUT/$NAME.mp4 $OUT/$NAME.gif   (frames every 2 s, contact sheets, metadata, forbidden-string scans; set CAPTURES_DIR to scan the capture PNGs too)"
