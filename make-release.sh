#!/bin/bash
# Packages dist/UpdateWorkbench.app as a drag-to-Applications DMG, a ZIP and SHA256SUMS in release/.
set -euo pipefail
cd "$(dirname "$0")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' dist/UpdateWorkbench.app/Contents/Info.plist)"
OUT=release; STAGE="$(mktemp -d "${TMPDIR:-/tmp}/uw-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$OUT"
DMG="$OUT/UpdateWorkbench-$VERSION.dmg"; ZIP="$OUT/UpdateWorkbench-$VERSION.zip"
rm -f "$DMG" "$ZIP" "$OUT/SHA256SUMS"
/usr/bin/ditto dist/UpdateWorkbench.app "$STAGE/Update Workbench.app"
ln -s /Applications "$STAGE/Applications"
/usr/bin/hdiutil create -quiet -volname "Update Workbench" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
/usr/bin/ditto -c -k --norsrc --noextattr --noqtn --keepParent "$STAGE/Update Workbench.app" "$ZIP"
(cd "$OUT" && /usr/bin/shasum -a 256 "$(basename "$DMG")" "$(basename "$ZIP")" > SHA256SUMS)
cat "$OUT/SHA256SUMS"
