# Narration script (optional voice-over)

The default delivery is a **subtitle-only** video (see [TTS-AND-AUDIO.md](TTS-AND-AUDIO.md)). This is the text a voice-over
would read: the same words as `captions.en.srt`, cue by cue, 175 words in 75 seconds (about 140 words a minute, under the
150 ceiling; the speech sits inside each cue's on-screen window). `tools/check-captions.mjs` fails when a line here differs
from its caption or the pace goes over 150.

Format: `<cue number>. <caption start> — <text>`. Pauses between cues are the silence in the video; nothing is added
that the captions do not say.

## Hook (0:00 – 0:06)
1. 00:00:00,600 — One menu bar app with many small tools.
2. 00:00:03,400 — Switch on only the ones you want.

## The widget window (0:06 – 0:12)
3. 00:00:06,300 — Open the widget window: each gadget is a widget.
4. 00:00:09,800 — Each one switches on or off alone.

## The settings panel on the right (0:12 – 0:24)
5. 00:00:12,800 — Click a widget: its settings panel slides in on the right.
6. 00:00:16,700 — Three tabs: Settings, Shortcuts, Permissions.
7. 00:00:20,200 — Permissions: the clock needs none, Calendars is optional.

## Six gadgets (0:24 – 0:50)
8. 00:00:24,200 — Window Snap: 24 commands, or drag a window to an edge.
9. 00:00:28,600 — System Monitor: CPU, memory, disk, network and more in the menu bar.
10. 00:00:33,500 — Capture Float keeps a capture floating over other windows.
11. 00:00:37,600 — File Shelf: shake while dragging and a floating shelf appears.
12. 00:00:41,800 — Focus Dim darkens everything behind the window you use.
13. 00:00:45,600 — Disk Map shows what fills a disk, as a sunburst or as blocks.

## Combos and the quick panel (0:50 – 1:02)
14. 00:00:50,300 — Order a combo: a few gadgets switch on together for the way you work.
15. 00:00:56,700 — The menu bar quick panel lists the tools, their status and controls.

## Nacho Pet (1:02 – 1:07)
16. 00:01:02,300 — Nacho Pet is the Nacho character in the corner of your screen.

## Download (1:07 – 1:15)
17. 00:01:07,300 — Free and open source (MIT) for macOS 12 or later.
18. 00:01:11,000 — Get it from GitHub Releases.

## Read-aloud notes
- Say "Nacho Combo" as two words, "MIT" as the letters M-I-T, "macOS twelve".
- The web address and the small print on the last card (the MIT licence covers the source code only; the Nacho artwork,
  icon and names are not open source; the screens are rendered by the app itself) are on screen only. If a voice-over
  is ever used, add the second sentence of the small print to the narration and to the captions, in the same change.
