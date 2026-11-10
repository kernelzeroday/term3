# Changelog

term3 versions follow [semver](https://semver.org); see [RELEASING.md](RELEASING.md).
Each release notes the Ghostty version it is built on.

## 0.1.0-rc.5

Built on Ghostty 1.4.1-dev (main at f28124c73).

### Added
- **Default to maximized window on launch.** term3 now opens new windows in
  a maximized state by default (`maximize = true`). Explicit configuration
  and `--maximize=false` continue to work as expected.
- **Large browser-proportioned restore size.** When unmaximized, or when
  running without maximize, term3 now sizes windows to occupy the majority
  of the screen (80% width and 80% height, minimum 800×600) like a typical
  modern browser, instead of shrinking into a tiny 800×600 box.

## 0.1.0-rc.4

Built on Ghostty 1.4.1-dev (main at f28124c73).

### Fixed
- **`xterm-ghostty` terminfo not found in `sudo -s`, `sudo -i`, `su`, or root subshells.**
  rc.2 placed the compiled terminfo only in `/usr/share/term3/terminfo` and relied
  on the `TERMINFO` environment variable. When running `sudo -s` or switching users,
  `sudo`'s `env_reset` strips `TERMINFO`, causing programs like `htop`, `vim`, and `nano`
  to fail with `Error opening terminal: xterm-ghostty`. term3 now also installs
  `xterm-ghostty` into the standard system terminfo path (`/usr/share/terminfo/x/xterm-ghostty`)
  so it resolves in all contexts without requiring environment variables.
- **Enable `sudo` shell integration by default.** `shell-integration-features` now
  enables `sudo` by default so terminal sessions automatically preserve `TERMINFO`
  via `sudo --preserve-env=TERMINFO` when invoking commands across remote hosts.

## 0.1.0-rc.3

Built on Ghostty 1.4.1-dev (main at f28124c73).

### Added
- **GNOME dark color scheme and palette by default.** term3 now defaults to
  GNOME Terminal's standard "GNOME dark" theme: `#171421` background,
  `#d0cfcc` foreground, and the 16-color ANSI palette from GNOME Terminal.

## 0.1.0-rc.2

Built on Ghostty 1.4.1-dev (main at f28124c73).

### Fixed
- **Ctrl+L in bash didn't clear the screen or scrollback, and terminfo-based
  programs saw an unknown terminal.** rc.1 relied on Fedora's `ncurses-term`
  for terminfo, but it only provides `ghostty`, not the `xterm-ghostty`
  that term3 sets as `TERM`. term3 now ships Ghostty's terminfo, which
  includes `E3` (clear scrollback, used by readline's clear-screen), in a
  private database at `/usr/share/term3/terminfo`, and points `TERMINFO` at
  it. ncurses still falls back to the system database for other terminal
  types, and the private location can't conflict with `ncurses-term` or a
  Ghostty package.
- **Bar cursor at the prompt.** Ghostty's shell integration switched the
  cursor to a bar at the prompt. term3 turns that feature off by default,
  so the cursor stays a block, like GNOME Terminal
  (`shell-integration-features = cursor` brings it back).
- Regression tests: the GUI test runs `tput clear` and `tput E3` inside a
  term3 tab, the smoke test checks the shipped entry, and the RPM's
  `%check` verifies it.

## 0.1.0-rc.1

First release candidate. Built on Ghostty 1.4.1-dev (main at f28124c73).

### Tab sidebar
- Tabs in a vertical sidebar on the left (`gtk-tabs-location = left`, the
  default) or right. Rows have a fixed size, so the window never changes
  shape as tabs are added.
- Drag the sidebar's edge to resize (`gtk-sidebar-width`, default 220).
- Drag rows to reorder. Middle-click closes. Right-click for rename/close.
  A dot marks tabs that rang the bell.
- Long titles: `gtk-sidebar-title-overflow = ellipsize | scroll | wrap`,
  with `gtk-sidebar-title-lines` for `wrap`.
- A dimmed working-directory line under each title
  (`gtk-sidebar-subtitle = working-directory | none`). It is hidden when the
  title already shows the directory.

### GNOME
- The default font is the desktop monospace font and size (GNOME's
  `monospace-font-name`, e.g. Adwaita Mono 11), as in GNOME Terminal.
  `font-family` or `font-size` in your config override it.

### Identity and packaging
- Binary `term3`, app ID `io.github.kernelzeroday.term3`, config in
  `~/.config/term3/config`, resources in `share/term3`. Installs alongside
  Ghostty without conflicts.
- New icon. "About term3" shows term3's version and the Ghostty base.
- RPM packaging (`term3/scripts/build-rpm.sh`). It uses Fedora system
  libraries where available and is built offline.
- Test suite: unit, property, config, CLI smoke and headless GUI tests,
  plus valgrind (`term3/tests/run.sh`). For this release: 98 unit/property/
  config tests, 14 smoke checks, and the GUI tier (12 tabs and 2 windows, no
  GTK criticals) all pass. Valgrind reports 0 errors and 0 bytes definitely lost.

### Known limitations
- A `font-family` set only in a nested `config-file` include is added after
  the desktop font instead of replacing it. Set it in the main config file.
- Shell completions, man pages and editor syntax files are not packaged yet
  (upstream's are named for `ghostty`).
- Strings term3 changed ("About term3", "Quit term3?") are English-only.
