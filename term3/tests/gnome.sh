#!/usr/bin/env bash
# GNOME tier: the real app in a real (headless) GNOME Shell, with real key
# events sent through Mutter's RemoteDesktop API. Covers super shortcuts
# against GNOME's own (the keyboard-shortcuts inhibit race) and
# gtk-defuse-gnome-shortcuts. See term3/tests/gnome/drive.py for the checks.
#
#   term3/tests/gnome.sh [path/to/term3]       (default: zig-out/bin/term3)
#   KEEP_TMP=1 term3/tests/gnome.sh            keep logs
#
# Everything runs in a private D-Bus session with its own HOME, config,
# GSettings database, runtime dir and Wayland display: your desktop, its
# settings and its keyboard are never touched.
#
# Needs: gnome-shell (with --headless), dbus-run-session, gsettings, gdbus,
# python3 with the dbus module (Fedora: python3-dbus).
set -euo pipefail
# The system tools, not e.g. Homebrew's: Homebrew's GLib has no dconf module
# and silently falls back to a keyfile in the real config dir.
export PATH="/usr/bin:/bin:$PATH"
root="$(cd "$(dirname "$0")/../.." && pwd)"
py=/usr/bin/python3; [[ -x $py ]] || py=python3
uuid="term3-test@term3"

if [[ "${1:-}" != --inner ]]; then
  bin="$(realpath "${1:-$root/zig-out/bin/term3}")"
  if ! gnome-shell --help 2>/dev/null | grep -q -- --headless; then
    echo "SKIP: needs gnome-shell with --headless"; exit 77
  fi
  for c in dbus-run-session gsettings gdbus; do
    command -v "$c" >/dev/null || { echo "SKIP: needs $c"; exit 77; }
  done
  "$py" -c 'import dbus' 2>/dev/null || { echo "SKIP: needs python3-dbus"; exit 77; }

  # Build the private environment first, then start the private bus inside
  # it. Services the bus starts on demand (dconf, the permission store)
  # inherit the bus daemon's environment, so it must already point at the
  # temp dir. GSETTINGS_BACKEND keeps every client on the same database.
  tmp="$(mktemp -d)"
  export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/config" XDG_DATA_HOME="$tmp/data" \
    XDG_STATE_HOME="$tmp/state" XDG_CACHE_HOME="$tmp/cache" XDG_RUNTIME_DIR="$tmp/run" \
    GSETTINGS_BACKEND=dconf
  mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME/applications" "$XDG_STATE_HOME" \
    "$XDG_CACHE_HOME" "$XDG_RUNTIME_DIR"
  chmod 700 "$XDG_RUNTIME_DIR"
  export T3TEST_EVENTS="$tmp/events.jsonl" T3TEST_CLIPBOARD="term3-gnome-test-paste"

  # The test extension, loaded from a data dir only this session sees.
  ext="$tmp/share/gnome-shell/extensions/$uuid"
  mkdir -p "$ext"
  cp "$root/term3/tests/gnome/extension.js" "$ext/"
  major="$(gnome-shell --version | grep -oE '[0-9]+' | head -1)"
  printf '{"uuid": "%s", "name": "term3 test", "description": "term3 GNOME test tier", "shell-version": ["%s"]}\n' \
    "$uuid" "$major" >"$ext/metadata.json"
  export XDG_DATA_DIRS="$tmp/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"

  # GNOME keys its "may this app capture shortcuts" permission by desktop
  # file, so give the app one; the inner part grants it (a fresh session
  # would otherwise ask with a dialog that takes the keyboard).
  printf '[Desktop Entry]\nType=Application\nName=term3\nExec=%s\nStartupWMClass=io.github.kernelzeroday.term3\n' \
    "$bin" >"$XDG_DATA_HOME/applications/io.github.kernelzeroday.term3.desktop"

  status=0
  dbus-run-session -- "$0" --inner "$bin" "$tmp" || status=$?
  # The document portal may still have its FUSE mount in the runtime dir.
  for _ in 1 2 3; do
    fusermount3 -u "$tmp/run/doc" 2>/dev/null || fusermount -u "$tmp/run/doc" 2>/dev/null || true
    [[ -n "${KEEP_TMP:-}" ]] && break
    rm -rf "$tmp" 2>/dev/null && break
    sleep 1
  done
  if [[ -n "${KEEP_TMP:-}" ]]; then echo "logs kept in $tmp"
  elif [[ -e "$tmp" ]]; then echo "note: could not remove $tmp"; fi
  exit $status
fi

# --- inner: inside the private bus -------------------------------------------
bin="$2" tmp="$3"
shell_pid=""
cleanup() {
  [[ -n "$shell_pid" ]] && kill "$shell_pid" 2>/dev/null || true
  pkill -P $$ 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup EXIT

# Never touch the real settings: the first write must land in the temp dir.
gsettings set org.gnome.shell welcome-dialog-last-shown-version "'999'"
if [[ ! -s "$XDG_CONFIG_HOME/dconf/user" ]]; then
  echo "FAIL: GSettings did not write to the test's own database; refusing to go on"; exit 1
fi
gsettings set org.gnome.shell disable-user-extensions false
gsettings set org.gnome.shell enabled-extensions "['$uuid']"

gnome-shell --headless --wayland --no-x11 --virtual-monitor 1280x800 \
  --wayland-display=term3-gnome-test >"$tmp/shell.log" 2>&1 &
shell_pid=$!
export WAYLAND_DISPLAY=term3-gnome-test GDK_BACKEND=wayland
for _ in $(seq 100); do [[ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]] && break; sleep 0.1; done
[[ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]] || { echo "gnome-shell did not start"; tail -20 "$tmp/shell.log"; exit 1; }
for _ in $(seq 150); do grep -q '"enabled"' "$T3TEST_EVENTS" 2>/dev/null && break; sleep 0.1; done
grep -q '"enabled"' "$T3TEST_EVENTS" 2>/dev/null || { echo "test extension did not load"; tail -20 "$tmp/shell.log"; exit 1; }

gdbus call --session --dest org.freedesktop.impl.portal.PermissionStore \
  --object-path /org/freedesktop/impl/portal/PermissionStore \
  --method org.freedesktop.impl.portal.PermissionStore.SetPermission \
  gnome true shortcuts-inhibitor io.github.kernelzeroday.term3.desktop "['GRANTED']" >/dev/null

status=0
"$py" -I "$root/term3/tests/gnome/drive.py" "$bin" "$tmp" || status=$?
if [[ $status -ne 0 ]]; then
  echo "--- gnome-shell log (tail)"; grep -vE "dbus-daemon|Activat" "$tmp/shell.log" | tail -15
fi
exit $status
