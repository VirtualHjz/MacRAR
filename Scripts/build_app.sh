#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
CONFIG="${1:-release}"
case "$CONFIG" in release|debug) ;; *) echo "Usage: $0 [release|debug]" >&2; exit 2 ;; esac

APP_NAME="MacRAR"
VERSION="1.0.0"
if [[ "$CONFIG" == "debug" ]]; then
    APP_DIR="$ROOT_DIR/dist/$APP_NAME-Debug.app"
else
    APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
fi
CONTENTS="$APP_DIR/Contents"
SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:--}"

echo "== Building $APP_NAME ($CONFIG) =="
swift build -c "$CONFIG" --product "$APP_NAME"
BUILD_BINARY="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"

echo "== Staging application =="
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources/bin" "$CONTENTS/Resources/Licenses"
cp "$BUILD_BINARY" "$CONTENTS/MacOS/$APP_NAME"
cp "$ROOT_DIR/Sources/MacRAR/Resources/bin/7za" "$CONTENTS/Resources/bin/7za"
cp "$ROOT_DIR/build_assets/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
cp "$ROOT_DIR/ThirdParty/unrar/license.txt" "$CONTENTS/Resources/Licenses/UnRAR.txt"
cp "$ROOT_DIR/ThirdParty/p7zip_16.02/DOC/License.txt" "$CONTENTS/Resources/Licenses/p7zip-License.txt"
cp "$ROOT_DIR/ThirdParty/p7zip_16.02/DOC/copying.txt" "$CONTENTS/Resources/Licenses/p7zip-LGPL.txt"
cp "$ROOT_DIR/ThirdParty/p7zip_16.02/DOC/unRarLicense.txt" "$CONTENTS/Resources/Licenses/p7zip-UnRAR.txt"
chmod 755 "$CONTENTS/MacOS/$APP_NAME" "$CONTENTS/Resources/bin/7za"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>com.macrar.app</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSServices</key>
    <array><dict>
        <key>NSMenuItem</key><dict><key>default</key><string>用 MacRAR 解压</string></dict>
        <key>NSMessage</key><string>extractService</string>
        <key>NSSendFileTypes</key><array>
            <string>public.archive</string><string>public.zip-archive</string><string>com.pkware.zip-archive</string>
        </array>
    </dict></array>
    <key>CFBundleDocumentTypes</key>
    <array><dict>
        <key>CFBundleTypeName</key><string>Archive</string>
        <key>CFBundleTypeRole</key><string>Viewer</string>
        <key>LSHandlerRank</key><string>Alternate</string>
        <key>CFBundleTypeExtensions</key><array>
            <string>zip</string><string>rar</string><string>7z</string>
            <string>tar</string><string>gz</string><string>tgz</string>
            <string>bz2</string><string>tbz</string><string>tbz2</string>
            <string>xz</string><string>txz</string><string>lzma</string>
            <string>iso</string><string>cpio</string><string>cab</string><string>deb</string>
        </array>
    </dict></array>
</dict>
</plist>
PLIST

plutil -lint "$CONTENTS/Info.plist"
SIGN_ARGS=(--force --sign "$SIGNING_IDENTITY")
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    SIGN_ARGS+=(--timestamp=none)
else
    SIGN_ARGS+=(--options runtime --timestamp)
fi
codesign "${SIGN_ARGS[@]}" "$CONTENTS/Resources/bin/7za"
codesign "${SIGN_ARGS[@]}" "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

if [[ "$CONFIG" == "release" ]]; then
    DMG="$ROOT_DIR/dist/$APP_NAME-$VERSION-arm64.dmg"
    STAGING="$(mktemp -d)"
    trap 'rm -rf "$STAGING"' EXIT
    ln -s /Applications "$STAGING/Applications"
    cp -R "$APP_DIR" "$STAGING/$APP_NAME.app"
    hdiutil create -quiet -ov -volname "$APP_NAME" -srcfolder "$STAGING" -format UDZO "$DMG"
    hdiutil verify "$DMG"
    shasum -a 256 "$DMG"
    echo "== Packaged: $DMG =="
else
    echo "== Packaged: $APP_DIR =="
fi
