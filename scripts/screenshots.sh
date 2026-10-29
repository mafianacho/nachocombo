#!/bin/bash
# Regenerates the README screenshots in docs/images from the real app through its debug control channel.
# Everything is rendered by the app's own views; System Monitor pictures use sample numbers (no data from this Mac).
# The gallery windows show the gadgets as they are switched on / off in settings.json at that moment.
# Quits a running Nacho Combo first and leaves the debug instance closed afterwards.
# APP=/path/to/NachoCombo.app (default build/NachoCombo.app)
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${APP:-build/NachoCombo.app}"
BIN="$APP/Contents/MacOS/NachoCombo"
OUT=docs/images
mkdir -p "$OUT"
pkill -x NachoCombo || true
sleep 1
"$BIN" --debug-ctl >/dev/null 2>&1 &
sleep 4
ctl() { "$BIN" ctl "$@" >/dev/null; }
# crop <file> <x> <y> <width> <height> <out> (points; the PNGs are 2x). sips ignores an offset of 0 and crops from the
# middle instead, so 0 becomes 1 pixel.
crop() {
  local y=$(($3 * 2)) x=$(($2 * 2))
  sips -c $(($5 * 2)) $(($4 * 2)) --cropOffset $((y > 0 ? y : 1)) $((x > 0 ? x : 1)) "$OUT/$1" --out "$OUT/$6" >/dev/null
}

ctl appearance dark
ctl gallery sample on
for pair in menuBar:menu-bar-organizer systemMonitor:system-monitor windowSnap:window-snap \
            fileShelf:file-shelf captureFloat:capture-float focusDim:focus-dim keepAwake:keep-awake \
            clipboard:clipboard-history deviceControl:device-control appSwitch:app-switch mouseTune:mouse-tune \
            calendarClock:calendar-clock; do
  ctl gallery preview "${pair%%:*}" "$PWD/$OUT/${pair##*:}.png"
done
ctl monitor menubar "$PWD/$OUT/monitor-menu-bar.png" sample
ctl monitor flyout cpu 0 "$PWD/$OUT/monitor-cpu-flyout.png" sample
ctl monitor flyout memory 0 "$PWD/$OUT/monitor-memory-flyout.png" sample
ctl monitor snapshot battery "$PWD/$OUT/monitor-battery.png" sample

ctl gallery page home; sleep 1
ctl settings snapshot "$PWD/$OUT/gallery-dark.png"
ctl gallery page windowSnap; ctl gallery tab settings; sleep 1
ctl gallery detail "$PWD/$OUT/detail-window-snap.png"
ctl gallery tab shortcuts; sleep 1
ctl gallery content "$PWD/$OUT/detail-window-snap-shortcuts.png"
ctl gallery page permissions; sleep 1
ctl gallery detail "$PWD/$OUT/permissions.png"
ctl combo select desk; sleep 1
ctl gallery detail "$PWD/$OUT/combos.png"
ctl gallery page captureFloat; ctl gallery tab overview; sleep 1
ctl gallery content "$PWD/$OUT/detail-capture-float.png"
ctl panel list; sleep 1
ctl snapshot panel "$PWD/$OUT/quick-panel.png"
ctl panel tool captureFloat; sleep 1
ctl snapshot panel "$PWD/$OUT/quick-panel-capture-float.png"
ctl panel combos; sleep 1
ctl snapshot panel "$PWD/$OUT/quick-panel-combos.png"
ctl panel close
ctl appearance light
ctl gallery page windowSnap; ctl gallery tab settings; sleep 1
ctl settings snapshot "$PWD/$OUT/gallery-light.png"
ctl gallery page home
ctl gallery sample off
ctl appearance system
ctl quit || true

# Sections of the pages (points; the PNGs are 2x). The Capture Float crop keeps its last 560 pt: Keys and Gestures and
# Good to Know.
crop detail-window-snap.png 0 0 560 760 detail-window-snap-top.png
height=$(($(sips -g pixelHeight "$OUT/detail-capture-float.png" | awk '/pixelHeight/ {print $2}') / 2))
width=$(($(sips -g pixelWidth "$OUT/detail-capture-float.png" | awk '/pixelWidth/ {print $2}') / 2))
crop detail-capture-float.png 0 $((height - 560)) "$width" 560 detail-capture-float-keys.png
rm "$OUT/detail-window-snap.png" "$OUT/detail-capture-float.png"
rm -f "$OUT/detail-window-snap-permissions.png"
sips -Z 256 Resources/AppIcon.png --out "$OUT/app-icon.png" >/dev/null
echo "screenshots written to $OUT"
