#!/usr/bin/env bash
# Build the term3 SRPM and binary RPM into term3/out/rpmbuild/.
#   term3/scripts/build-rpm.sh                 # system libraries where Fedora has them
#   term3/scripts/build-rpm.sh --without system_libs   # everything bundled
# Requires: rpm-build, plus the BuildRequires in the spec
# (sudo dnf builddep term3/out/rpmbuild/SPECS/term3.spec).
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"

ver="$(term3/scripts/version.sh)"
rpmver="$(term3/scripts/version.sh --rpm)"
gver="$(term3/scripts/version.sh --ghostty)"
out="$root/term3/out"
top="$out/rpmbuild"

[[ -s "$out/term3-$ver.tar.gz" && -s "$out/term3-$ver-zig-deps.tar.gz" ]] || term3/scripts/make-sources.sh

mkdir -p "$top"/{SOURCES,SPECS,BUILD,RPMS,SRPMS}
# Symlink rather than copy: the sources are ~350 MB.
for f in "$out"/term3-"$ver".tar.gz "$out"/term3-"$ver"-zig-deps.tar.gz "$out"/zig-*-linux-*.tar.xz; do
  ln -sf "$f" "$top/SOURCES/"
done
sed -e "s/@VERSION@/$rpmver/g" \
    -e "s/@TARBALL_VERSION@/$ver/g" \
    -e "s/@GHOSTTY_VERSION@/$gver/g" \
    -e "s/@DATE@/$(LC_ALL=C date '+%a %b %d %Y')/g" \
    term3/packaging/rpm/term3.spec.in > "$top/SPECS/term3.spec"

# --clean removes the ~3 GB build tree (sources, Zig cache, buildroot)
# once the build succeeds; on failure it is kept for debugging. Remove it
# with: rm -rf term3/out/rpmbuild/BUILD
rpmbuild --define "_topdir $top" --clean -ba "$top/SPECS/term3.spec" "$@"
df -h "$out" | tail -1

echo
find "$top/RPMS" "$top/SRPMS" -name '*.rpm' -printf '%p  %s bytes\n'
