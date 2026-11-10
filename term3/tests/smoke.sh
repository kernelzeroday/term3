#!/usr/bin/env bash
# CLI smoke tests: no display needed. Checks identity, version, the default
# config, and that term3's config keys validate (and bad values don't).
#
#   term3/tests/smoke.sh [path/to/term3]     (default: zig-out/bin/term3)
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
bin="${1:-$root/zig-out/bin/term3}"
ver="$("$root/term3/scripts/version.sh")"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# Never read the developer's real config.
export XDG_CONFIG_HOME="$tmp/config" HOME="$tmp/home"
mkdir -p "$XDG_CONFIG_HOME" "$HOME"

pass=0
fail=0
check() {
  local name="$1"; shift
  if "$@" >"$tmp/out" 2>&1; then
    pass=$((pass + 1)); echo "ok   $name"
  else
    fail=$((fail + 1)); echo "FAIL $name"; sed 's/^/     /' "$tmp/out" | head -20
  fi
}

check "binary exists" test -x "$bin"
check "+version reports term3 $ver and its ghostty base" \
  bash -c "'$bin' +version | head -1 | grep -Eq '^term3 $ver \\(ghostty [0-9]+\\.[0-9]+\\.[0-9]+'"
check "+version lists the term3 version" \
  bash -c "'$bin' +version | grep -q '^  - term3  : $ver\$'"

defaults="$("$bin" +show-config --default 2>/dev/null || true)"
for kv in "gtk-tabs-location = left" "gtk-sidebar-width = 220" \
          "gtk-sidebar-title-overflow = ellipsize" "gtk-sidebar-title-lines = 2" \
          "gtk-sidebar-subtitle = working-directory" \
          "background = #171421" "foreground = #d0cfcc" \
          "palette = 0=#171421" "palette = 1=#c01c28"; do
  check "default: $kv" grep -qxF "$kv" <<<"$defaults"
done

cat >"$tmp/good.conf" <<'EOF'
gtk-tabs-location = right
gtk-sidebar-width = 300
gtk-sidebar-title-overflow = scroll
gtk-sidebar-title-lines = 3
gtk-sidebar-subtitle = none
EOF
check "+validate-config accepts term3 keys" "$bin" +validate-config --config-file="$tmp/good.conf"

for bad in "gtk-tabs-location = middle" "gtk-sidebar-width = wide" \
           "gtk-sidebar-title-overflow = marquee" "gtk-sidebar-subtitle = cwd"; do
  echo "$bad" >"$tmp/bad.conf"
  check "+validate-config rejects: $bad" bash -c "! '$bin' +validate-config --config-file='$tmp/bad.conf'"
done

check "config is read from ~/.config/term3/config" bash -c "
  mkdir -p '$XDG_CONFIG_HOME/term3' &&
  echo 'gtk-sidebar-width = 345' > '$XDG_CONFIG_HOME/term3/config' &&
  '$bin' +show-config | grep -qxF 'gtk-sidebar-width = 345'"

ti="$(dirname "$bin")/../share/term3/terminfo"
check "private terminfo describes xterm-ghostty with E3 (Ctrl+L clears scrollback)" \
  bash -c "TERMINFO='$ti' infocmp -x xterm-ghostty | grep -qF 'E3=\\E[3J'"

sti="$(dirname "$bin")/../share/terminfo"
check "system terminfo describes xterm-ghostty with E3 without TERMINFO env" \
  bash -c "infocmp -x -A '$sti' xterm-ghostty | grep -qF 'E3=\\E[3J'"

echo
echo "smoke: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
