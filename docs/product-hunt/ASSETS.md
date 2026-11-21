# Product Hunt asset plan

Status: PLAN. No image or video is produced or uploaded by this document. The screens and the video come from later
NACHO-975 steps and go to `docs/product-hunt/assets/` (small PNG only; no video or large file is committed to the
repository). Every upload to Product Hunt needs 🔒 **Boss approval required**.

Sizes come from Product Hunt's help article "4. Build your product page"
(https://help.producthunt.com/en/articles/17834537-4-build-your-product-page), read 2026-11-21 (see [SOURCES.md](SOURCES.md)).
`⚠ Unverified (estimate)` marks values the article does not state.

## 1. Specs

| Asset | Official rule (G4, checked 2026-11-21) | Our plan |
|---|---|---|
| Logo / thumbnail | "Recommended size: 240x240px. JPG, PNG, or GIF, up to 2MB." The square image next to the launch on the leaderboard. Animated logos "only play on hover". | 240x240 PNG made from the app icon (`docs/images/app-icon.png`, 256x256 today; downscale, keep square). Static PNG, well under 2 MB. |
| Separate thumbnail | ⚠ Unverified: no separate "thumbnail" field is described; the logo is the square image. | none |
| Gallery images | "at least 1 required"; "3 or more images" listed as a way to stand out; "Recommended size: 1270x760px". ⚠ Unverified: maximum number of images, accepted formats and per-file size. | 5 to 8 PNG images at 1270x760 (about 5:3), each under 2 MB as a safe guess (⚠ Unverified estimate; not an official gallery limit). |
| Video | "optional but recommended"; added "by link". ⚠ Unverified: length, format, hosts, size. | One link to the intro video (16:9, 1920x1080, MP4 H.264 file, 60 to 90 seconds, made in another NACHO-975 sub-issue). Link: `TBD after boss-approved upload`. |
| GIF | ⚠ Unverified for the gallery: G4 gives a GIF rule only for the logo (up to 2 MB). | 10 to 20 second silent loop from the same video, kept as an optional gallery item; check the size limit in the upload form before upload. |

Rules for every image (from the project brief, not Product Hunt): sample data only, no real names, paths, e-mail
addresses, clipboard text, calendar events, notifications or other apps' windows; English captions; the Nacho character
only as part of the app UI (TRADEMARKS.md).

## 2. Gallery plan (8 slots at most)

The gadget order follows the README's gadget table and the order in which the README hero slideshow introduces them
(Window Snap first, System Monitor second...). It is meant to match the intro video's storyboard, so one story runs
through the video and the gallery. If the storyboard changes, change the order here.

Source column: where a ready-made, app-rendered picture already exists in the repository (rendered by
`scripts/screenshots.sh`). Since PR #76 the README pictures of the widget window and its panel (`gallery-*.png`, `combos.png`, `permissions.png`, `detail-*.png`)
show the v0.13.0 design. The README says they are off-screen renders from the CI test run with made-up data (the version number in them is a test value), so
check every picture for a wrong version number before using it, and re-render with sample data if needed.

| # | Gallery image title | English caption (max about 90 characters, ⚠ Unverified: no official caption field was described) | App screen to use | Existing picture to start from |
|---|---|---|---|---|
| 1 | The widget window | Every gadget is a widget on one wall. Click one and its settings open on the right. | Widget window with the gadget wall and the settings panel open on one gadget (v0.13.0 design, sample data) | `docs/images/gallery-dark.png` (1210x770; v0.13.0 wall with the Calendar Clock panel open; check the version text in it) |
| 2 | Combos | Order a combo to switch on a few gadgets together. | Combos page with a combo selected (for example No.2 Desk) | `docs/images/combos.png` (480x1000, Combos tab of the panel; re-render wider for the gallery) |
| 3 | Window Snap | Snap windows from the keyboard or by dragging to an edge. | Window Snap: window on the left half, drag zone at the right edge | `docs/images/window-snap.png` (800x448) |
| 4 | System Monitor | CPU, memory, disk, network and battery in your menu bar. | Menu bar items above the CPU panel, sample numbers | `docs/images/system-monitor.png` (800x600) |
| 5 | Capture Float | Keep a screen capture floating above your work. | Selection over a chart and the floating capture with its buttons | `docs/images/capture-float.png` |
| 6 | File Shelf | A floating shelf for files, links and text while you move between apps. | Shelf holding sample items (sample file names only) | `docs/images/file-shelf.png` |
| 7 | Focus Dim, Clipboard History and more | Dim everything behind the window you work in. Search what you copied. | Two-panel collage: Focus Dim and Clipboard History with sample text | `docs/images/focus-dim.png`, `docs/images/clipboard-history.png` |
| 8 | Disk Map | See what fills your disk, and remove things with your approval. | Sunburst with the free-space wedge, sample disk | `docs/images/disk-map-sunburst.png` (2280x1556) |

Not in the gallery (to stay honest and within 8): Menu Bar Organizer, Keep Awake, Device Control, App Switch, Mouse Tune
and Calendar Clock appear in the video; Computer Use (experimental) and Nacho Pet are mentioned in the text only,
because the README says neither has been tried on a real Mac. If the boss wants the pet in the gallery, use a sample
chat with no login screen and no real conversation, and show the pet only through the app's own UI.

## 3. Video slot

| Item | Value |
|---|---|
| Link | `TBD after boss-approved upload` |
| Where it is hosted | ⚠ Unverified: the host is not chosen; publishing the video on YouTube or any host is its own 🔒 Boss approval required step |
| File | produced by the video sub-issue under the artifacts folder outside the repository; not committed here |
| Content | 60 to 90 seconds, English on-screen captions, app screens in Korean, v0.13.0 widget window |

## 4. Checklist before upload (each upload is a 🔒 step)

- [ ] Images are 1270x760, PNG, readable at thumbnail size
- [ ] Privacy check passed on every image (sample data only; see the video sub-issue's checklist for the method)
- [ ] Captions are English and match [LISTING.md](LISTING.md) wording
- [ ] No claim in a caption is outside the README (see SOURCES.md section C)
- [ ] The video link is a real, public, boss-approved link

## 5. Produced images (NACHO-975, v0.13.0)

Files in `docs/product-hunt/assets/`: `thumbnail.png` (240x240, from `docs/images/app-icon.png`, 256x256 downscaled) and seven
1270x760 PNG gallery images. Captions are laid over the capture PNGs (HTML/CSS rendered with Chromium, fonts Noto Sans).
The eighth slot (Combos) is left out: the only usable source (quick-panel capture) is washed out; no filler. Gadget counts are not used in
any caption (README 13 vs. release notes 15: ⚠ pending boss decision). The video link stays `TBD after boss-approved upload`; the
final MP4/GIF live outside the repository under `.../nachocombo-promo/final/` and are not committed.

| File | Source capture | Origin | Caption (README basis) |
|---|---|---|---|
| `gallery-01-widget-wall.png` | c02-wall-home | CI off-screen render, fixture data, 1x, Korean UI | "Every gadget is a widget on one wall." (README "Opening the app shows the widget window: every gadget is a widget on a wall") |
| `gallery-02-settings-panel.png` | c03-wall-panel-calendar | CI render, fixture data, 1x, Korean UI | "Click a widget and its panel slides in from the right." (README "Click a widget and a panel slides in from the right") |
| `gallery-03-window-snap.png` | c10-window-snap | Mac mini real build, app-drawn sample | "Snap windows from the keyboard or by dragging." (gadget table: "24 window commands from the keyboard, drag to snap") |
| `gallery-04-capture-float.png` | c13-capture-float | Mac mini real build, sample | "Keep a capture floating above other windows." (table: "keeps it floating above other windows") |
| `gallery-05-file-shelf.png` | c14-file-shelf | Mac mini real build, sample | "A floating shelf for files, images, links and text." (table, File Shelf) |
| `gallery-06-focus-dim.png` | c15-focus-dim | Mac mini real build, sample | "Keep the active window bright and dim everything behind it." (table, Focus Dim) |
| `gallery-07-disk-map.png` | c16-disk-map | Mac mini real build, sample disk | "See what fills your disk, as a sunburst or as blocks." (table, Disk Map) |

Images 01 and 02 show Korean app text (UI localization is out of scope for this release); the captions say what the screen shows.
