#!/bin/zsh
# ビルドして ~/Applications にインストールし、ログイン時に起動するよう登録して起動する
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh

DEST="$HOME/Applications/DiaCommandBar.app"
mkdir -p "$HOME/Applications"
pkill -x DiaCommandBar 2>/dev/null || true
sleep 0.5
rm -rf "$DEST"
cp -R build/DiaCommandBar.app "$DEST"

open "$DEST" --args --enable-login-item
echo "installed: $DEST"
