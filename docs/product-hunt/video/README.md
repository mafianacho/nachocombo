# Intro video tooling (Product Hunt, NACHO-975)

Everything needed to make the English intro video for Nacho Combo from pictures the app renders itself, and to prove it
leaks nothing personal. **Text and scripts only**: videos, GIFs, frames and capture PNGs are never committed (see
`.gitignore`); they go to an artifacts folder outside the repository.

| File | What it is |
|---|---|
| [STORYBOARD.md](STORYBOARD.md) | the 75 s scene plan, where every claim comes from, and the **capture list** the next step shoots |
| [captions.en.srt](captions.en.srt) · [NARRATION.md](NARRATION.md) | English captions (burned in and as SRT) and the same words as an optional voice-over script |
| [TTS-AND-AUDIO.md](TTS-AND-AUDIO.md) · [LICENSES.md](LICENSES.md) | voice and music licences with the recommendation (subtitle-only), fonts, tools |
| [PROVENANCE.md](PROVENANCE.md) | **the final v0.13.0 video**: build shown, where each picture came from (Mac mini render / CI off-screen render), tools and versions, fonts, sound (none), sha256 of the MP4, GIF and capture PNGs |
| `capture-manifest.json` → `capture.sh` | the capture list as data; `capture.sh` (generated) shoots all PNGs on a Mac from the debug build |
| `timeline.json` | the scene timeline: what is on screen, when, where (renderer input) |
| `build.sh` | **one command**: captures folder → MP4 (H.264) + gallery GIF + ffprobe + verification |
| `tools/` | `render.mjs` (scene → PNG frames on a fixed clock), `scene/` (the HTML scene), `check-captions.mjs`, `check-text-stability.mjs` (no sideways wobble of text), `verify.mjs`, `gif-frames.mjs`, `make-standin.mjs`, `gen-capture.mjs`, `ffmpeg.sh` |
| `privacy/` | the privacy check: `run.sh` (frames every 2 s, contact sheets, metadata dump, forbidden-string scans, checklist), `scan-forbidden.mjs`, `forbidden-patterns.json`, `CHECKLIST.template.md` |

## How it works
```
captures/*.png + capture-manifest.json + timeline.json + captions.en.srt
   └─ tools/render.mjs   Chromium (Playwright) draws the HTML scene at t = N/25 s, 1920x1080 PNG per frame (one page, in order)
       └─ tools/check-text-stability.mjs   frames: titles, labels and captions must not move sideways (PASS needed)
       └─ ffmpeg (Docker, libx264)   frames → MP4 (yuv420p, +faststart), then a copy pass that strips every tag and the encoder's version SEI
       └─ tools/check-text-stability.mjs   the MP4 decoded again: the same check
       └─ ffmpeg                      selected segments → palette-optimised GIF, steps down in size until it is under 2 MiB
       └─ ffmpeg (--preview)          a copy under 10 MB (2-pass ABR) for chat previews; not the deliverable
           └─ tools/verify.mjs        ffprobe → 1920x1080, h264 High 4.1, yuv420p, 25 fps, 1875 frames, 75.00 s, no metadata, faststart; GIF 10-20 s, loops, size; preview under 10 MB
```
The method follows `scripts/capture-motion.mjs` (fixed-clock frames, ffmpeg encode), with the scene in HTML/CSS so captions,
titles, the cursor and the panel slide are code, not a video editor.

## Needs
- Node.js 18+ and a `playwright-core` directory that has a Chromium in the shared cache `~/.cache/ms-playwright`
  (`PLAYWRIGHT_CORE=/path/to/node_modules/playwright-core`). Nothing is installed or downloaded for Chromium.
- Docker for ffmpeg: the pinned public image `jrottenberg/ffmpeg@sha256:292a972c60356abd651d9a4f9c808c13e7473f65ad400b7eb99215f4e571931d`
  (tag `7-ubuntu`, FFmpeg 7.1 with x264, about 87 MB; pulled once, never removed by these scripts). Rootless Docker: set
  `DOCKER_HOST=unix:///run/user/<uid>/docker.sock`; rootful Docker: also set `FFMPEG_DOCKER_USER="$(id -u):$(id -g)"`.
  Without Docker, `FFMPEG_MODE=local` uses an `ffmpeg` on the PATH that has libx264, palettegen, tile and drawtext.
  When several automated runs share one Docker daemon, set `MULTICA_TASK_ID=<run id>`: every ffmpeg container then gets the label
  `mafianacho.owner=<run id>` and its own name `nc-video-<run id>-<pid>-<n>`, so a cleanup can be limited to a run's own containers
  (`docker ps --filter label=mafianacho.owner=<run id>`). Unset, the `docker run` command is unchanged. `tools/ffmpeg.test.sh` checks this with a fake `docker`.
- About 1 GB of free disk for the frames while building (removed afterwards unless `--keep-frames`), and about 6 to 7 minutes for 1875 frames: the render
  is one browser page drawing every frame in order (about 250 s; more pages with `--workers N` are faster but must pass `tools/check-text-stability.mjs`),
  then checks, encode, GIF and, with `--preview`, the small copy (about 90 s together).

## 1. Dry run with stand-in pictures (no Mac needed)
```sh
export PLAYWRIGHT_CORE=/path/to/node_modules/playwright-core
./build.sh --standin --out <artifacts>/draft --name draft-standin
```
`--standin` copies the existing `docs/images/*.png` under the capture file names and burns a **DRAFT** watermark into every frame:
it proves the pipeline and is not a deliverable.

## 2. The real video
1. On a Mac with a v0.13.0 (or newer) debug build, on a clean test user account: `APP=build/NachoCombo.app docs/product-hunt/video/capture.sh <captures dir>`.
   Fix any `ctl` command that v0.13.0 rejects in `capture-manifest.json`, then `node tools/gen-capture.mjs --write`.
2. Look at every PNG: sample data only, nothing personal (the `privacy` line of each capture in the manifest says what to look for).
3. Re-tune `timeline.json` to the real pictures: the click target in S03 (`click.at`), the combos crop in S05a, the focus points.
   Look at single moments fast with `node tools/render.mjs --captures <dir> --out <dir>/stills --still 5,14.6,30` (no video needed).
4. `./build.sh --captures <captures dir> --out <artifacts>/final --name nachocombo-intro`.
5. Privacy check, then fill in the by-eye rows of `<artifacts>/final/privacy/CHECKLIST.md`:
   ```sh
   privacy/run.sh <artifacts>/final/nachocombo-intro.mp4 <artifacts>/final/nachocombo-intro.gif
   ```
   `--offset <s>` starts the frame grid that many seconds into the video: after a rebuild use another offset, so the frames read are not the ones seen before.
   It writes, next to the video: `privacy/frames/f_0001.png` ... (one every 2 s: 38 for 75 s), `privacy/gif-frames/g_001.png` ... (one per second of the GIF loop), `contact-sheet-01.png` and `-02.png` with time
   stamps, `ffprobe.json` and `metadata.txt` (every container/stream tag), `scan-media.txt` (forbidden strings in the MP4/GIF bytes), `scan-source.txt`
   (forbidden strings in the scene files, timeline, captions, scripts and, with `CAPTURES_DIR=<dir>`, the capture PNGs including their PNG text chunks) and `CHECKLIST.md`.
   `node privacy/scan-forbidden.mjs --selftest` shows that the scanner really catches the patterns.
6. Upload and publishing are **not** part of this tooling and need a boss's approval (the Product Hunt procedure is `docs/product-hunt/PROCEDURE.md`, a sibling task): Product
   Hunt takes a video as a **link** (YouTube), not as a file.

## Checks that run by themselves
- `node tools/check-captions.mjs`: caption rules (42 characters a line, 2 lines, at most 17 characters per second, scene boundaries, narration at most
  150 words a minute, narration equals captions). `build.sh` runs it first.
- `node tools/gen-capture.mjs --check`: the STORYBOARD capture table and `capture.sh` match `capture-manifest.json`.
- `node tools/verify.mjs`: the output spec, run at the end of `build.sh`.
- `node tools/check-text-stability.mjs <video.mp4 | frames folder>`: PASS/FAIL for sideways wobble of the text (see the header of the script for what is measured and the limits).
  `build.sh` runs it on the PNG frames (exact) and on the MP4 and stops when it fails. `--selftest` shows that it catches a 1 px wobble.

## Notes
- The video is a slideshow of the app's own renders, not a screen recording, and says so on screen. Sample numbers and a made-up disk are labelled.
- Metadata: the MP4 is encoded with `-map_metadata -1 -fflags +bitexact`, then copied once more without re-encoding to drop the muxer's and encoder's tags and the
  x264 version string (H.264 SEI). What remains is the container's own structure: the file-type brand, language `und`, a generic `VideoHandler` name.
- The scene reads fonts and the icon/character art from this repository (`Resources/`) while rendering. No path of the machine that builds the video is written into any file this tooling makes.
- `GIF_MAX_BYTES=<n>` overrides the 2 MiB GIF target (the Product Hunt guide states 2 MB for animated logos and nothing for gallery GIFs; see LICENSES.md).
