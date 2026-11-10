#!/usr/bin/env bash
# Build the term3 .deb package for Debian/Ubuntu.
# Output is placed in the project root: term3_<version>_<arch>.deb
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"

ver="$(term3/scripts/version.sh)"
debver="$(term3/scripts/version.sh --rpm)" # 0.1.0~rc.4
arch="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
deb_file="$root/term3_${debver}_${arch}.deb"
deb_symlink="$root/term3_${ver}_${arch}.deb"

echo "Building term3 $ver ($debver) for $arch..."

stage="/tmp/term3-stage"
deb_dir="/tmp/term3-deb"
rm -rf "$stage" "$deb_dir"

# Build with zig
DESTDIR="$stage" zig build \
  --prefix /usr \
  --system "$root/.zig-deps" \
  -Doptimize=ReleaseFast \
  -Dcpu=baseline \
  -Dpie=true \
  -Dstrip=true \
  -Demit-docs=false \
  -Demit-terminfo=false \
  -Demit-termcap=false \
  -Dversion-string=1.4.1-dev \
  -Dpatch-rpath='$ORIGIN/../lib' \
  -fno-sys=spirv-cross \
  -fno-sys=glslang \
  -fno-sys=highway \
  -fno-sys=simdutf \
  -fno-sys=fontconfig \
  -fno-sys=freetype \
  -fno-sys=harfbuzz \
  -fno-sys=libpng \
  -fno-sys=zlib \
  -fno-sys=oniguruma \
  -fno-sys=gtk4-layer-shell \
  -fno-sys=libxml2

mkdir -p "$deb_dir"
cp -a "$stage"/* "$deb_dir"/

# Remove files keyed to ghostty command or dev headers
rm -rf "$deb_dir/usr/share/bash-completion" \
       "$deb_dir/usr/share/zsh" \
       "$deb_dir/usr/share/fish" \
       "$deb_dir/usr/share/bat" \
       "$deb_dir/usr/share/vim" \
       "$deb_dir/usr/share/nvim" \
       "$deb_dir/usr/share/man" \
       "$deb_dir/usr/include" \
       "$deb_dir"/usr/share/terminfo/ghostty.*

# Ensure both system and private terminfo entries exist
[[ -f "$deb_dir/usr/share/terminfo/x/xterm-ghostty" ]] || {
  echo "ERROR: $deb_dir/usr/share/terminfo/x/xterm-ghostty was not installed!" >&2
  exit 1
}
[[ -f "$deb_dir/usr/share/term3/terminfo/x/xterm-ghostty" ]] || {
  echo "ERROR: $deb_dir/usr/share/term3/terminfo/x/xterm-ghostty was not installed!" >&2
  exit 1
}

# Verify terminfo describes xterm-ghostty with E3 capability
infocmp -x -A "$deb_dir/usr/share/terminfo" xterm-ghostty | grep -qF 'E3=\E[3J' || {
  echo "ERROR: system terminfo missing E3 capability!" >&2
  exit 1
}

# Install documentation
mkdir -p "$deb_dir/usr/share/doc/term3"
cp "$root/LICENSE" "$deb_dir/usr/share/doc/term3/copyright"
cp "$root/README.md" "$deb_dir/usr/share/doc/term3/"
cp "$root/TERM3.md" "$deb_dir/usr/share/doc/term3/"
cp "$root/term3/SCOPE.md" "$deb_dir/usr/share/doc/term3/"
cp "$root/term3/VENDORING.md" "$deb_dir/usr/share/doc/term3/"
gzip -9cn "$root/term3/CHANGELOG.md" > "$deb_dir/usr/share/doc/term3/changelog.Debian.gz"

# Strip layer-shell library if present
if [[ -f "$deb_dir/usr/lib/libgtk4-layer-shell.so" ]]; then
  strip --strip-unneeded "$deb_dir/usr/lib/libgtk4-layer-shell.so" || true
fi

# Set permissions
find "$deb_dir" -type d -exec chmod 755 {} +
find "$deb_dir/usr/share" -type f -exec chmod 644 {} +
chmod 755 "$deb_dir/usr/bin/term3"
if [[ -f "$deb_dir/usr/lib/libgtk4-layer-shell.so" ]]; then
  chmod 755 "$deb_dir/usr/lib/libgtk4-layer-shell.so"
fi

installed_size="$(du -sk --apparent-size "$deb_dir/usr" | awk '{print $1}')"

# Compute dependencies via dpkg-shlibdeps if available
mkdir -p "$deb_dir/DEBIAN"
deps="libc6 (>= 2.38), libadwaita-1-0 (>= 1.7.0), libgtk-4-1 (>= 4.18.0), libglib2.0-0t64 | libglib2.0-0, libpango-1.0-0, libegl1, libwayland-client0, libx11-6, hicolor-icon-theme"
if command -v dpkg-shlibdeps >/dev/null 2>&1; then
  shlib_deps="$(cd /tmp && dpkg-shlibdeps -O -l"$deb_dir/usr/lib" "$deb_dir/usr/bin/term3" "$deb_dir"/usr/lib/libgtk4-layer-shell.so* 2>/dev/null | sed -e 's/^shlibs:Depends=//' || true)"
  if [[ -n "$shlib_deps" ]]; then
    deps="$shlib_deps, hicolor-icon-theme"
  fi
fi

cat > "$deb_dir/DEBIAN/control" <<EOF
Package: term3
Version: $debver
Architecture: $arch
Maintainer: term3 maintainers <noreply@github.com>
Installed-Size: $installed_size
Depends: $deps
Section: x11
Priority: optional
Homepage: https://github.com/kernelzeroday/term3
Description: GTK terminal with tabs in a sidebar on the left, based on Ghostty
 term3 is a terminal emulator whose one opinion is a vertical tab sidebar on
 the left, like iTerm2: tabs have a fixed size, show their working directory,
 can be dragged to reorder, and the sidebar can be resized. Everything else is
 Ghostty (1.4.1-dev): GPU rendering, fonts, configuration, and shell
 integration.
EOF

chmod 755 "$deb_dir/DEBIAN"
chmod 644 "$deb_dir/DEBIAN/control"

(cd "$deb_dir" && find usr -type f -exec md5sum {} + > "$deb_dir/DEBIAN/md5sums")
chmod 644 "$deb_dir/DEBIAN/md5sums"

dpkg-deb --root-owner-group --build "$deb_dir" "$deb_file"
ln -sf "$deb_file" "$deb_symlink"

echo "Package successfully built:"
ls -lh "$deb_file"
