# Intro video storyboard (75 s, English captions)

Status: **final cut built (NACHO-977)** from the 15 v0.13.0 pictures (11 shot on a Mac mini from the v0.13.0 build, 4 wall and panel renders from the
v0.13.0 CI run; see `PROVENANCE.md` for the scene-by-scene origin). The scene table below describes the final cut; where it differs
from the first plan the changes are listed under "Changes in the final cut". Dry run with stand-in pictures: see [README.md](README.md).

## Format
| | |
|---|---|
| Length | 75 s (target 60 to 90 s) |
| Picture | 1920 x 1080, 16:9, 25 fps, H.264 `yuv420p`, `+faststart`, no metadata |
| Sound | none. Subtitle-only delivery: the words are burned into the picture and also shipped as `captions.en.srt`. No music. Optional voice-over: [NARRATION.md](NARRATION.md), see [TTS-AND-AUDIO.md](TTS-AND-AUDIO.md) |
| Gallery loop | 10 to 20 s silent GIF cut from the same frames (`gif.segments` in `timeline.json`), 2 MiB target |
| Fonts | Anton (brand lines), IBM Plex Sans (captions, text), IBM Plex Mono (labels): the app's own open-licensed brand fonts, SIL OFL 1.1, from `Resources/Fonts` |
| Colors | the app's dark menu-board brown (`#15110d`) and box yellow (`#ffc43d`), picked by eye from the app's gallery banner; check against `design/tokens.json` before the final cut |

## How it is made (and said honestly)
The video is a **slideshow of pictures the app renders itself**, with the motion (slide-in panel, cursor, ripple, zoom,
captions, cross-fades) drawn afterwards in a browser scene. It is not a screen recording and no desktop, menu bar or
notification of a real Mac is ever filmed. The first and last scene say so on screen ("Rendered by the app itself, not
a screen recording"), as the README does under its own hero GIF. System Monitor and Disk Map pictures use sample numbers and a
made-up disk, and their scenes say so in a label. The app's own text in the pictures is partly Korean (no English
localisation yet); the captions carry the explanation.

## Scenes
Captions are the cues of [`captions.en.srt`](captions.en.srt) (18 cues, at most 42 characters a line, two lines, 16.5
characters per second at most: `node tools/check-captions.mjs`). Times are on the video clock.

| Scene | Time | What is on screen | Captures | Caption cue(s) | Motion / transition |
|---|---|---|---|---|---|
| S01 Hook | 0:00 to 0:06 | App icon, the **NACHO COMBO** wordmark in Anton, the app's own line "One box. Only what you order.", the six System Monitor items as a menu bar strip. Top-right label: rendered by the app itself, not a screen recording | `app-icon`, `menu-bar` | 1, 2 | Fade in from black; icon pops, title slides in, strip rises |
| S02 Widget window | 0:06 to 0:12.5 | Title "The widget window". The whole window with the gadget wall, labels "Each gadget has its own switch" and "Window text is in Korean" | `wall-home` | 3, 4 | Cross-fade in; slow 6 % push-in |
| S03 Settings panel | 0:12.5 to 0:24 | Title "Click a widget". A cursor clicks the Calendar Clock tile, the panel **slides in from the right** (Calendar Clock, Settings tab). Then the Shortcuts tab, then the Permissions tab, both of Calendar Clock. Title becomes "Settings, shortcuts, permissions" | `wall-home`, `wall-panel-calendar`, `wall-panel-shortcuts`, `wall-panel-permissions` | 5, 6, 7 | Cursor travel from 13.3 s, ripple at 14.2 s, wipe-reveal of the panel at 14.6 s, tab changes by cross-fade at 17.0 s and 20.0 s |
| S04a Window Snap | 0:24 to 0:28.4 | Title, label "Needs: Accessibility", the Window Snap picture | `window-snap` | 8 | Cross-fade; 6 % push-in |
| S04b System Monitor | 0:28.4 to 0:33.2 | Labels "Permission: none", "Sample numbers"; the picture of the menu bar items over the CPU panel, then the CPU panel with its flyout | `system-monitor`, `monitor-cpu-flyout` | 9 | Cross-fade; the second picture fades in at 30.8 s |
| S04c Capture Float | 0:33.2 to 0:37.4 | Label "Needs: Screen Recording", the Capture Float picture | `capture-float` | 10 | Cross-fade; push-in |
| S04d File Shelf | 0:37.4 to 0:41.6 | Label "Permission: none", the File Shelf picture | `file-shelf` | 11 | Cross-fade; push-in |
| S04e Focus Dim | 0:41.6 to 0:45.4 | Label "Permission: none", the Focus Dim picture (light) | `focus-dim` | 12 | Cross-fade; push-in |
| S04f Disk Map | 0:45.4 to 0:50 | Labels "Permission: none", "Full Disk Access: optional", "Made-up sample disk"; the Disk Map sunburst | `disk-map` | 13 | Cross-fade; push-in |
| S05a Combos | 0:50 to 0:56.5 | Title "Combos", label "7 ready-made, plus your own"; the Combos page, scrolled from the board down to the Desk combo | `combos` | 14 | Cross-fade; slow pan down the board and a 12 % push-in |
| S05b Quick panel | 0:56.5 to 1:02 | Title "Quick panel", label "Click the nacho box in the menu bar"; the tool list (header and the Computer Use row cropped, grey pixels re-levelled for legibility), then the combo screen beside it | `quick-panel`, `quick-panel-combos` | 15 | Cross-fade; the second panel slides in at 57.7 s |
| S06 Nacho Pet | 1:02 to 1:07 | Title "Nacho Pet", labels "Switch it off any time" and "Illustration, not a capture"; the mascot (idle, then happy) in the corner of a drawn desktop card. **Mascot only**: no chat, no login screen, no conversation | `nacho-idle`, `nacho-happy` | 16 | Cross-fade; mascot pops in and bobs |
| S07 Download | 1:07 to 1:15 | Yellow end card: app icon, **NACHO COMBO**, "Free and open source (MIT)", "macOS 12 or later, Apple Silicon + Intel", `github.com/mafianacho/nachocombo/releases`, small print (MIT covers the source code only; artwork, icon and names are not open source; screens are v0.13.0 renders made by the app itself; sample or test data, except the quick panel's on/off dots, which show a real switch state, nothing personal) | `app-icon` | 17, 18 | Cross-fade; fade to black at 1:14.4 |

Order against the request: hook, whole widget window, settings in the right-hand panel (v0.13.0), six gadgets, combos and
quick panel, Nacho Pet (mascot only), download. Clipboard History was left out for time (its picture is in the README and
can replace Focus Dim; add a scene to `timeline.json` and re-time the captions).

## Claims and where they come from
Every sentence of the captions and labels, with its source in `README.md` (origin/main `f684d41`). Re-read this table
against the v0.13.0 README before the final cut.

| Cue / label | Claim | Source |
|---|---|---|
| 1, 2 | A menu bar app with many small tools, each switched on or off on its own. **No number is given on purpose**: the README intro counts thirteen gadgets plus Computer Use and Nacho Pet, the v0.13.0 release notes say "All fifteen gadgets" and the wall shows all of them | README intro ("One macOS menu bar app with thirteen gadgets, each switched on or off on its own"), `docs/release-notes/v0.13.0.md` |
| S02 label | Each gadget has its own switch | README intro, "Usage" |
| S01 line | "One box. Only what you order." | The app's own banner text on the gadget wall (visible in the gallery picture) |
| 3, 4 | Opening the app shows the widget window; every gadget is a widget on a wall | README "The app lives in the menu bar ... shows the widget window: every gadget is a widget on a wall" |
| 5 | Click a widget and a panel slides in from the right | README "The settings panel" ("Click a widget and a panel slides in from the right") |
| 6 | The panel has Settings, Shortcuts and Permissions tabs | README "A gadget's panel ... three tabs"; picture c04, c05 |
| 7 | Calendar Clock needs no permission; Calendars is optional (events are read on this Mac and never sent anywhere) | README "Calendar Clock" ("Calendars is optional and only for events") and Gadgets table; picture c05 (Permissions tab, "Not asked yet") |
| 8, S04a label | Window Snap: 24 commands, or drag a window to an edge; needs Accessibility | README Gadgets table ("24 window commands from the keyboard, drag to snap") and "Window Snap" (24 commands; drag to snap) |
| 9, S04b labels | System Monitor: CPU, memory, disk, network, sensor and battery menu bar items; no permission; pictures use sample numbers | README Gadgets table, "System Monitor", note under the intro screenshots |
| 10, S04c label | Capture Float keeps a capture floating above other windows; needs Screen Recording | README Gadgets table and "Capture Float" |
| 11 | File Shelf opens when you shake a drag; floating shelf | README Gadgets table and "File Shelf" |
| 12 | Focus Dim dims everything behind the active window; no permission | README Gadgets table and "Focus Dim" |
| 13, S04f labels | Disk Map shows what fills a disk as a sunburst or blocks; Full Disk Access optional; `ctl disk sample` is a made-up disk | README Gadgets table, "Disk Map", ctl list |
| 14, S05a label | A combo switches on a few gadgets together; seven ready-made combos, up to five of your own | README "Combos" |
| 15 | The quick panel (click the nacho box) lists the tools with their status and has a combo screen | README "Quick panel (menu bar)"; pictures c21, c22 |
| 16, S06 label | Nacho Pet: the Nacho character in the corner of the screen; switching the gadget off hides Nacho | README "Nacho Pet" ("sits in the bottom-right corner", "Switching the gadget off ... hides Nacho") |
| 17, S07 | Free and open source (MIT); macOS 12 or later; Apple Silicon and Intel | README header line, `LICENSE`, "Install (release)" |
| 17, S07 small print | MIT covers the source code only; the Nacho artwork, app icon and names are not open source | `LICENSE`, `TRADEMARKS.md`, README "License" |
| 18 | Download from GitHub Releases | README header line, "Install (release)" |
| S01, S07 label | Rendered by the app itself, not a screen recording | README line under the hero GIF; `scripts/screenshots.sh` |

Not claimed anywhere: Computer Use (experimental, not tried on a real Mac), automatic updates, anything about the Nacho
account, chat or login, the Windows app, notarization.

## Capture list (shoot this, nothing else)
Shot by the next step from a **v0.13.0 (or newer) debug build** with `./capture.sh <out dir>` (generated from
`capture-manifest.json`; it runs exactly the commands below). All captures are the app's own renders on sample data, 2x,
and none contains the desktop, the real menu bar or another app. Appearance is dark unless the table says light.
Run it on a clean test user account of a Mac. It refuses to start while a Nacho Combo process is already running (the Mac may be shared) and never kills one unless `KILL_RUNNING=1` is set.

Setup before the first capture: `ctl appearance dark`, `ctl gallery sample on`. Teardown after the last: `ctl disk hide`,
`ctl gallery page home`, `ctl gallery sample off`, `ctl appearance system`. `{out}` below is the file name in the output folder.

<!-- capture-table:start (generated by tools/gen-capture.mjs) -->

| # | File | Scene | Subject | Exact `ctl` commands (in order, after the setup below) | Look | Min width |
|---|---|---|---|---|---|---|
| 1 | `c01-menu-bar.png` | S01 | The six System Monitor menu bar items (CPU, memory, disk, network, sensors, battery) on sample numbers | `ctl monitor menubar c01-menu-bar.png sample` | dark | 800 px |
| 2 | `Resources/AppIcon.png` | S01, S07 | The app icon, read from the repository at render time (not copied, not a capture) | none: read from the repository at render time | n/a | 1024 px |
| 3 | `c02-wall-home.png` | S02, S03 | The widget window with the gadget wall, no panel open | `ctl gallery page home`<br>`sleep 1`<br>`ctl snapshot widget c02-wall-home.png` | dark | 1800 px |
| 4 | `c03-wall-panel-calendar.png` | S03 | The same window with the right-hand panel open on Calendar Clock, Settings tab (same window size as wall-home so the two overlay exactly) | `ctl gallery page calendarClock`<br>`ctl gallery tab overview`<br>`sleep 1`<br>`ctl snapshot widget c03-wall-panel-calendar.png` | dark | 1800 px |
| 5 | `c04-wall-panel-shortcuts.png` | S03 | Window Snap panel, Shortcuts tab, same window size | `ctl gallery page windowSnap`<br>`ctl gallery tab shortcuts`<br>`sleep 1`<br>`ctl snapshot widget c04-wall-panel-shortcuts.png` | dark | 1800 px |
| 6 | `c05-wall-panel-permissions.png` | S03 | Window Snap panel, Permissions tab, same window size | `ctl gallery page windowSnap`<br>`ctl gallery tab permissions`<br>`sleep 1`<br>`ctl snapshot widget c05-wall-panel-permissions.png` | dark | 1800 px |
| 7 | `c10-window-snap.png` | S04a | Window Snap picture: a window snapped to the left half and one dragged to the right edge (the app draws the desktop around it) | `ctl gallery preview windowSnap c10-window-snap.png` | dark | 800 px |
| 8 | `c11-system-monitor.png` | S04b | System Monitor picture: menu bar items above the CPU panel, sample numbers | `ctl gallery preview systemMonitor c11-system-monitor.png` | dark | 800 px |
| 9 | `c12-monitor-cpu-flyout.png` | S04b | CPU panel with the CPU chart card hovered and its flyout beside it, sample numbers | `ctl monitor flyout cpu 0 c12-monitor-cpu-flyout.png sample` | dark | 1300 px |
| 10 | `c13-capture-float.png` | S04c | Capture Float picture: dashed selection over a chart and the captured area floating with close, pin and share buttons | `ctl gallery preview captureFloat c13-capture-float.png` | dark | 800 px |
| 11 | `c14-file-shelf.png` | S04d | File Shelf picture: a file dragged onto the floating shelf holding a PDF, an image and a text snippet | `ctl gallery preview fileShelf c14-file-shelf.png` | dark | 800 px |
| 12 | `c15-focus-dim.png` | S04e | Focus Dim picture: one window bright in front, two dimmed behind (light variant reads better) | `ctl gallery preview focusDim c15-focus-dim.png light` | light | 800 px |
| 13 | `c16-disk-map.png` | S04f | Disk Map window on the made-up sample disk, sunburst view colored by folder | `ctl disk sample`<br>`ctl disk style sunburst`<br>`ctl disk color folder`<br>`sleep 1`<br>`ctl disk snapshot c16-disk-map.png` | dark | 2000 px |
| 14 | `c20-combos.png` | S05a | Combos page with the Desk combo selected (the whole page; the video crops the top) | `ctl gallery page combos`<br>`ctl combo select desk`<br>`sleep 1`<br>`ctl gallery detail c20-combos.png` | dark | 1000 px |
| 15 | `c21-quick-panel.png` | S05b | Menu bar quick panel, tool list (Combo row first, status dots) | `ctl panel list`<br>`sleep 1`<br>`ctl snapshot panel c21-quick-panel.png` | dark | 340 px |
| 16 | `c22-quick-panel-combos.png` | S05b | Menu bar quick panel, combo screen | `ctl panel combos`<br>`sleep 1`<br>`ctl snapshot panel c22-quick-panel-combos.png` | dark | 340 px |
| 17 | `Resources/Nacho/idle.png` | S06 | Nacho character, idle face (mascot only), read from the repository at render time | none: read from the repository at render time | n/a | 440 px |
| 18 | `Resources/Nacho/happy.png` | S06 | Nacho character, happy face (mascot only), read from the repository at render time | none: read from the repository at render time | n/a | 440 px |

<!-- capture-table:end -->

After shooting: `PLAYWRIGHT_CORE=... ./build.sh --captures <out dir> --out <artifacts>/final --name nachocombo-intro`, then
`privacy/run.sh <artifacts>/final/nachocombo-intro.mp4 <artifacts>/final/nachocombo-intro.gif` and fill in the checklist.

## Assumptions, decisions and what is not verified
1. **No capture command has been run against a real build.** Syntax comes from the README (Build / test), `scripts/screenshots.sh`
   and `Sources/NachoCombo/AppDelegate.swift` on `f684d41` (`gallery page|tab|preview|detail|sample`, `settings snapshot`,
   `combo select`, `snapshot panel`, `monitor ...`, `disk ...` all exist there; `gallery tab` accepts the old keys
   `overview` and `settings`). The shoot must confirm them on v0.13.0 and may adjust `capture-manifest.json`.
2. **Gadget count.** The README says thirteen gadgets plus Computer Use and Nacho Pet; the v0.13.0 release notes say "All fifteen
   gadgets" and the v0.13.0 wall shows fifteen widgets. The captions therefore give **no number** ("many small tools"). If the
   boss wants a number, "fifteen" would count the experimental Computer Use, which this video does not promote.
3. **Panel reveal.** In S03 the real panel opens inside the window and the wall re-flows (three columns beside the panel, four without).
   The video fakes the slide with a wipe between two window snapshots of the same size. The click target (`click.at` in
   `timeline.json`, now on the Calendar Clock tile of the v0.13.0 layout) must be checked on the real captures.
4. **Nacho Pet has no app render.** There is no `ctl` command that draws the pet on a desktop, so S06 uses the character
   pictures from `Resources/Nacho` on a drawn card. A real pet-in-the-corner picture would need a new `ctl` command (app code,
   out of scope). The scene is optional: remove S06 and re-time cues 16 to 18 if the boss would rather not show it.
5. **Korean text in the pictures.** The widget window, tabs and some labels are Korean. The captions and labels explain each
   scene in English. English localisation of the app is out of scope and stays a boss decision.
6. **Artwork rights.** The icon and the Nacho pictures are Mafianacho's own, all rights reserved (`TRADEMARKS.md`). They are
   read from the repository at render time and never copied into the repo's `docs/`.
7. **Colors and sizes** (yellow, brown, caption size) were chosen by eye, not read from design tokens; contrast of the
   captions is white on a 78 % black box.
8. **Length.** Six gadget scenes fill 26 s; no extra scene is needed to reach 75 s. The app has enough material: the longest
   candidates left out are Clipboard History, Keep Awake, Device Control, App Switch, Mouse Tune, Calendar Clock (only in S03) and Menu Bar Organizer.
9. **The v0.13.0 wall shows live-looking tiles.** Clipboard History rows, the Device Control output name, the Calendar Clock event,
   File Shelf items, System Monitor numbers, Nacho Pet's "sign in" button and Computer Use's permission state are all on the wall
   and in every window snapshot. `ctl gallery sample on` is expected to replace them with made-up values (the v0.13.0 release-note
   pictures show such values: an AirPods-style device name, a sample meeting, three sample file names); whoever shoots must
   **check every tile of every wall PNG** and hide a tile in the widget edit mode if it shows anything real.
10. **Nacho Pet tile on the wall.** The wall's Nacho Pet tile carries a sign-in button ("나초 계정으로 로그인", no account shown). The brief forbids
    login screens and pet conversations in the video; a button on a tile is neither, but a boss may want the tile cropped out of S02 and S03 anyway. The wall also shows the experimental Computer Use tile (README: "not yet tried on a real Mac"), which the video does not describe. Decide at review.
11. **Where the pictures can come from.** The v0.13.0 window renders in `docs/release-notes/assets/v0.13.0/` (wall with edit drawer, Calendar Clock panel in
    Settings, Shortcuts and Permissions tabs, dark and light) are offscreen renders from the macOS CI runner with made-up data, 1210 x 770 (1x),
    and already match S03. They are what the dry run uses as stand-ins and could be used in the final cut without a Mac. What is missing is the plain
    wall with no panel and no edit drawer (S02, S03 start), and 2x resolution. `ctl` on a Mac fixes both; no new `ctl` command is needed for any scene except the pet in the corner (item 4).

## Changes in the final cut (NACHO-977)
Decided with the capture review (NACHO-976); the first plan above stays in the file for the record.
- **S03 shows Calendar Clock, not Window Snap.** The wall and panel pictures (c02 to c05) are v0.13.0 CI off-screen renders, and the
  panel tabs in them (Shortcuts, Permissions) belong to Calendar Clock. Cues 6 and 7 were reworded to what the pictures show.
- **Korean text.** The wall and panel pictures are partly Korean; S02 says so on screen ("Window text is in Korean"), the captions carry the meaning.
- **Quick panel (c21, c22)** are washed out in the source pictures. c21 is cropped above its "N running" header and below the Nacho Pet row (the Computer Use pin is not shown),
  its grey pixels are re-levelled and c22 gets a brightness/contrast filter (`lift` and `filter` in `timeline.json`, no other change to the pixels).
  c21 shows a real switch state of the capture Mac (green dots), not sample data; the end card says so.
- **Combos (c20)** is a tall page, scrolled instead of panned (`scroll` in `timeline.json`).
- **S06 (Nacho Pet)** is a drawn card with the mascot art, labelled "Illustration, not a capture".
- No number of gadgets is named anywhere (README says thirteen plus two, the release notes say fifteen: boss decision pending).
- Voice-over: none (subtitle-only, as recommended in `TTS-AND-AUDIO.md`). Music: none.
