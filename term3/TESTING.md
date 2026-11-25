# Testing term3

```sh
term3/tests/run.sh          # unit + property + config + smoke + gui + gnome
term3/tests/run.sh --all    # ...plus valgrind memcheck (slow)
```

Tiers whose tools aren't installed are reported as **skip**, not pass.

| Tier | What it covers | Needs |
| --- | --- | --- |
| **unit** (`zig build test -Dtest-filter=term3`) | Pure sidebar logic in `src/term3.zig`: width clamping, drag math, the marquee timeline, `~` abbreviation, hiding a subtitle that repeats the title, font-name parsing, GNOME accelerator parsing and the defuse/restore bookkeeping (and that every defused GNOME shortcut is one of term3's own super keybinds). term3 config options: defaults, parsing, rejection of bad values, and the system-font default and how config replaces it. | Zig |
| **property** (part of unit) | Invariants over 20,000 seeded random inputs each: widths always in range, drag is monotonic and mirrored left/right, the marquee is bounded, periodic and never moves backwards, path abbreviation round-trips, font parsing never crashes, the subtitle check matches a reference implementation, any width round-trips through config. Seeds are fixed, so failures reproduce. | Zig |
| **smoke** (`term3/tests/smoke.sh`) | The built binary: `+version` shows term3 and its Ghostty base, the default config has term3's keys, `+validate-config` accepts good values and rejects bad ones, and config is read from `~/.config/term3/`. | none |
| **gui** (`term3/tests/gui.sh`) | The real app in a headless compositor with a private D-Bus session: opens 12 tabs with long titles and directory changes, a second window, then quits. Fails on a crash, a non-zero exit, a hang, or any GTK/GLib CRITICAL. | weston (or Xvfb), dbus-daemon |
| **gnome** (`term3/tests/gnome.sh`) | The real app in a real headless GNOME Shell, with real key events sent through Mutter's RemoteDesktop API and a test-only shell extension reporting what the shell did. Reproduces the super-shortcut race (a fast `super+v` reaches GNOME before term3's shortcuts inhibit exists, and GNOME's notification list takes the keyboard), and checks `gtk-defuse-gnome-shortcuts` end to end: toggled from the Settings menu action, exactly the clashing GNOME shortcuts are removed, a fast `super+v` then still pastes and opens no popup, the choice is saved, it is idempotent across restarts and config reloads, and turning it off resets the keys to GNOME's defaults while keeping the user's own changes. Its own D-Bus session, HOME, GSettings database and runtime dir; it refuses to run if GSettings would write anywhere else. | gnome-shell, python3-dbus, dbus-daemon |
| **valgrind** (`term3/tests/valgrind.sh`) | The gui tier on a baseline-CPU debug build under memcheck: invalid reads/writes, uninitialised values, definite leaks. Upstream's `valgrind.supp` plus `term3/tests/term3.supp` filter driver noise. | valgrind |

## Memory safety, in layers

- Zig's own checks: Debug and ReleaseSafe builds trap on out-of-bounds
  access, integer overflow, null unwrap, and use of `undefined` in many cases.
- Zig unit tests use `std.testing.allocator`, which fails a test on any leak
  or double free.
- Valgrind covers the parts Zig can't see: the C libraries and the GTK/GObject
  reference counting at the edge of the sidebar code (bindings, expressions,
  signal handlers).

Fedora packages: `sudo dnf install valgrind weston dbus-daemon xorg-x11-server-Xvfb python3-dbus`.
