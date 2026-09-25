#!/usr/bin/env bash
# Draws every size of the app icon from Resources/icon/appIcon.svg into the asset catalog
# Run it after changing the SVG and commit the PNGs: the build takes them as they are and needs no rsvg-convert
#
# Environment:
#   RSVG_CONVERT  rsvg-convert executable (default: rsvg-convert from PATH; brew install librsvg)

set -euo pipefail

CLIENT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RSVG_CONVERT=${RSVG_CONVERT:-rsvg-convert}
SOURCE="$CLIENT_SRC/Resources/icon/appIcon.svg"
ICONSET="$CLIENT_SRC/Resources/Assets.xcassets/AppIcon.appiconset"
# The point sizes of a macOS app icon, each drawn at 1x and 2x
SIZES="16 32 128 256 512"

command -v "$RSVG_CONVERT" >/dev/null || { echo "rsvg-convert not found: brew install librsvg" >&2; exit 1; }
mkdir -p "$ICONSET"

images=""
for size in $SIZES; do
    for scale in 1 2; do
        suffix=$([ "$scale" = 2 ] && echo "@2x" || true)
        name="icon_${size}x${size}${suffix}.png"
        "$RSVG_CONVERT" -w $((size * scale)) -h $((size * scale)) "$SOURCE" -o "$ICONSET/$name"
        images="$images{ \"filename\": \"$name\", \"idiom\": \"mac\", \"scale\": \"${scale}x\", \"size\": \"${size}x${size}\" },"
    done
done

printf '{\n  "images": [%s],\n  "info": { "author": "xcode", "version": 1 }\n}\n' "${images%,}" |
    python3 -m json.tool --indent 2 >"$ICONSET/Contents.json"
printf '{\n  "info": { "author": "xcode", "version": 1 }\n}\n' >"$CLIENT_SRC/Resources/Assets.xcassets/Contents.json"
echo "Icon drawn into $ICONSET"
