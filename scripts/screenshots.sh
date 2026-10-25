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
# crop <file> <x> <y> <width> <height> (points; the PNGs are 2x)
crop() { sips -c $(($5 * 2)) $(($4 * 2)) --cropOffset $(($3 * 2)) $(($2 * 2)) "$OUT/$1" --out "$OUT/$6" >/dev/null; }

ctl appearance dark
ctl gallery sample on
for pair in menuBar:menu-bar-organizer systemMonitor:system-monitor windowSnap:window-snap \
            fileShelf:file-shelf captureFloat:capture-float focusDim:focus-dim; do
  ctl gallery preview "${pair%%:*}" "$PWD/$OUT/${pair##*:}.png"
done
ctl monitor menubar "$PWD/$OUT/monitor-menu-bar.png" sample
ctl monitor flyout cpu 0 "$PWD/$OUT/monitor-cpu-flyout.png" sample
ctl monitor flyout memory 0 "$PWD/$OUT/monitor-memory-flyout.png" sample
ctl monitor snapshot battery "$PWD/$OUT/monitor-battery.png" sample

ctl gallery select systemMonitor; sleep 1
ctl settings snapshot "$PWD/$OUT/gallery-dark.png"
ctl gallery select windowSnap; sleep 1
ctl gallery detail "$PWD/$OUT/detail-window-snap.png"
ctl gallery select captureFloat; sleep 1
ctl gallery detail "$PWD/$OUT/detail-capture-float.png"
ctl panel list; sleep 1
ctl snapshot panel "$PWD/$OUT/quick-panel.png"
ctl panel tool captureFloat; sleep 1
ctl snapshot panel "$PWD/$OUT/quick-panel-capture-float.png"
ctl panel close
ctl appearance light
ctl gallery select fileShelf; sleep 1
ctl settings snapshot "$PWD/$OUT/gallery-light.png"
ctl gallery sample off
ctl appearance system
ctl quit || true

# Sections of the detail panes (offsets in points; adjust when the pane's content changes).
crop detail-window-snap.png 0 0 448 700 detail-window-snap-top.png
crop detail-window-snap.png 0 1215 448 545 detail-window-snap-shortcuts.png
crop detail-window-snap.png 0 2370 448 540 detail-window-snap-permissions.png
crop detail-capture-float.png 0 1470 448 760 detail-capture-float-keys.png
rm "$OUT/detail-window-snap.png" "$OUT/detail-capture-float.png"
sips -Z 256 Resources/AppIcon.png --out "$OUT/app-icon.png" >/dev/null
echo "screenshots written to $OUT"
