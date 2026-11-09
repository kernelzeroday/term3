#!/usr/bin/env bash
# Headless GUI test: run the real app in a private compositor and D-Bus
# session (never your desktop's), drive the tab sidebar through D-Bus
# actions, and check it survives without GTK criticals.
#
#   term3/tests/gui.sh [path/to/term3]       (default: zig-out/bin/term3)
#   VALGRIND=1 term3/tests/gui.sh BIN        run the app under valgrind
#                                            (see term3/tests/valgrind.sh)
#
# Needs: weston (or Xvfb as a fallback), dbus-run-session, gdbus.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
bin="$(realpath "${1:-$root/zig-out/bin/term3}")"

# Re-exec inside a private session bus so the app's D-Bus name can't clash
# with a running term3.
if [[ -z "${TERM3_GUI_TEST_INNER:-}" ]]; then
  exec env TERM3_GUI_TEST_INNER=1 dbus-run-session -- "$0" "$bin"
fi

tmp="$(mktemp -d)"
log="$tmp/term3.log"
appid="io.github.kernelzeroday.term3.guitest"
objpath="/io/github/kernelzeroday/term3/guitest"
slow=1; [[ -n "${VALGRIND:-}" ]] && slow=10   # valgrind is ~10-50x slower

compositor_pid=""
app_pid=""
cleanup() {
  [[ -n "$app_pid" ]] && kill "$app_pid" 2>/dev/null || true
  [[ -n "$compositor_pid" ]] && kill "$compositor_pid" 2>/dev/null || true
  wait 2>/dev/null || true
  if [[ -n "${KEEP_TMP:-}" ]]; then echo "logs kept in $tmp"; else rm -rf "$tmp"; fi
}
trap cleanup EXIT

export XDG_CONFIG_HOME="$tmp/config" XDG_RUNTIME_DIR="$tmp/run" HOME="$tmp/home"
mkdir -p "$XDG_CONFIG_HOME/term3" "$XDG_RUNTIME_DIR" "$HOME"
chmod 700 "$XDG_RUNTIME_DIR"
cat >"$XDG_CONFIG_HOME/term3/config" <<'EOF'
gtk-tabs-location = left
gtk-sidebar-title-overflow = scroll
confirm-close-surface = false
quit-after-last-window-closed = true
# No systemd scopes: the private test D-Bus session has no systemd.
linux-cgroup = never
EOF

# --- compositor -------------------------------------------------------------
if command -v weston >/dev/null; then
  weston --backend=headless --renderer=gl --socket=term3-test --width=1280 --height=800 \
    >"$tmp/weston.log" 2>&1 &
  compositor_pid=$!
  export WAYLAND_DISPLAY=term3-test GDK_BACKEND=wayland
  for _ in $(seq 50); do [[ -S "$XDG_RUNTIME_DIR/term3-test" ]] && break; sleep 0.1; done
  [[ -S "$XDG_RUNTIME_DIR/term3-test" ]] || { echo "weston did not start"; cat "$tmp/weston.log"; exit 1; }
elif command -v Xvfb >/dev/null; then
  Xvfb :93 -screen 0 1280x800x24 >"$tmp/xvfb.log" 2>&1 &
  compositor_pid=$!
  export DISPLAY=:93 GDK_BACKEND=x11
  sleep 1
else
  echo "SKIP: need weston or Xvfb"; exit 77
fi
export LIBGL_ALWAYS_SOFTWARE=1

# --- app --------------------------------------------------------------------
run=("$bin" --class="$appid" --gtk-single-instance=true)
if [[ -n "${VALGRIND:-}" ]]; then
  run=(valgrind --error-exitcode=99 --num-callers=40 --leak-check=full
       --show-leak-kinds=definite --errors-for-leak-kinds=definite
       --suppressions="$root/valgrind.supp" --suppressions="$root/term3/tests/term3.supp"
       --log-file="$tmp/valgrind.log" "${run[@]}")
fi
if [[ -n "${GDB:-}" ]]; then
  # Debugging aid: stop at the first GLib CRITICAL and print the stack.
  export G_DEBUG=fatal-criticals
  run=(gdb -q -batch -ex run -ex "bt 40" --args "${run[@]}")
fi
GHOSTTY_LOG=stderr "${run[@]}" >"$log" 2>&1 &
app_pid=$!

act() { # act <action> [gvariant-params]
  # org.gtk.Actions.Activate takes (s av a{sv}); type the empty values
  # explicitly so gdbus doesn't guess wrong.
  gdbus call --session --timeout $((25 * slow)) --dest "$appid" --object-path "$objpath" \
    --method org.gtk.Actions.Activate "$1" "${2:-@av []}" '@a{sv} {}' >/dev/null
}

# Wait for the app to own its bus name.
for _ in $(seq $((100 * slow))); do
  gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
    --method org.freedesktop.DBus.NameHasOwner "$appid" 2>/dev/null | grep -q true && break
  kill -0 "$app_pid" 2>/dev/null || break
  sleep 0.1
done

fail=0
step() { echo "--- $*"; }
alive() {
  if ! kill -0 "$app_pid" 2>/dev/null; then
    echo "FAIL: term3 exited during: $1"; fail=1; return 1
  fi
}

# Wait for the first window's terminal; tabs requested before it exists
# would open as separate windows instead.
for _ in $(seq $((100 * slow))); do
  grep -qE "surface content scale|render surface realize" "$log" && break
  kill -0 "$app_pid" 2>/dev/null || break
  sleep 0.1
done

step "app started"; alive "startup" || true

# Each tab runs this: change directory, set a long title (exercises the
# subtitle and marquee paths), then idle.
cat >"$tmp/tab.sh" <<'EOS'
#!/bin/sh
cd /tmp
printf '\033]0;tab %s with a long title for the sidebar marquee\007' "$1"
printf '\033]7;file://%s/tmp\007' "$(hostname)"
exec sleep 600
EOS
chmod +x "$tmp/tab.sh"

step "open 12 tabs (rows created, titles and cwd bound)"
for i in $(seq 12); do
  act new-tab "[<@(tas) (0, [\"-e\", \"$tmp/tab.sh\", \"$i\"])>]" || true
  sleep "0.$((2 * slow))"
done
sleep $((1 * slow))
alive "opening tabs" || true

step "open a second window with its own sidebar"
act new-window || true
sleep $((1 * slow))
alive "second window" || true

step "quit cleanly"
act quit || true
for _ in $(seq $((100 * slow))); do kill -0 "$app_pid" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$app_pid" 2>/dev/null; then echo "FAIL: did not quit"; fail=1; fi
status=0; wait "$app_pid" || status=$?
app_pid=""
echo "exit status: $status"
[[ $status -eq 0 ]] || { echo "FAIL: non-zero exit"; fail=1; }

# Every terminal must have been created: the first window, 12 tabs, and the
# second window. (Release builds log "surface content scale", debug builds
# "render surface realize", once per terminal.)
surfaces=$(grep -cE "surface content scale" "$log" || true)
realized=$(grep -cE "render surface realize" "$log" || true)
(( realized > surfaces )) && surfaces=$realized
echo "terminals created: $surfaces (expected 14)"
[[ $surfaces -eq 14 ]] || { echo "FAIL: expected 14 terminals"; fail=1; }

# GTK/GLib criticals and warnings point at real bugs (bad casts, NULL
# objects, failed assertions); our own sidebar module must log no warnings.
if grep -E "CRITICAL|Gtk-CRITICAL|warning\(gtk_ghostty_tab_sidebar\)|panic" "$log"; then
  echo "FAIL: criticals in log"; fail=1
fi

if [[ -n "${VALGRIND:-}" ]]; then
  echo "--- valgrind"
  grep -E "ERROR SUMMARY|definitely lost|Invalid (read|write)|uninitialised" "$tmp/valgrind.log" | head -20 || true
  grep -q "ERROR SUMMARY: 0 errors" "$tmp/valgrind.log" || { echo "FAIL: valgrind errors (KEEP_TMP=1 to keep the log)"; fail=1; }
fi

if [[ $fail -ne 0 ]]; then
  echo "--- app log (tail)"; tail -40 "$log"
  echo "gui: FAILED"; exit 1
fi
echo "gui: passed"
