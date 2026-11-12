#!/bin/bash
# Packages dist.noindex/UpdateWorkbench.app as a drag-to-Applications DMG, a ZIP and SHA256SUMS in release/.
set -euo pipefail
cd "$(dirname "$0")"
APP=dist.noindex/UpdateWorkbench.app
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
# The DMG staging copy lives in a temporary .noindex folder so Spotlight never lists it.
OUT=release; STAGE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/uw-dmg.XXXXXX")"; STAGE="$STAGE_ROOT/stage.noindex"
trap 'rm -rf "$STAGE_ROOT"' EXIT
mkdir -p "$STAGE"
mkdir -p "$OUT"
DMG="$OUT/UpdateWorkbench-$VERSION.dmg"; ZIP="$OUT/UpdateWorkbench-$VERSION.zip"
rm -f "$DMG" "$ZIP" "$OUT/SHA256SUMS"
/usr/bin/ditto "$APP" "$STAGE/Update Workbench.app"
ln -s /Applications "$STAGE/Applications"
/usr/bin/hdiutil create -quiet -volname "Update Workbench" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
/usr/bin/ditto -c -k --norsrc --noextattr --noqtn --keepParent "$STAGE/Update Workbench.app" "$ZIP"
(cd "$OUT" && /usr/bin/shasum -a 256 "$(basename "$DMG")" "$(basename "$ZIP")" > SHA256SUMS)
cat "$OUT/SHA256SUMS"
