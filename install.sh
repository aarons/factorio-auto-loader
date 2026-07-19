#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

NAME=$(/usr/bin/python3 -c 'import json; print(json.load(open("info.json"))["name"])')
VERSION=$(/usr/bin/python3 -c 'import json; print(json.load(open("info.json"))["version"])')
SLUG="${NAME}_${VERSION}"
ZIP="${SLUG}.zip"
ARCHIVE_DIR="$SCRIPT_DIR/archive"
MODS_DIR="$HOME/Library/Application Support/factorio/mods"

if [ ! -d "$MODS_DIR" ]; then
  echo "Factorio mods directory not found: $MODS_DIR" >&2
  exit 1
fi

mkdir -p "$ARCHIVE_DIR"
for existing in "$SCRIPT_DIR"/${NAME}_*.zip; do
  [ -e "$existing" ] || continue
  mv -f "$existing" "$ARCHIVE_DIR/"
done

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/$SLUG"
cp -R control.lua data.lua settings.lua info.json changelog.txt locale "$STAGE/$SLUG/"

(cd "$STAGE" && zip -qr "$SCRIPT_DIR/$ZIP" "$SLUG")

cp "$ZIP" "$MODS_DIR/$ZIP"

echo "Installed $ZIP -> $MODS_DIR"
