#!/usr/bin/env bash
# Cut a term3 release from the current commit. See term3/RELEASING.md.
#
#   term3/scripts/release.sh            check, test, build RPMs, tag, then ask before pushing
#   term3/scripts/release.sh --dry-run  everything except tagging and publishing
#
# Publishing pushes the tag to origin and creates a GitHub release (marked
# pre-release for -rc versions) with the RPMs, SRPM and sources attached.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
dry=0; [[ "${1:-}" == "--dry-run" ]] && dry=1

ver="$(term3/scripts/version.sh)"
tag="$(term3/scripts/version.sh --tag)"
gver="$(term3/scripts/version.sh --ghostty)"
die() { echo "release: $*" >&2; exit 1; }

echo "term3 $ver  (tag $tag, ghostty $gver)"

# --- preconditions ----------------------------------------------------------
[[ -z "$(git status --porcelain)" ]] || die "working tree not clean"
[[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || die "not on main"
git rev-parse -q --verify "refs/tags/$tag" >/dev/null && die "tag $tag already exists"
grep -q "^## $ver\$" term3/CHANGELOG.md || die "no '## $ver' section in term3/CHANGELOG.md"
git merge-base --is-ancestor upstream/main HEAD 2>/dev/null ||
  echo "note: HEAD does not contain the latest upstream/main (fine; recorded base is $gver)"

# --- tests and artifacts ----------------------------------------------------
term3/tests/run.sh || die "tests failed"
term3/scripts/make-sources.sh
term3/scripts/build-rpm.sh

out="term3/out"
mapfile -t assets < <(find "$out/rpmbuild/RPMS" "$out/rpmbuild/SRPMS" -name '*.rpm'; \
                      ls "$out/term3-$ver.tar.gz" "$out/term3-$ver-zig-deps.tar.gz")
(cd "$out" && sha256sum "${assets[@]/#$out\//}" > "SHA256SUMS-$ver") 2>/dev/null ||
  sha256sum "${assets[@]}" > "$out/SHA256SUMS-$ver"
assets+=("$out/SHA256SUMS-$ver")
printf 'artifact: %s\n' "${assets[@]}"

[[ $dry -eq 1 ]] && { echo "dry run: not tagging or publishing"; exit 0; }

# --- tag --------------------------------------------------------------------
notes="$(awk -v v="## $ver" '$0==v{f=1;next} /^## /{f=0} f' term3/CHANGELOG.md)"
git tag -a "$tag" -m "term3 $ver

Based on Ghostty $gver.
$notes"
echo "created tag $tag"

# --- publish (asks first) ---------------------------------------------------
read -r -p "Push $tag to origin and publish the GitHub release? [y/N] " yn
[[ "$yn" == [yY]* ]] || { echo "not published. Later: git push origin $tag && gh release create ..."; exit 0; }

git push origin "$tag"
pre=(); [[ "$ver" == *-* ]] && pre=(--prerelease)
gh release create "$tag" "${pre[@]}" --title "term3 $ver" \
  --notes "Based on Ghostty $gver.

$notes

Install: \`sudo dnf install ./term3-$(term3/scripts/version.sh --rpm)-1.<dist>.<arch>.rpm\`" \
  "${assets[@]}"
