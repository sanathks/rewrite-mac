#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="Rewrite"
BUILD_DIR="$PROJECT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

ARCH_FLAGS=""
for arch in "$@"; do
    ARCH_FLAGS="$ARCH_FLAGS --arch $arch"
done

echo "Building $APP_NAME..."
cd "$PROJECT_DIR"

swift build -c release $ARCH_FLAGS

echo "Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Find the built binary — location varies by Swift version and flags
BINARY=""
for candidate in \
    "$PROJECT_DIR/.build/apple/Products/Release/$APP_NAME" \
    "$PROJECT_DIR/.build/release/$APP_NAME" \
    "$PROJECT_DIR/.build/arm64-apple-macosx/release/$APP_NAME" \
    "$PROJECT_DIR/.build/x86_64-apple-macosx/release/$APP_NAME"; do
    if [ -f "$candidate" ]; then
        BINARY="$candidate"
        break
    fi
done

if [ -z "$BINARY" ]; then
    echo "ERROR: Could not find built binary. Contents of .build:"
    find "$PROJECT_DIR/.build" -name "$APP_NAME" -type f 2>/dev/null || true
    exit 1
fi

cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp "$PROJECT_DIR/Resources/icon.png" "$APP_BUNDLE/Contents/Resources/icon.png"
echo "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Use dev certificate if available, otherwise ad-hoc
SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Rewrite Development" | head -1 | awk -F'"' '{print $2}' || true)
if [ -n "$SIGN_IDENTITY" ]; then
    codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
else
    codesign --force --deep --sign - "$APP_BUNDLE"
fi
echo "App bundle created: $APP_BUNDLE"

# Determine DMG filename based on architecture
if [ $# -eq 1 ]; then
    case "$1" in
        arm64) DMG_SUFFIX="-apple-silicon" ;;
        x86_64) DMG_SUFFIX="-intel" ;;
        *) DMG_SUFFIX="-$1" ;;
    esac
else
    DMG_SUFFIX=""
fi

# Create DMG
DMG_PATH="$BUILD_DIR/${APP_NAME}${DMG_SUFFIX}.dmg"
DMG_TEMP="$BUILD_DIR/dmg_staging"
rm -rf "$DMG_TEMP" "$DMG_PATH"
mkdir -p "$DMG_TEMP"
cp -R "$APP_BUNDLE" "$DMG_TEMP/"
ln -s /Applications "$DMG_TEMP/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_TEMP" -ov -format UDZO "$DMG_PATH"
rm -rf "$DMG_TEMP"

echo "Build complete: $DMG_PATH"
