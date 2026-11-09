#!/usr/bin/env bash
# Create the three RPM sources in term3/out/:
#   term3-<ver>.tar.gz            git archive of HEAD (must be committed)
#   term3-<ver>-zig-deps.tar.gz   every Zig package, unpacked by hash (zig build --system)
#   zig-<arch>-linux-<zigver>.tar.xz for x86_64 and aarch64 (the build-time compiler)
# Needs network for the Zig packages and compiler; the RPM build itself is offline.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"

ver="$(term3/scripts/version.sh)"
zigver="$(sed -n 's/^ *\.minimum_zig_version = "\(.*\)",$/\1/p' build.zig.zon)"
# The spec pins a patch release; keep in sync with %zig_version in term3.spec.in.
zigver_pinned="$(sed -n 's/^%global zig_version \(.*\)$/\1/p' term3/packaging/rpm/term3.spec.in)"
[[ "${zigver%.*}" == "${zigver_pinned%.*}" ]] || {
  echo "Zig mismatch: build.zig.zon wants $zigver, spec pins $zigver_pinned" >&2; exit 1; }

out="$root/term3/out"
mkdir -p "$out"

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "warning: uncommitted changes are NOT in the source tarball (it archives HEAD)" >&2
fi

echo "==> source tarball (term3-$ver)"
git archive --format=tar.gz --prefix="term3-$ver/" -o "$out/term3-$ver.tar.gz" HEAD

echo "==> zig packages"
deps_tmp="$(mktemp -d)"
trap 'rm -rf "$deps_tmp"' EXIT
ZIG_GLOBAL_CACHE_DIR="$deps_tmp/cache" ./nix/build-support/fetch-zig-cache.sh deps/packages.txt
mv "$deps_tmp/cache/p" "$deps_tmp/term3-$ver-zig-deps"
tar -C "$deps_tmp" -czf "$out/term3-$ver-zig-deps.tar.gz" "term3-$ver-zig-deps"

echo "==> zig $zigver_pinned toolchains"
for arch in x86_64 aarch64; do
  f="zig-$arch-linux-$zigver_pinned.tar.xz"
  [[ -s "$out/$f" ]] || curl -fsSL -o "$out/$f" "https://ziglang.org/download/$zigver_pinned/$f"
done

ls -lh "$out"
