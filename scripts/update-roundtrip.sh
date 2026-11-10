#!/bin/bash
# Real round trip of automatic updates: tools/mock-server/releases.mjs plays GitHub Releases, nacho-update-cli plays
# the app's lifecycle (launch / scheduled check / quit) on the same UpdateStore the app uses, against fake app bundles.
# Checks: background download + verification, swap at quit, at most 2 kept copies (waiting + previous), older copies
# deleted, automatic rollback after two unhealthy launches, the rolled-back version skipped, a corrupt release refused,
# swap at the next launch when quit did not, manual rollback, interrupted download cleaned up.
# On macOS the fake apps are ad-hoc code signed and checked with codesign (plus a tampered one that must be refused);
# on Linux there is no codesign, so the signature step is skipped (--skip-signature).
# Output: build/update-roundtrip/*.log and summary.txt. Exit 0 only if every check passes. Needs Swift and Node 18+
# (Linux: zip/unzip too).
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=build/update-roundtrip
rm -rf "$OUT"; mkdir -p "$OUT/feed/files" "$OUT/apps"
PORT="${UPDATE_PORT:-8793}"
FEED="http://127.0.0.1:$PORT/repos/mafianacho/nachocombo/releases/latest"
swift build --product nacho-update-cli 2>&1 | tail -1
CLI="$(swift build --show-bin-path)/nacho-update-cli"
node tools/mock-server/releases.mjs --port "$PORT" --dir "$OUT/feed" > "$OUT/feed.log" &
SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.2; done

MAC=0; [ "$(uname)" = Darwin ] && MAC=1
SIGN=(); [ $MAC = 1 ] || SIGN=(--skip-signature)
TARGET="$OUT/Applications/NachoCombo.app"
ROOT="$OUT/Support/Updates"
fail=0
check() { if [ "$2" -eq 0 ]; then echo "PASS $1" | tee -a "$OUT/summary.txt"; else echo "FAIL $1" | tee -a "$OUT/summary.txt"; fail=1; fi; }
has() { grep -q -- "$1" "$OUT/$2.log"; echo $?; }

make_app() { # version dir [bundle id]
  local app="$2/NachoCombo.app"
  mkdir -p "$app/Contents/MacOS"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>${3:-com.mafianacho.nachocombo}</string>
<key>CFBundleShortVersionString</key><string>$1</string>
<key>CFBundleExecutable</key><string>NachoCombo</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
  if [ $MAC = 1 ]; then cp /usr/bin/true "$app/Contents/MacOS/NachoCombo"; codesign --force --sign - "$app" 2>/dev/null
  else printf 'fake %s\n' "$1" > "$app/Contents/MacOS/NachoCombo"; fi
}

publish() { # version [corrupt|tampered]
  local v="$1" dir="$OUT/apps/$1" zip="NachoCombo-$1-macos.zip"
  rm -rf "$dir"; mkdir -p "$dir"; make_app "$v" "$dir"
  if [ "${2:-}" = tampered ]; then sed -i.bak 's/APPL/APPX/' "$dir/NachoCombo.app/Contents/Info.plist"; rm -f "$dir/NachoCombo.app/Contents/Info.plist.bak"; fi
  rm -f "$OUT/feed/files/$zip"
  if [ $MAC = 1 ]; then (cd "$dir" && ditto -c -k --keepParent NachoCombo.app "$OLDPWD/$OUT/feed/files/$zip")
  else (cd "$dir" && zip -qr "$OLDPWD/$OUT/feed/files/$zip" NachoCombo.app); fi
  local sum; sum=$( (sha256sum "$OUT/feed/files/$zip" 2>/dev/null || shasum -a 256 "$OUT/feed/files/$zip") | cut -c1-64)
  [ "${2:-}" = corrupt ] && sum=$(printf '0%.0s' $(seq 1 64))
  echo "$sum  $zip" > "$OUT/feed/files/SHA256SUMS.txt"
  cat > "$OUT/feed/latest.json" <<JSON
{"tag_name":"v$v","name":"Nacho Combo $v","draft":false,"prerelease":false,"html_url":"https://example.invalid/v$v","body":"test",
 "assets":[{"name":"$zip","size":1,"browser_download_url":"http://127.0.0.1:$PORT/files/$zip"},
           {"name":"SHA256SUMS.txt","size":1,"browser_download_url":"http://127.0.0.1:$PORT/files/SHA256SUMS.txt"}]}
JSON
}

cli() { local name="$1"; shift; "$CLI" "$@" --root "$ROOT" --target "$TARGET" --feed "$FEED" "${SIGN[@]}" > "$OUT/$name.log" 2>&1; echo "rc=$?" >> "$OUT/$name.log"; }
apps_kept() { find "$ROOT" -name NachoCombo.app -maxdepth 2 2>/dev/null | wc -l | tr -d ' '; }
beside() { ls -A "$OUT/Applications" | tr '\n' ' '; }

mkdir -p "$OUT/Applications"; make_app 0.5.0 "$OUT/Applications"

publish 0.5.1
cli 01-check check
cli 01-status status
check "check: 0.5.1 downloaded, verified and waiting; running copy untouched" $(( $(has 'staged 0.5.1' 01-check) + $(has 'installed=0.5.0 staged=0.5.1 previous=- kept=1' 01-status) ))
cli 02-quit quit
check "quit: 0.5.1 swapped in, 0.5.0 kept as the only previous copy, nothing left beside the app" $(( $(has 'quit: applied 0.5.1' 02-quit) + $(has 'installed=0.5.1 staged=- previous=0.5.0 kept=1' 02-quit) )) ; [ "$(beside)" = "NachoCombo.app " ]; check "  Applications holds only NachoCombo.app ($(beside))" $?
cli 03-launch launch
check "launch: first start of 0.5.1 is healthy, update notice shown once" $(( $(has 'healthy 0.5.1' 03-launch) + $(has 'notice updated(to: "0.5.1")' 03-launch) + $(has 'trial=-' 03-launch) ))

publish 0.5.2
cli 04-check check
check "at most 2 kept copies: waiting 0.5.2 + previous 0.5.0 (kept=$(apps_kept))" $(( $(has 'staged=0.5.2 previous=0.5.0 kept=2' 04-check) ))
[ "$(apps_kept)" -le 2 ]; check "  on disk: $(apps_kept) app copies in the update folder" $?
cli 05-quit quit
check "quit: 0.5.2 in, previous is now 0.5.1, 0.5.0 deleted" $(( $(has 'installed=0.5.2 staged=- previous=0.5.1 kept=1' 05-quit) ))
[ -z "$(grep -rl '0.5.0' "$ROOT" 2>/dev/null)" ]; check "  no file of 0.5.0 left in the update folder" $?

cli 06-crash1 launch --crash
cli 07-crash2 launch --crash
cli 08-recover launch
check "two launches of 0.5.2 die before healthy -> third launch rolls back to 0.5.1" $(( $(has 'started=1' 06-crash1) + $(has 'started=2' 07-crash2) + $(has 'rolled back to 0.5.1' 08-recover) ))
cli 09-after status
check "after the automatic rollback: 0.5.1 installed, 0.5.2 deleted and skipped" $(( $(has 'installed=0.5.1 staged=- previous=- kept=0 skipped=0.5.2' 09-after) ))
cli 10-skip check
check "the rolled-back 0.5.2 is not downloaded again" $(( $(has 'ignored (0.5.2 was rolled back on this Mac)' 10-skip) ))

publish 0.5.3 corrupt
cli 11-corrupt check
check "a release whose zip does not match SHA256SUMS.txt is refused, nothing kept" $(( $(has 'does not match SHA256SUMS.txt' 11-corrupt) + $(has 'staged=-' 11-corrupt) ))
[ ! -e "$ROOT/download" ]; check "  no download leftovers" $?
if [ $MAC = 1 ]; then
  publish 0.5.3 tampered
  cli 12-tampered check
  check "macOS: a release changed after signing fails codesign and is refused" $(( $(has 'code signature does not verify' 12-tampered) ))
fi

publish 0.5.3
cli 13-check check
# The app was killed (shutdown) before quitting normally: the next launch swaps first.
cli 14-launch launch
check "not swapped at quit -> next launch swaps 0.5.3 in first" $(( $(has 'update 0.5.3 is waiting, swapping before start' 14-launch) + $(has 'installed=0.5.3 staged=- previous=0.5.1' 14-launch) ))
cli 15-launch launch
cli 16-rollback rollback
check "manual 'Revert to Previous Version': back to 0.5.1, 0.5.3 skipped" $(( $(has 'rollback: back to 0.5.1' 16-rollback) + $(has 'installed=0.5.1 staged=- previous=- kept=0 skipped=0.5.2,0.5.3' 16-rollback) ))

mkdir -p "$ROOT/download/unpacked"; echo half > "$ROOT/download/NachoCombo-0.5.4-macos.zip"; echo x > "$ROOT/junk.tmp"
mkdir -p "$OUT/Applications/.NachoCombo-update-old.app"
cli 17-tidy launch
[ ! -e "$ROOT/download" ] && [ ! -e "$ROOT/junk.tmp" ] && [ ! -e "$OUT/Applications/.NachoCombo-update-old.app" ]
check "launch removes an interrupted download, stray files and a half-done swap" $?

echo "---- summary ----"; cat "$OUT/summary.txt"
exit $fail
