#!/bin/bash
set -euo pipefail

# Package Scope as a macOS .app bundle
# Usage: ./scripts/package-app.sh
# Output: build/Scope.app

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="Scope"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
BUNDLE_ID="com.scope.app"
VERSION="1.0.0"

echo "=== Packaging $APP_NAME.app ==="
echo ""

# Step 1: Build release binaries
echo "[1/5] Building release binaries..."
cd "$PROJECT_DIR/Context"
swift build -c release 2>&1 | tail -3
BINARY_PATH=".build/release/Scope"
MCP_BINARY_PATH=".build/release/ScopeMCP"

if [ ! -f "$BINARY_PATH" ]; then
    echo "ERROR: Binary not found at $BINARY_PATH"
    exit 1
fi
echo "  App binary: $(du -h "$BINARY_PATH" | awk '{print $1}')"
echo "  MCP binary: $(du -h "$MCP_BINARY_PATH" | awk '{print $1}')"

# Step 2: Generate icon
echo "[2/5] Generating app icon..."
ICON_WORK="$BUILD_DIR/icon_work"
mkdir -p "$ICON_WORK"
CUSTOM_ICON="$PROJECT_DIR/assets/AppIcon.png"
if [ -f "$CUSTOM_ICON" ]; then
    cp "$CUSTOM_ICON" "$ICON_WORK/icon_1024.png"
    echo "  Using custom icon from assets/AppIcon.png"
else
    swift "$SCRIPT_DIR/generate-icon.swift" "$ICON_WORK"
    echo "  Generated programmatic icon (place assets/AppIcon.png to use a custom icon)"
fi

# Step 3: Create iconset
echo "[3/5] Creating iconset..."
ICONSET="$ICON_WORK/AppIcon.iconset"
mkdir -p "$ICONSET"

# macOS icon sizes
SIZES=(16 32 64 128 256 512)
for s in "${SIZES[@]}"; do
    sips -z "$s" "$s" "$ICON_WORK/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null 2>&1
    d=$((s * 2))
    sips -z "$d" "$d" "$ICON_WORK/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null 2>&1
done
cp "$ICON_WORK/icon_1024.png" "$ICONSET/icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o "$ICON_WORK/AppIcon.icns"
echo "  Icon: $(du -h "$ICON_WORK/AppIcon.icns" | awk '{print $1}')"

# Step 4: Assemble .app bundle
echo "[4/5] Assembling .app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binaries
cp "$BINARY_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$MCP_BINARY_PATH" "$APP_BUNDLE/Contents/MacOS/ScopeMCP"

# Copy icon
cp "$ICON_WORK/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# Write Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>scope</string>
            </array>
            <key>CFBundleURLName</key>
            <string>com.scope.oauth</string>
        </dict>
    </array>
    <key>LSUIElement</key>
    <false/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Scope needs microphone access to record meeting audio for transcription and task extraction.</string>
</dict>
</plist>
PLIST

# Write PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Step 5: Ad-hoc codesign
echo "[5/5] Codesigning..."
codesign --force --deep --sign - "$APP_BUNDLE" 2>&1
echo "  Signed (ad-hoc)"

# Create .zip for distribution
echo "Creating .zip archive..."
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$BUILD_DIR/$APP_NAME.zip"
echo "  Archive: $(du -h "$BUILD_DIR/$APP_NAME.zip" | awk '{print $1}')"

# Cleanup
rm -rf "$ICON_WORK"

echo ""
echo "=== Done ==="
APP_SIZE=$(du -sh "$APP_BUNDLE" | awk '{print $1}')
echo "  $APP_BUNDLE ($APP_SIZE)"
echo ""
echo "To install:"
echo "  cp -r \"$APP_BUNDLE\" /Applications/"
echo ""
echo "Or just double-click it in Finder:"
echo "  open \"$BUILD_DIR\""
echo ""
echo "MCP server binary is at:"
echo "  $APP_BUNDLE/Contents/MacOS/ScopeMCP"
echo ""
echo "To configure Claude Code, add to ~/.claude/settings.json:"
echo "  \"mcpServers\": {"
echo "    \"scope\": {"
echo "      \"command\": \"$APP_BUNDLE/Contents/MacOS/ScopeMCP\""
echo "    }"
echo "  }"
