#!/usr/bin/env bash
# Regenerates the Auto-Loader chest sprites from the vanilla steel-chest art.
#
# The mod ships its own copies of these PNGs (with the blue tint baked in) so
# that data.lua never depends on the steel-chest prototype's icon/picture
# fields, which other mods (e.g. AAI Containers & Warehouses) rewrite.
#
# Requires ImageMagick (`magick`) and a local Factorio install.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="${FACTORIO_BASE:-$HOME/Library/Application Support/Steam/steamapps/common/Factorio/factorio.app/Contents/data/base}"

if [ ! -d "$BASE" ]; then
  echo "Factorio base data not found: $BASE (set FACTORIO_BASE)" >&2
  exit 1
fi

# Multiplicative tint, matching Factorio's `tint` semantics: r=0.45 g=0.75 b=1.0.
TINT_R=0.45
TINT_G=0.75

tint() {
  magick "$1" -channel R -evaluate multiply "$TINT_R" -channel G -evaluate multiply "$TINT_G" +channel "$2"
}

tint "$BASE/graphics/icons/steel-chest.png"              "$SCRIPT_DIR/icons/auto-loader-chest.png"
tint "$BASE/graphics/entity/steel-chest/steel-chest.png" "$SCRIPT_DIR/entity/auto-loader-chest.png"
cp   "$BASE/graphics/entity/steel-chest/steel-chest-shadow.png" "$SCRIPT_DIR/entity/auto-loader-chest-shadow.png"

echo "Wrote:"
ls -1 "$SCRIPT_DIR/icons" "$SCRIPT_DIR/entity"
