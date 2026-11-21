#!/bin/bash
# Packages dist.noindex/UpdateWorkbench.app as a drag-to-Applications DMG, a ZIP, SHA256SUMS and appcast.xml in release/.
# The ZIP is signed with the release key (tools/release-key.swift); appcast.xml is the feed installed copies check.
# Optional: RELEASE_NOTES=path/to/notes.md puts plain release notes into the feed.
set -euo pipefail
cd "$(dirname "$0")"
source scripts/macos-notary.sh
APP=dist.noindex/UpdateWorkbench.app
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")"
# The DMG staging copy lives in a temporary .noindex folder so Spotlight never lists it.
OUT=release; STAGE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/uw-dmg.XXXXXX")"; STAGE="$STAGE_ROOT/stage.noindex"
trap 'rm -rf "$STAGE_ROOT"' EXIT
mkdir -p "$STAGE"
mkdir -p "$OUT"
DMG="$OUT/UpdateWorkbench-$VERSION.dmg"; ZIP="$OUT/UpdateWorkbench-$VERSION.zip"
rm -f "$DMG" "$ZIP" "$OUT/SHA256SUMS" "$OUT/appcast.xml"
/usr/bin/ditto "$APP" "$STAGE/Update Workbench.app"
sign_app="$STAGE/Update Workbench.app"
codesign --force --options runtime --timestamp --sign "$MACOS_SIGN_IDENTITY" "$sign_app"
notarize_app "$sign_app" "$STAGE_ROOT/notary.zip"
ln -s /Applications "$STAGE/Applications"
/usr/bin/hdiutil create -quiet -volname "Update Workbench" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
notarize_dmg "$DMG"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$sign_app" "$ZIP"
ditto -x -k "$ZIP" "$STAGE_ROOT/unzipped"
verify_signature "$STAGE_ROOT/unzipped/Update Workbench.app"
xcrun stapler validate "$STAGE_ROOT/unzipped/Update Workbench.app"
(cd "$OUT" && /usr/bin/shasum -a 256 "$(basename "$DMG")" "$(basename "$ZIP")" > SHA256SUMS)
# Sign the ZIP and check the signature against the key built into the app before publishing anything.
SIGNATURE="$(xcrun swift tools/release-key.swift sign "$ZIP")"
[ "$(xcrun swift tools/release-key.swift public-key)" = "$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$APP/Contents/Info.plist")" ] \
    || { echo "The app's SUPublicEDKey doesn't match the release key in the Keychain." >&2; exit 1; }
NOTES=""
[ -n "${RELEASE_NOTES:-}" ] && NOTES="$(sed 's/]]>/]]]]><![CDATA[>/g' "$RELEASE_NOTES")"
cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel>
<title>Update Workbench</title>
<item>
<title>Update Workbench $VERSION</title>
<pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
<sparkle:version>$BUILD</sparkle:version>
<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
<description><![CDATA[$NOTES]]></description>
<enclosure url="https://github.com/Kasakir-AI/UpdateWorkbench/releases/download/v$VERSION/$(basename "$ZIP")" length="$(stat -f %z "$ZIP")" type="application/octet-stream" sparkle:edSignature="$SIGNATURE"/>
</item>
</channel>
</rss>
XML
cat "$OUT/SHA256SUMS"
echo "Signed $(basename "$ZIP") and wrote $OUT/appcast.xml"
