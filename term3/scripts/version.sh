#!/usr/bin/env bash
# Print term3's version, read from src/term3.zig (the single source of truth).
#
#   version.sh          0.1.0-rc.1      (semver, used in tags: term3-v0.1.0-rc.1)
#   version.sh --rpm    0.1.0~rc.1      (RPM: "~" sorts pre-releases before 0.1.0)
#   version.sh --tag    term3-v0.1.0-rc.1
#   version.sh --ghostty  Ghostty version this tree is based on, e.g. 1.4.1-dev+f28124c73
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"

v="$(sed -n 's/^pub const version = "\(.*\)";$/\1/p' "$root/src/term3.zig")"
[[ -n "$v" ]] || { echo "version.sh: no version in src/term3.zig" >&2; exit 1; }

case "${1:-}" in
  "") echo "$v" ;;
  --rpm) echo "${v/-/\~}" ;;
  --tag) echo "term3-v$v" ;;
  --ghostty)
    gv="$(sed -n 's/^ *\.version = "\(.*\)",$/\1/p' "$root/build.zig.zon" | head -1)"
    base="$(git -C "$root" merge-base HEAD upstream/main 2>/dev/null || true)"
    if [[ -n "$base" ]]; then echo "$gv+$(git -C "$root" rev-parse --short=9 "$base")"; else echo "$gv"; fi
    ;;
  *) echo "usage: $0 [--rpm|--tag|--ghostty]" >&2; exit 2 ;;
esac
