# Privacy check: {{video}}

Checked on {{date}}. Frames are taken every {{interval}} s: **{{frames}} frames** (a video of {{duration}} s needs at
least {{needed}}). The frames and contact sheets are in `{{frames_dir}}`; the numbers in the "automatic" rows below come
from the scripts in this folder, the "by eye" rows must be filled in by the person who looked at every frame.

Rules (NACHO-975): no real account, e-mail or name; no real file names or folder paths; no clipboard content; no real
calendar entries; no other app's window; no notification; no Wi-Fi or device name; no Nacho Pet conversation, login
screen or token; no server user name, host name or home path anywhere (screen, metadata, files).

## Automatic

| Item | Result | Evidence |
|---|---|---|
| Frames extracted | {{frames}} frames every {{interval}} s | `{{frames_dir}}/f_0001.png` ... |
| Container and stream metadata | {{metadata_result}} | `ffprobe.json`, `metadata.txt` |
| Forbidden strings in the video / GIF bytes | {{scan_media_result}} | `scan-media.txt` |
| Forbidden strings in the source material (scene files, timeline, captions, scripts, capture PNGs) | {{scan_source_result}} | `scan-source.txt` |

## By eye (every frame, both contact sheets and any full-size frame in doubt)

Mark each row `PASS`, `FAIL` (then fix the capture and rebuild) or `N/A`, and write what you looked at.

| Item | Result | What was looked at |
|---|---|---|
| Account, e-mail address, personal name | ☐ | |
| File names and folder paths (shelf rows, recents, titles, Disk Map labels) | ☐ | |
| Clipboard content (Clipboard History rows) | ☐ | |
| Calendar events (Calendar Clock) | ☐ | |
| Other apps' windows or documents behind a gadget picture | ☐ | |
| Notifications and banners | ☐ | |
| Wi-Fi name, device name, host name, IP address (System Monitor, Device Control) | ☐ | |
| Menu bar: only Nacho Combo's own items, no other app icons, no clock with a real date | ☐ | |
| Nacho Pet: mascot only, no chat text, no sign-in screen, no token | ☐ | |
| Frames that show the app's own text in Korean: nothing personal in them | ☐ | |

Reviewer: ______  Date: ______  Result: ☐ clean, ready for boss review  ☐ needs a new capture
