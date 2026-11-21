# Provenance: Nacho Combo intro video v0.13.0

What the video is made from, with what, and under which licences. No user names, host names or paths are recorded here on purpose.

## What it is
- A 75 s, 1920x1080, 25 fps, H.264 video with burned-in English captions (`captions.en.srt`) and a 14 s silent GIF loop. A third file, `nacho-combo-intro-v0.13.0-preview.mp4` (under 10 MB), is a **confirmation copy** for chat previews: same pictures, size, 25 fps, 1875 frames and 75.00 s, a lower bit rate. It is **not the deliverable**.
- **Not a screen recording.** Every app picture is a render the app made itself (or, for four of them, the CI runner's off-screen render of the same v0.13.0 code on test data). The motion (zoom, scroll, cursor click, panel wipe, cross-fades) and all text on top are drawn afterwards in an HTML scene (`tools/scene`). The first and last scene say so on screen.
- Built with the pipeline in this folder (`build.sh`, `tools/`, `timeline.json`, `STORYBOARD.md`), no video editor.
- This is the **second build** (NACHO-994): the first MP4 had a 1 px sideways wobble of the big text (next section) and is superseded. The pictures, `timeline.json` and the look are the same; the render method is different and caption 8 reads "Window Snap: 24 commands, or drag a window to an edge." (it said "24 keyboard commands"; the README says "24 window commands").

## Product build shown
- **Nacho Combo v0.13.0** (`CFBundleShortVersionString 0.13.0`, ad-hoc signed), tag v0.13.0, commit `fdcd4c9`.
- Release disk image `NachoCombo-0.13.0-macos.dmg`, SHA-256 `5283efdeaa69ba3710e033ce34ee131c374b7376e4fb8b04e9c83fcdda8fb8bf` (equal to the release's `SHA256SUMS.txt`).

## Render method: why the text wobbled and what changed (NACHO-994)
- **Symptom (reported by the owner, measured on the first MP4):** the big English text (scene titles) moved left and right by 1 px with a period of 6 frames, about 4.2 Hz at 25 fps. Example, scene S04a "WINDOW SNAP": the right end of the text alternates between 520 and 521 px in a repeating pattern. A re-render with the old method shows the same pattern in its raw PNG frames, so it is the renderer and not the encoder. Captions were not affected.
- **Cause:** `tools/render.mjs` drew frame i on browser page (i mod 6) (default `--workers 6`), and the same text came out up to 1 px different on each page, depending on the frames that page had drawn before: every scene element had `will-change: opacity, transform` (its own compositor layer) and finished elements kept a `translateX(0px)` / `scale(1)` transform. One page drawing the frames in order gives identical text.
- **What changed:**
  1. `tools/render.mjs`: default `--workers 1` (one page draws every frame in order). More pages are still possible (`--workers N`) but print a warning and must pass the check below; `--range a,b` renders only part of the timeline for quick checks.
  2. `tools/scene/scene.css`: `will-change` removed from `.el`; text uses `text-rendering: geometricPrecision`, `font-kerning: normal`, no ligatures.
  3. `tools/scene/scene.js`: once an entrance is over (p >= 1) an element gets `transform: none`, `clip-path` empty and no `opacity` property; entrance offsets are whole pixels; a shot that does not zoom gets `transform: none`.
  4. New `tools/check-text-stability.mjs` (also run by `build.sh` on the PNG frames, the MP4 and the preview): measures the left end, right end and sub-pixel centre shift of every title, label, tagline, pill and caption in its stable window and tests them for a pattern against frame number modulo 2 to 8. Its rules and limits are in the header of the script.
- **Evidence (same tool, same rules):**

| What was checked | Result |
|---|---|
| First MP4 (sha256 `e4e2e269...a8dabf`, superseded) | **FAIL**: 14 of 14 titles fail (an end moves 1 px in 13 of them, centre shift 0.21 to 0.77 px in all 14); 41 of 55 measurements pass (pills and captions were stable); periodic patterns with period 6 (16 findings), 3, 4 and 8 |
| Frames of the old renderer, 6 pages, re-rendered | **FAIL**: 14 titles, period 6 in the PNG frames themselves (35 findings with period 6) |
| Frames of the new renderer, 1 page (what this MP4 was encoded from) | **PASS** 55 of 55: ends 0 px, centre shift 0.000 px, no text pixel changes between consecutive frames, no periodic pattern |
| This MP4 | **PASS** 55 of 55: no title or pill end moves, largest centre shift 0.006 px, one single 1 px step of one caption end (an encoder re-coding a still picture once, allowed up to 2 per window) |
| Preview copy | **PASS** 55 of 55 |
| New renderer, 6 pages (experiment) | text **PASS** 55 of 55 (page independent now); 566 of 1875 frames still differ from the 1-page frames, only inside the screenshot area and by at most 16 of 255 levels (image resampling during zooms and wipes), which is why the default stays at one page |

- **Render time:** 247.8 s for the 1875 frames on one page (the old default took 204.7 s on 6 pages); the whole build including encodes, GIF, preview copy and checks is about 6.5 minutes.

## Where each picture comes from
| Picture | File | Source | How made |
|---|---|---|---|
| c01 menu bar items | `c01-menu-bar.png` | Mac mini, v0.13.0 build | `ctl monitor menubar ... sample` (sample numbers), dark |
| c02 wall | `c02-wall-home.png` | **CI off-screen render**, test fixture data | scene `s1-wall-closed-dark`, CI run 44873248670 on commit `fdcd4c9` (GitHub Actions of the public repository), 1x (1210x770) |
| c03 panel, Calendar Clock | `c03-wall-panel-calendar.png` | **CI off-screen render**, test fixture data | scene `s2-calendar-settings-dark`, same run, 1x |
| c04 panel, Shortcuts tab | `c04-wall-panel-shortcuts.png` | **CI off-screen render**, test fixture data | scene `s2-calendar-shortcuts-dark`, same run, 1x (Calendar Clock's tabs, not Window Snap's) |
| c05 panel, Permissions tab | `c05-wall-panel-permissions.png` | **CI off-screen render**, test fixture data | scene `s2-calendar-permissions-dark`, same run, 1x |
| c10 Window Snap | `c10-window-snap.png` | Mac mini, v0.13.0 build | `ctl gallery preview windowSnap`, sample content, dark |
| c11 System Monitor | `c11-system-monitor.png` | Mac mini, v0.13.0 build | `ctl gallery preview systemMonitor`, sample numbers |
| c12 CPU flyout | `c12-monitor-cpu-flyout.png` | Mac mini, v0.13.0 build | `ctl monitor flyout cpu 0 ... sample` |
| c13 Capture Float | `c13-capture-float.png` | Mac mini, v0.13.0 build | `ctl gallery preview captureFloat` |
| c14 File Shelf | `c14-file-shelf.png` | Mac mini, v0.13.0 build | `ctl gallery preview fileShelf` |
| c15 Focus Dim | `c15-focus-dim.png` | Mac mini, v0.13.0 build | `ctl gallery preview focusDim ... light` |
| c16 Disk Map | `c16-disk-map.png` | Mac mini, v0.13.0 build | `ctl disk sample`, sunburst, colored by folder (made-up disk) |
| c20 Combos | `c20-combos.png` | Mac mini, v0.13.0 build | `ctl gallery page combos`, Desk combo selected, `ctl gallery detail` |
| c21 quick panel, tool list | `c21-quick-panel.png` | Mac mini, v0.13.0 build | `ctl panel list` + `ctl snapshot panel`; **real on/off state of that app instance, not sample data** |
| c22 quick panel, combos | `c22-quick-panel-combos.png` | Mac mini, v0.13.0 build | `ctl panel combos` + `ctl snapshot panel` |
| app icon | `Resources/AppIcon.png` | repository (v0.13.0) | read at render time |
| Nacho mascot, idle and happy | `Resources/Nacho/idle.png`, `happy.png` | repository (v0.13.0) | read at render time, on a drawn desktop card |

SHA-256 of the 15 capture PNGs: see the table at the end.

### Shooting environment
- **11 pictures (c01, c10 to c16, c20 to c22):** Mac mini, macOS 27.2.1 (26B131), app run from a copy of the DMG's .app with --debug-ctl, gallery sample on. The app render has no desktop, menu bar of the Mac or other app around it. Appearance dark (c15 light). The app that was running before the shoot was stopped and restarted afterwards (shoot approved by the owner); the app's settings files were byte-identical before and after.
- **4 pictures (c02 to c05):** the macOS CI runner's off-screen render of the same v0.13.0 code on test fixture data. 1x resolution, so they are shown at about 1x and look softer than the Mac pictures.
- An attempt to shoot the wall and panel on the Mac produced the wrong subject (the app-settings panel) and was discarded.

### Scene to picture
| Scene | Time | Pictures |
|---|---|---|
| S01 Hook | 0:00 to 0:06 | app icon, c01 (Mac mini) |
| S02 Widget window | 0:06 to 0:12.5 | c02 (CI render) |
| S03 Settings panel | 0:12.5 to 0:24 | c02, c03, c04, c05 (CI renders) |
| S04a Window Snap | 0:24 to 0:28.4 | c10 (Mac mini) |
| S04b System Monitor | 0:28.4 to 0:33.2 | c11, c12 (Mac mini) |
| S04c Capture Float | 0:33.2 to 0:37.4 | c13 (Mac mini) |
| S04d File Shelf | 0:37.4 to 0:41.6 | c14 (Mac mini) |
| S04e Focus Dim | 0:41.6 to 0:45.4 | c15 (Mac mini) |
| S04f Disk Map | 0:45.4 to 0:50 | c16 (Mac mini) |
| S05a Combos | 0:50 to 0:56.5 | c20 (Mac mini) |
| S05b Quick panel | 0:56.5 to 1:02 | c21, c22 (Mac mini) |
| S06 Nacho Pet | 1:02 to 1:07 | mascot art on a drawn card (no app render) |
| S07 Download | 1:07 to 1:15 | app icon |

### What was done to the pictures
Fitted to the frame (no distortion), slow push-in on some, c20 scrolled from the board to the Desk combo, c21 cropped above its header and below the Nacho Pet row, c21's grey pixels re-levelled and c22 given a brightness/contrast filter because both snapshots are washed out (colour and alpha untouched in c21), a panel wipe between c02 and c03 that imitates the panel opening (the real panel slides in), a drawn cursor and click ripple. Nothing else was edited, retouched or composed into the app pictures.

## Tools and versions (build machine, nothing shipped)
| Tool | Version | Licence |
|---|---|---|
| Playwright `playwright-core` 1.64.0 with Chromium 156.0.8078.4 | renders the scene frame by frame | Apache-2.0 (Playwright), BSD-style (Chromium) |
| FFmpeg 7.1 with x264 (Docker image `jrottenberg/ffmpeg@sha256:292a972c60356abd651d9a4f9c808c13e7473f65ad400b7eb99215f4e571931d`) | H.264 encode (crf 18, preset slow, High 4.1, yuv420p, bt709), metadata strip, GIF palette | FFmpeg built with GPL and nonfree options: the binary is only run, never shipped; its output is not covered by its licence |
| Node.js 22 | scripts, including `tools/check-text-stability.mjs` | MIT |
| Pillow (Python) | contact sheets of the review only | HPND |

Encode: 25 fps, 1875 frames, `-map_metadata -1`, a second pass without re-encoding removes container tags and the encoder's version string; `+faststart`. GIF: 800 px wide, 10 fps, 128 colours, Bayer dither, loop forever, from four segments of the video (0.4 to 3.4 s, 13.6 to 16.5 s, 24.0 to 28.3 s, 67.2 to 70.9 s). Preview copy: same frames, libx264 2-pass ABR at 930 kbit/s (preset slow, High 4.1, yuv420p, `-g 50`), `-movflags +faststart`, `-map_metadata -1`, the same metadata-stripping copy pass; 8 757 199 bytes, 934 kbit/s measured.

## Fonts (in the picture)
Anton (wordmark and scene titles), IBM Plex Sans (captions, text), IBM Plex Mono (labels, address): the app's own brand fonts from `Resources/Fonts`, SIL Open Font License 1.1 (Anton Project Authors; IBM Corp.). Used as rendered text, not modified, renamed or embedded in a distributed font file.

## Sound
- **Music: none.** No music track.
- **Voice / TTS: none (subtitle-only).** The tooling issue's research (`TTS-AND-AUDIO.md`) recommends subtitle-only: voice licences differ per voice model and nobody has listened to a candidate voice for this script. No paid or cloud voice was used, no macOS `say` output. The video has no audio stream.

## Rights
The source code is MIT. The app icon, the Nacho character and the app's artwork are © Mafianacho, all rights reserved and not open source (`TRADEMARKS.md`, `Resources/Nacho/LICENSE`); they are used here in Mafianacho's own promotion of its own app. Pictures of the app are the app's own renders.

## Files
| File | SHA-256 | Size |
|---|---|---|
| `nacho-combo-intro-v0.13.0.mp4` (the deliverable) | `6342741b83846d639a6b78e00474108e0d0807eb32287b7f600a19901d60ad07` | 12840238 bytes |
| `nacho-combo-intro-v0.13.0.gif` | `ce67dc0cc36ae8ecc592653cc9b2ccc4907a5c8700713f66031d7961b2c7f31c` | 1003450 bytes |
| `nacho-combo-intro-v0.13.0-preview.mp4` (confirmation copy, not the deliverable) | `32e54bf0c7541c333b1e84a369dc54247a9c14747e43ae51acf53d8f018b7424` | 8757199 bytes |

Superseded (the first build, with the 1 px text wobble; kept in `final/superseded-jitter/`): MP4 `e4e2e26993101a6a4bd3704c8b7f2780792147f2564a78ee0eaca675a5a8dabf`, GIF `28de85f0d2bac4474700ccd63f788f6da7233e444f9d64361aa3fd5dd93ce8c7`. Do not use them.

SHA-256 of the capture PNGs used:

| File | SHA-256 |
|---|---|
| `c01-menu-bar.png` | `56c2eb8b1c267f785b367fe82d9d72347ce78b4a854ae0d056303e92c2ef9a14` |
| `c02-wall-home.png` | `e1822a96fd9df81bb9efeb5f937089732b0005e2bbd7243a80d164e0f42de626` |
| `c03-wall-panel-calendar.png` | `682ea387fc66d952944d39a3c86263255bd97baac6aa36a0fa100a2b793851e3` |
| `c04-wall-panel-shortcuts.png` | `c1597a775b0fbb00745837556a73da7ee00f768d9f50a660b1b924292edd635b` |
| `c05-wall-panel-permissions.png` | `6ebc8315d7d95859331b31cdeea8772affb3affdb01f44b036fc9982b1956baf` |
| `c10-window-snap.png` | `cf81384485b769434189e547e5ae9f28c24ecc49a1e5432d8735c81ddf77d4fd` |
| `c11-system-monitor.png` | `eb72c62d160770d9ee116cf79f2dc22cac4389b23ff8156a7407ac361820d55f` |
| `c12-monitor-cpu-flyout.png` | `fa01c539ff95ac53ba8cbde3538e5829ebe1f0bc2ad4c2d78e78dd28642ec90b` |
| `c13-capture-float.png` | `f2fad137cf0814f19f6e9f14264b50b7a7cd15d7dcee1fc9f759530aa5273694` |
| `c14-file-shelf.png` | `451e2988c607020ad654ebd39b4dd6ce1297d85a4a467f5425a1f4e7c7830c33` |
| `c15-focus-dim.png` | `1d95f56a571b3d97bd64d1a5c540e483d1bfd950e7a703abe1d046c505c0ab42` |
| `c16-disk-map.png` | `d1637b10f0b0ee633dbf0b04afb10ac01ddfab62bb1dad34d47894cdc7972a5a` |
| `c20-combos.png` | `0a928c5b2cb5f5a908f5e8209ed14e6d39ab54390cc81a3978104f599e77d608` |
| `c21-quick-panel.png` | `23db1e049e8c3a9c3b6976f7b5a7c0715dcfad9320fbec6898764ae3c76326ae` |
| `c22-quick-panel-combos.png` | `1bca0c79cce29569d374b0593948dd9479648457421f5e75fc920251556d2b03` |
