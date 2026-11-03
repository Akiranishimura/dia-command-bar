#!/bin/zsh
# リリースビルドして build/DiaCommandBar.app を作る
# （Command Line Tools の SwiftPM が壊れている環境があるので swiftc を直接使う）
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/DiaCommandBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O \
  -target arm64-apple-macosx13.0 \
  -framework AppKit -framework Carbon -framework ServiceManagement \
  Sources/DiaCommandBar/*.swift \
  -o "$APP/Contents/MacOS/DiaCommandBar"

cp Resources/Info.plist "$APP/Contents/"
codesign --force --sign - "$APP"
echo "built: $PWD/$APP"
