#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="WeaponShift"
BUNDLE_ID="com.weaponshift.prototype"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

cd "$ROOT_DIR"
pkill -x "$APP_NAME" >/dev/null 2>&1 || true

if [[ "$MODE" == "--playtest" || "$MODE" == "playtest" ]]; then
  swift build >&2
else
  swift build
fi
BUILD_DIR="$(swift build --show-bin-path)"
BUILD_BINARY="$BUILD_DIR/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
mkdir -p "$APP_CONTENTS/Resources"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
find "$BUILD_DIR" -maxdepth 1 -type d \( -name "*.resources" -o -name "*.bundle" \) -exec cp -R {} "$APP_CONTENTS/Resources/" \;

RESOURCE_BUNDLE="$APP_CONTENTS/Resources/${APP_NAME}_${APP_NAME}.bundle"
REQUIRED_RESOURCES=(
  ArcherSprite.png
  BossSprite.png
  BossBolt.png
  BroadswordPlayerSprite.png
  ChainPlayerSprite.png
  DaggerPlayerSprite.png
  DungeonBackplate.png
  ExploderSprite.png
  ArrowProjectile.png
  HUDMapFrame.png
  HUDModalPanel.png
  HUDSlot.png
  HUDSlotSelected.png
  HUDVitalsFrame.png
  PlayerSprite.png
  SkeletonSprite.png
  StoneLedgeLeft.png
  StoneLedgeRight.png
  StoneLedgeTile.png
  TitleAttract.png
  WhipSlashSprite.png
)

for asset in "${REQUIRED_RESOURCES[@]}"; do
  if [[ ! -s "$RESOURCE_BUNDLE/$asset" ]]; then
    echo "missing required resource: $asset" >&2
    exit 1
  fi
done

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  --playtest|playtest)
    RUN_DIR="$(mktemp -d "$DIST_DIR/playtest.XXXXXX")"
    REPORT="$RUN_DIR/playtest-report.json"
    PLAYTEST_SNAPSHOT="$RUN_DIR/playtest-final.png"
    LOG="$RUN_DIR/playtest.log"
    STABLE_REPORT="$DIST_DIR/playtest-report.json"
    STABLE_SNAPSHOT="$DIST_DIR/playtest-final.png"
    rm -f "$STABLE_REPORT"
    rm -f "$STABLE_SNAPSHOT"
    "$APP_BINARY" --playtest --playtest-report "$REPORT" --playtest-snapshot "$PLAYTEST_SNAPSHOT" >"$LOG" 2>&1 &
    APP_PID="$!"
    for attempt in $(seq 1 150); do
      if [[ -f "$REPORT" ]]; then
        cp "$REPORT" "$STABLE_REPORT"
        if [[ -s "$PLAYTEST_SNAPSHOT" ]]; then
          cp "$PLAYTEST_SNAPSHOT" "$STABLE_SNAPSHOT"
        fi
        cat "$STABLE_REPORT"
        exit 0
      fi
      if [[ "$attempt" -gt 3 ]] && ! kill -0 "$APP_PID" >/dev/null 2>&1; then
        tail -80 "$LOG" >&2 || true
        exit 1
      fi
      sleep 1
    done
    kill "$APP_PID" >/dev/null 2>&1 || true
    tail -80 "$LOG" >&2 || true
    echo "playtest timed out" >&2
    exit 1
    ;;
  --snapshot|snapshot)
    SNAPSHOT_MODE="${2:-combat}"
    SNAPSHOT="$DIST_DIR/snapshot-$SNAPSHOT_MODE.png"
    rm -f "$SNAPSHOT"
    "$APP_BINARY" --snapshot "$SNAPSHOT_MODE" --snapshot-path "$SNAPSHOT"
    test -s "$SNAPSHOT"
    echo "$SNAPSHOT"
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--playtest|--snapshot [title|combat|boss]]" >&2
    exit 2
    ;;
esac
