#!/bin/bash
# Builds YAME.app for Apple silicon.
# Needs macOS 26 and Xcode 26 (or its Command Line Tools: `xcode-select --install`).
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
APP="build/YAME.app"

echo "▸ Compiling (${CONFIG}, arm64)…"
swift build -c "${CONFIG}" --arch arm64 --product YAME
BIN="$(swift build -c "${CONFIG}" --arch arm64 --show-bin-path)/YAME"

echo "▸ Assembling ${APP}…"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/YAME"
cp Resources/Info.plist "${APP}/Contents/Info.plist"
cp Resources/AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"
if [ -n "${VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION#v}" "${APP}/Contents/Info.plist"
fi
strip -x "${APP}/Contents/MacOS/YAME" || true

echo "▸ Signing (ad-hoc)…"
codesign --force --deep --options runtime --sign - "${APP}"

echo "✓ Built ${APP} ($(du -sh "${APP}" | cut -f1))"
echo "  Open it with:  open ${APP}"
