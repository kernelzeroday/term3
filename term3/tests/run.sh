#!/usr/bin/env bash
# Run every term3 test tier. Exit status is non-zero if any tier fails;
# tiers whose tools aren't installed are reported as skipped.
#
#   term3/tests/run.sh            unit + property + config + smoke + gui
#   term3/tests/run.sh --all      ...plus valgrind (slow: several minutes)
#
# Tiers:
#   unit      zig build test -Dtest-filter=term3   pure logic, property tests, config parsing
#   smoke     term3/tests/smoke.sh                 CLI: version, defaults, config validation
#   gui       term3/tests/gui.sh                   real app, headless compositor, D-Bus driven
#   valgrind  term3/tests/valgrind.sh              gui tier under valgrind memcheck
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
zig="${ZIG:-zig}"
results=()
overall=0

tier() { # tier <name> <command...>
  local name="$1"; shift
  echo "==== $name"
  "$@"; local s=$?
  case $s in
    0) results+=("pass  $name") ;;
    77) results+=("skip  $name") ;;
    *) results+=("FAIL  $name"); overall=1 ;;
  esac
}

tier unit "$zig" build test -Dtest-filter=term3 --summary all ${ZIG_BUILD_FLAGS:-}
tier build "$zig" build -Doptimize=ReleaseFast ${ZIG_BUILD_FLAGS:-}
tier smoke term3/tests/smoke.sh
if command -v dbus-run-session >/dev/null && { command -v weston >/dev/null || command -v Xvfb >/dev/null; }; then
  tier gui term3/tests/gui.sh
else
  echo "==== gui"; echo "SKIP: needs dbus-run-session and weston or Xvfb"; results+=("skip  gui")
fi
if [[ "${1:-}" == "--all" ]]; then
  tier valgrind term3/tests/valgrind.sh
fi

echo
printf '%s\n' "${results[@]}"
exit $overall
