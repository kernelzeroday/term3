#!/usr/bin/env bash
# Render term3/icon/term3.svg into every PNG the build embeds or installs:
#   images/gnome/{N}.png, images/gnome/nightly-{N}.png  (GTK app + installed icons)
#   images/icons/icon_{N}.png, icon_{N}@2x.png           (other upstream uses)
# Those paths are upstream's, so the build picks up our icon with no build
# changes, and Ghostty's trademarked icon is not shipped.
#
# Requires ImageMagick 7 with the librsvg delegate (`magick -list format | grep RSVG`).
set -euo pipefail
cd "$(dirname "$0")/../.."

svg=term3/icon/term3.svg
out=images/icons

for size in 16 32 128 256 512 1024; do
  magick -background none -density 384 "$svg" -resize "${size}x${size}" "PNG32:$out/icon_${size}.png"
  magick -background none -density 384 "$svg" -resize "$((size * 2))x$((size * 2))" "PNG32:$out/icon_${size}@2x.png"
done

for size in 16 32 64 128 256 512 1024 2048; do
  magick -background none -density 768 "$svg" -resize "${size}x${size}" "PNG32:images/gnome/${size}.png"
  cp "images/gnome/${size}.png" "images/gnome/nightly-${size}.png"
done

echo "rendered $(ls images/gnome/*.png | wc -l) icons into images/gnome"
echo "rendered $(ls "$out"/icon_*.png | wc -l) icons into $out"
