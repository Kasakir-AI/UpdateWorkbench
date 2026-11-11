#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build-cache dist/UpdateWorkbench.app/Contents/MacOS dist/UpdateWorkbench.app/Contents/Resources
# App icon: regenerate only when the generator changes.
ICON_SCRIPT=Resources/AppIcon/make-icon.swift
if [ ! -f .build/AppIcon.icns ] || [ "$ICON_SCRIPT" -nt .build/AppIcon.icns ]; then
    rm -rf .build/AppIcon.iconset
    xcrun swift "$ICON_SCRIPT" .build/AppIcon.iconset Resources/AppIcon/AppIcon-1024.png
    /usr/bin/iconutil -c icns .build/AppIcon.iconset -o .build/AppIcon.icns
fi
cp .build/AppIcon.icns dist/UpdateWorkbench.app/Contents/Resources/AppIcon.icns
export CLANG_MODULE_CACHE_PATH="$PWD/.build-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build-cache"
swift build --configuration release -debug-info-format none --scratch-path "$PWD/.build" --disable-sandbox
BIN_DIR="$(swift build --configuration release --scratch-path "$PWD/.build" --disable-sandbox --show-bin-path)"
cp "$BIN_DIR/UpdateWorkbench" dist/UpdateWorkbench.app/Contents/MacOS/UpdateWorkbench
cat > dist/UpdateWorkbench.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>UpdateWorkbench</string>
<key>CFBundleIdentifier</key><string>local.updateworkbench.app</string>
<key>CFBundleName</key><string>Update Workbench</string>
<key>CFBundleDisplayName</key><string>Update Workbench</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.1</string>
<key>CFBundleVersion</key><string>4</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - dist/UpdateWorkbench.app
printf 'Built %s/dist/UpdateWorkbench.app\n' "$PWD"
