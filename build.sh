#!/bin/zsh
set -euo pipefail

APP_NAME="Codex Account Switcher"
EXECUTABLE_NAME="CodexAccountSwitcher"
SOURCE_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
SOURCE_FILE="$SOURCE_DIR/CodexMenuBarApp.swift"
CLI_SOURCE="${CLI_SOURCE:-$SOURCE_DIR/scripts/codex-account-switcher}"
ICON_SOURCE="${ICON_SOURCE:-$SOURCE_DIR/assets/AppIcon.icns}"
BUILD_ROOT="${BUILD_ROOT:-/tmp/CodexAccountSwitcherBuild}"
STAGING_APP="$BUILD_ROOT/$APP_NAME.app"
TARGET_APP="${TARGET_APP:-$SOURCE_DIR/dist/$APP_NAME.app}"
VERSION="${VERSION:-$(git -C "$SOURCE_DIR" describe --tags --abbrev=0 2>/dev/null || echo 1.0.0)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$SOURCE_DIR" rev-list --count HEAD 2>/dev/null || echo 1)}"

rm -rf "$BUILD_ROOT"
mkdir -p "$STAGING_APP/Contents/MacOS" "$STAGING_APP/Contents/Resources"
mkdir -p "$(dirname "$TARGET_APP")"

xcrun swiftc \
  -O \
  -parse-as-library \
  -framework AppKit \
  -framework SwiftUI \
  -framework Foundation \
  -framework UserNotifications \
  -o "$STAGING_APP/Contents/MacOS/$EXECUTABLE_NAME" \
  "$SOURCE_FILE"

cat > "$STAGING_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>Codex Account Switcher</string>
  <key>CFBundleExecutable</key>
  <string>CodexAccountSwitcher</string>
  <key>CFBundleIdentifier</key>
  <string>local.codex.account-switcher</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Codex Account Switcher</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${BUILD_NUMBER}</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

if [[ -f "$CLI_SOURCE" ]]; then
  cp "$CLI_SOURCE" "$STAGING_APP/Contents/Resources/codex-account-switcher"
  chmod +x "$STAGING_APP/Contents/Resources/codex-account-switcher"
fi

if [[ -f "$ICON_SOURCE" ]]; then
  cp "$ICON_SOURCE" "$STAGING_APP/Contents/Resources/AppIcon.icns"
  if /usr/libexec/PlistBuddy -c "Print :CFBundleIconFile" "$STAGING_APP/Contents/Info.plist" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$STAGING_APP/Contents/Info.plist"
  else
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$STAGING_APP/Contents/Info.plist"
  fi
fi

chmod +x "$STAGING_APP/Contents/MacOS/$EXECUTABLE_NAME"
codesign --force --deep -s - "$STAGING_APP"
rm -rf "$TARGET_APP"
mv "$STAGING_APP" "$TARGET_APP"

echo "Built $TARGET_APP"
