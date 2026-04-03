#!/bin/zsh
set -euo pipefail

SOURCE_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
APP_NAME="Codex Account Switcher.app"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
TARGET_APP="$INSTALL_DIR/$APP_NAME"

"$SOURCE_DIR/build.sh"

mkdir -p "$INSTALL_DIR"
rm -rf "$TARGET_APP"
cp -R "$SOURCE_DIR/dist/$APP_NAME" "$TARGET_APP"

echo "Installed $TARGET_APP"
