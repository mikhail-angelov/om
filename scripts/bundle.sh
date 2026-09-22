#!/bin/sh
# Wrap the built editor in a .app so macOS treats it as an application.
#
# A bare SwiftPM executable has no Info.plist, and without one AppKit refuses
# the process a regular activation policy: it runs, no window appears, and
# nothing is written to stderr. The bundle is the whole fix.
set -eu

configuration=${CONFIGURATION:-release}
name=${APP_NAME:-Om}
out=${BUILD_DIR:-build}
root=$(cd "$(dirname "$0")/.." && pwd)

binary=$(swift build -c "$configuration" --package-path "$root" --show-bin-path)/OmEditor
[ -x "$binary" ] || { echo "no $binary — run make build first"; exit 1; }

version=$(git -C "$root" describe --tags --always --dirty 2>/dev/null || echo 0.0.0)
app=$root/$out/$name.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/$name"

cat >"$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>$name</string>
	<key>CFBundleDisplayName</key><string>$name</string>
	<key>CFBundleExecutable</key><string>$name</string>
	<key>CFBundleIdentifier</key><string>app.om.editor</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$version</string>
	<key>CFBundleVersion</key><string>$version</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough for the app to launch locally. A distributed build
# needs a Developer ID identity in CODESIGN_IDENTITY.
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$app" >/dev/null 2>&1 || true
echo "$app"
