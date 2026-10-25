# Nacho Combo (MVP)

One macOS app with three modules, each switched on or off on its own. No third-party apps, code or brands are used.

| Module | What it does | Permission |
|---|---|---|
| Menu Bar Organizer | Collapses / expands the icons left of a divider ([constraints](docs/MENUBAR-CONSTRAINTS.md)) | None |
| System Monitor | CPU, memory, disk, network and sensor menu bar items with detail panels (every 2 s, [below](#system-monitor)) | None |
| Window Snap | ⌃⌥← / ⌃⌥→ / ⌃⌥↩ for left half, right half, maximize | Accessibility |

- Target: macOS 12 (Monterey) or later, Swift 5.5+ (Package.swift `platforms: .macOS(.v12)`).
- Settings: `~/Library/Application Support/NachoCombo/settings.json` (everything is OFF by default).
- OFF contract: a module's `stop()` releases all of its timers, hotkeys and status items. Counters for checking this are written to `state.json` in the same folder.
- Permission denied: when Window Snap is on without permission, nothing is registered and a notice (open settings button, check again) is shown. It is never worked around.

## System Monitor
Each metric group (CPU, memory, disk, network, sensors) gets its own menu bar item; clicking one opens a detail panel.
Pick the items to show in the settings window. A panel closes on an outside click, Esc or a Space change.
Resting the pointer on a panel card outlines the card in blue and opens a flyout with a larger chart left of the panel (right of it when the screen has no room).
Move the pointer into the flyout to change its range or metric (⌃⌄ next to the title); it closes once the pointer leaves both the card and the flyout.

| Panel | Contents |
|---|---|
| CPU | User / system history, per-core gauges (efficiency cores pink, performance cores blue), top processes, GPU (utilization, memory, temperature, clock), load average, uptime |
| Memory | Pressure and usage rings (app, wired, compressed), top processes, page ins / outs, swap used |
| Disk | Startup volume usage, read / write rates and history, peaks in the period, totals since boot, per-process R / W |
| Network | Upload / download rates and history, interfaces, public IP (opt-in), local IPs, per-process ↑ / ↓ |
| Sensors | CPU / GPU temperature and clock, fans, temperature sensor list, total power history |

| Card | Flyout |
|---|---|
| CPU chart | User / system history with period averages |
| Cores | Performance / efficiency core average history |
| GPU | Processor / memory / temperature / clock history |
| Load average | 1 / 5 / 15 min history |
| Memory rings | Memory pressure / usage history |
| App, wired, compressed | Stacked history by category |
| Page ins / outs, swap | Paging rates, swap used history |
| Startup volume | Used / purgeable / free ring, SSD health (NVMe SMART endurance) and temperature |
| Disk activity | Read / write history, peaks in the period, totals since boot |
| Network | Upload / download history, peaks in the period |
| Sensor rings, power, fans | CPU / GPU temperature and fan speed, total power, fan speed history |

- Chart ranges: 10 min / 1 hour / 3 hours / 24 hours (chosen per chart and saved in the settings; flyouts are saved separately from the panel charts). History is kept in memory only, for 24 hours, and is cleared on restart.
- Data sources and limits:
  - Public APIs: Mach host statistics (CPU, memory), sysctl (pressure, swap, load), the IOKit registry (disk totals, GPU utilization), getifaddrs and SystemConfiguration (network).
  - Process statistics use `proc_pid_rusage` and count **only processes owned by your account** (macOS refuses root-owned ones). Helper processes are summed per app bundle.
  - Per-process network traffic runs a single `/usr/bin/nettop` snapshot every 2 s, only while the network panel is open, and diffs the results.
  - Temperatures, fans and power come from (undocumented) SMC keys; CPU / GPU clocks from the private IOReport library (dlopen). Anything missing or failing shows "–" and does not affect the rest.
    Per-core temperature names are used only on M1 Pro / M1 Max, where the key layout was checked; other Apple silicon shows the CPU average and maximum. The clock table was verified on M1 Pro.
  - SSD health and temperature come from the NVMe SMART interface in the public header `IOKit/storage/nvme/NVMeSMARTLibExternal.h` (no permission needed). Health = 100 − endurance used. It is read only while the disk panel is open, once a minute.
  - The public IP is an external request (`https://www.cloudflare.com/cdn-cgi/trace`), so it is OFF by default. It is requested only from the panel's "Look Up" button or when auto lookup is turned on in the settings.

## Install (release)
- Download `NachoCombo-<version>-macos.zip` or `.dmg` and `SHA256SUMS.txt` from [Releases](../../releases). Universal binary (Apple Silicon + Intel), macOS 12 or later.
- Verify: `shasum -a 256 -c SHA256SUMS.txt`
- **Signing limits: the app is ad-hoc signed, without an Apple Developer ID signature or notarization.** Gatekeeper blocks the first launch.
  Right-click the app → Open → Open, or allow it in System Settings ▸ Privacy & Security. Updating or rebuilding changes the code signature,
  so Window Snap's Accessibility permission has to be granted again.
- Releases are created automatically: pushing a tag like `v0.1.0` makes GitHub Actions (`.github/workflows/release.yml`) build and package the app on a macOS runner.

## Build / test
- macOS: `scripts/build-app.sh` → `build/NachoCombo.app` (ad-hoc signed). Run it with `open build/NachoCombo.app`.
  Universal build `UNIVERSAL=1`, version `VERSION=x.y.z`, packaging `VERSION=x.y.z scripts/package.sh` (zip, dmg, SHA256SUMS → `dist/`).
- Core unit tests (Linux and macOS): `swift test` (on Linux the manifest leaves out the AppKit target).
- Debug control channel: start with `NachoCombo --debug-ctl`, then `NachoCombo ctl set systemMonitor off|on`, `ctl collapse on|off`,
  `ctl snap left|right|maximize`, `ctl dump`, `ctl quit`. Prints the state JSON. Not meant for release use.
  - System Monitor: `ctl monitor show cpu|memory|disk|network|sensors`, `ctl monitor hide`, `ctl monitor items cpu,network`,
    `ctl monitor range <cpu|disk|network|power|flyout.*> <600|3600|10800|86400>`, `ctl monitor publicip`,
    `ctl monitor snapshot <item> <file.png> [light]` (renders a panel as PNG), `ctl monitor menubar <file.png> [light]`, `ctl settings snapshot <file.png>`.
  - Flyouts: `ctl monitor hover <n>` (opens the flyout of the open panel's n-th hover card), `ctl monitor flyout <item> <n> <file.png> [light]` (renders the panel and the flyout side by side as PNG).

## License
[MIT](LICENSE) © 2026 Mafianacho. The "Nacho Combo" name and logo are not covered by this license.
