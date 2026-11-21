# Licences of what goes into the video

Everything the pipeline uses is free to use locally. Nothing below is copied into this repository except text and scripts.

## Fonts (in the picture)
| Font | Use | Licence | File in the repo |
|---|---|---|---|
| Anton | the NACHO COMBO wordmark and scene titles | SIL Open Font License 1.1, © 2020 The Anton Project Authors | `Resources/Fonts/Anton-Regular.ttf`, `Anton-OFL.txt` |
| IBM Plex Sans | captions and text | SIL OFL 1.1, © 2017 IBM Corp. (Reserved Font Name "Plex") | `Resources/Fonts/IBMPlexSans-*.ttf`, `IBMPlex-OFL.txt` |
| IBM Plex Mono | labels and the address line | SIL OFL 1.1, © 2017 IBM Corp. | `Resources/Fonts/IBMPlexMono-*.ttf`, `IBMPlex-OFL.txt` |

These are the app's own brand fonts (README "Brand"). The render server reads them straight from `Resources/Fonts`; the fonts are
used, not modified or renamed, and are not embedded in a distributed font file (a video of text set in them is not a font
redistribution under the OFL).

## Pictures
| Picture | Licence / rights |
|---|---|
| Captures from the app (`ctl` snapshots, previews) | The app's own renders on sample data. The source code is MIT; the rendered artwork (icons, banner, character) is Mafianacho's |
| App icon (`Resources/AppIcon.png`), Nacho character (`Resources/Nacho/*.png`) | © 2026 Mafianacho, all rights reserved, not open source (`TRADEMARKS.md`, `Resources/Nacho/LICENSE`). Used in Mafianacho's own promotion of its own app; read from the repo at render time |
| Cursor arrow, ripple, drawn desktop card | Drawn for this video in `tools/scene/scene.js`; no third-party artwork, no Apple cursor image |

## Sound
None by default: no music, no voice. See [TTS-AND-AUDIO.md](TTS-AND-AUDIO.md) for the voice candidates and why subtitle-only is recommended.

## Tools (used on the build machine, not shipped)
| Tool | Version used | Licence | Notes |
|---|---|---|---|
| Chromium via Playwright (`playwright-core` 1.64.0, Chromium 156) | shared cache `~/.cache/ms-playwright` | Apache-2.0 (Playwright), BSD-style (Chromium) | renders the scene to PNG; no new install |
| FFmpeg 7.1 with x264 in the Docker image `jrottenberg/ffmpeg` (tag `7-ubuntu`, digest `sha256:292a972c60356abd651d9a4f9c808c13e7473f65ad400b7eb99215f4e571931d`) | pinned by digest in `tools/ffmpeg.sh` | FFmpeg configured with `--enable-gpl --enable-nonfree`: the **binary is not redistributable**, so it is only run, never shipped. Its output (the MP4, the GIF) is not covered by the encoder's licence | the Playwright-bundled ffmpeg has VP9 only, no H.264. H.264 is a patent-licensed format; encoding a free web video with x264 is ordinary practice and nothing of the encoder is redistributed; this is not legal advice |
| Node.js 18+ | 22 used | MIT | scripts |

## Product Hunt media limits used for the GIF target
Official guide "4. Build your product page" (https://help.producthunt.com/en/articles/17834537-4-build-your-product-page, read 2026-11-21): logo / thumbnail
"JPG, PNG, or GIF, up to 2MB", recommended gallery image 1270x760. No file-size limit for gallery GIFs is stated there (unverified), so the GIF
target is the stricter **2 MiB**. Product Hunt takes videos **by link** (official wording: "add videos and demos by link"); the accepted hosts, length and file upload are not documented there (unverified; see `docs/product-hunt/SOURCES.md` item B1).
