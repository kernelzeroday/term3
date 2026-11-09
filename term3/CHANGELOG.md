# Changelog

term3 versions follow [semver](https://semver.org); see [RELEASING.md](RELEASING.md).
Each release notes the Ghostty version it is built on.

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
