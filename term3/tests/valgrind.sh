#!/usr/bin/env bash
# Memory-safety check: build a baseline-CPU debug term3 (valgrind can't run
# newer SIMD instructions) and run the headless GUI test under valgrind.
# Reports invalid reads/writes, uses of uninitialised memory, and definite
# leaks, with upstream's valgrind.supp plus term3/tests/term3.supp filtering
# known GTK/Mesa noise.
#
#   term3/tests/valgrind.sh
#   KEEP_TMP=1 term3/tests/valgrind.sh      # keep valgrind.log for inspection
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
command -v valgrind >/dev/null || { echo "SKIP: valgrind not installed"; exit 77; }

zig="${ZIG:-zig}"
prefix="$root/term3/out/valgrind"
"$zig" build -Doptimize=Debug -Dcpu=baseline --prefix "$prefix" ${ZIG_BUILD_FLAGS:-}
VALGRIND=1 "$root/term3/tests/gui.sh" "$prefix/bin/term3"
