# term3

A Linux terminal with one opinion: **tabs live in a vertical sidebar on the
left**, like iTerm2. Everything else is upstream Ghostty.

term3 is a small, easy-to-merge fork of [Ghostty](https://github.com/ghostty-org/ghostty)'s
GTK4/libadwaita app. The patch touches the tab UI only; terminal emulation,
rendering, fonts, config, shell integration, splits, etc. are Ghostty's.

## The sidebar

- Tabs are rows in a vertical list beside the terminal, below the header bar.
- Rows have a fixed, uniform height, so the window doesn't change shape as
  tabs are added or retitled. With `window-show-tab-bar = auto` the sidebar
  still shows with a single tab, so the terminal doesn't jump sideways when
  the second tab opens.
- Resize by dragging the sidebar's inner edge.
- Reorder by dragging rows.
- Click to switch, middle-click to close, hover for the close button,
  right-click for "Change Tab Title…" / "Close Tab".
- A dot marks tabs that rang the bell while in the background.

### Config

| Key | Values | Default |
| --- | --- | --- |
| `gtk-tabs-location` | `left`, `right`, `top`, `bottom` | `left` |
| `gtk-sidebar-width` | pixels (80–800) | `220` |
| `gtk-sidebar-title-overflow` | `ellipsize`, `scroll`, `wrap` | `ellipsize` |
| `gtk-sidebar-title-lines` | lines for `wrap` (1–8) | `2` |
| `gtk-sidebar-subtitle` | `working-directory`, `none` | `working-directory` |

- `ellipsize`: one line, cut off with "…"; full title in the tooltip.
- `scroll`: one line; a long title scrolls horizontally while hovered.
- `wrap`: up to N lines. Every row reserves N lines so rows stay uniform.

`top`/`bottom` give stock Ghostty behaviour. With the sidebar,
`gtk-titlebar-style = tabs` acts like `native` (there's no tab bar to merge
into the titlebar).

## Project docs

| Doc | What |
| --- | --- |
| [term3/SCOPE.md](term3/SCOPE.md) | What term3 is and isn't, the test for new features, and the roadmap |
| [term3/RELEASING.md](term3/RELEASING.md) | Versioning, tags (`term3-vX.Y.Z`), the release checklist, upstream merges |
| [term3/VENDORING.md](term3/VENDORING.md) | Every bundled dependency, what's system vs bundled, and the unvendoring plan |
| [term3/TESTING.md](term3/TESTING.md) | Test tiers: unit, property, smoke, headless GUI, valgrind |
| [term3/CHANGELOG.md](term3/CHANGELOG.md) | Release notes |

## Where the code is

| File | What |
| --- | --- |
| `src/apprt/gtk/class/tab_sidebar.zig` | The `GhosttyTabSidebar` widget |
| `src/apprt/gtk/ui/1.0/tab-sidebar.blp` | Its template |
| `src/apprt/gtk/class/window.zig` | Wiring: `sidebar-visible`, placement, options |
| `src/apprt/gtk/ui/1.4/window.blp` | Sidebar placed beside the terminal area |
| `src/apprt/gtk/css/style.css` | `term3` section at the end |
| `src/config/Config.zig` | The options above, system-font default, term3 config tests |
| `src/term3.zig` | term3 version and pure sidebar logic, with unit and property tests |
| `src/apprt/gtk/term3_system_font.zig` | Reads GNOME's monospace font |
| `term3/` | Docs, icon source, packaging, scripts, tests |

The sidebar holds no tab state of its own. It renders `AdwTabView`'s page
model (`adw_tab_view_get_pages`) and sends every action (select, close,
reorder) back to the tab view. Ghostty's existing logic (close confirmation,
titles, bell, new-tab position, keybinds) keeps working unchanged.

## Building

Requirements (Fedora):

```sh
sudo dnf install gtk4-devel libadwaita-devel blueprint-compiler libX11-devel gtk4-layer-shell-devel
```

Zig must match `minimum_zig_version` in `build.zig.zon` (currently 0.17.x;
Fedora ships 0.16, so use the upstream tarball from ziglang.org).

```sh
zig build -Doptimize=ReleaseFast  # release build -> zig-out/bin/term3
zig build                         # debug build (slow, shows a warning)
```

## Identity

| | term3 |
| --- | --- |
| Binary | `term3` |
| App ID | `io.github.kernelzeroday.term3` (D-Bus, desktop file, icon, WM class) |
| Config | `~/.config/term3/config` (Ghostty's format; a Ghostty config can be copied over as-is) |
| Themes | `~/.config/term3/themes/` |
| Terminfo | `/usr/share/term3/terminfo` (private; `TERMINFO` points here, so `TERM=xterm-ghostty` always resolves) |

term3 doesn't collide with a stock Ghostty install. What deliberately
stays "ghostty" for compatibility: `TERM=xterm-ghostty`, `TERM_PROGRAM`,
the `GHOSTTY_*` environment variables and shell integration (programs use
these to detect terminal features), the shared resources directory, and
internal names in the source.

## Staying current with upstream

`main` is upstream Ghostty plus term3 commits on top.

```sh
git fetch upstream
git merge upstream/main
```

Merge, don't rebase: release tags stay valid and `main` never needs a
force-push. See [term3/RELEASING.md](term3/RELEASING.md).

## Research notes (2026-11-09)

Why this shape, and not the alternatives:

- **libghostty.** The public, stable library is `libghostty-vt` (1.0 released
  2026-11-06): VT parsing, terminal state, render-state snapshots, key/mouse
  encoding, selection, search. It has **no renderer, font stack, or PTY**.
  The full embedding API (`include/ghostty.h`, "libghostty-internal")
  supports only macOS/iOS and is documented as not for external use. A GTK
  widget library is planned upstream but doesn't exist yet. So the only way
  to get Ghostty's renderer on Linux today is the Ghostty GTK app itself.
- **gnome-terminal.** It's now GTK4 + libadwaita + VTE (not GTK3). Its tabs
  are `AdwTabView` + `AdwTabBar`, the same building blocks as Ghostty's GTK
  app, so the sidebar change would be the same in either. Forking it would
  mean keeping VTE (no libghostty) or replacing VTE with libghostty-vt plus
  a hand-written renderer, font shaping, IME, selection, and a11y. That's
  far more work than the feature warrants.
- **AdwTabBar** is horizontal only, and libadwaita has no vertical tab
  widget, so the sidebar is our own widget bound to the `AdwTabView` model.
- **Upstream Ghostty** closed the vertical-tabs request (discussion #2549)
  and points to forks. Several exist (e.g. geremyturcotte/ghostty-linux-vertical-tabs,
  RIvance/ghostty-with-sidebar), which confirms the approach. term3 keeps
  its patch minimal so rebasing stays cheap.
- **Language.** The GTK app is Zig, so the patch is Zig. Writing the widget in
  Rust (gtk4-rs, linked as a static lib) is possible but would add a second
  toolchain and a cross-language GObject boundary for a few hundred lines,
  and make upstream merges harder. Standalone tooling around term3 can be Rust.
- **Platform.** Fedora Asahi (aarch64, 16k pages) is supported by Zig 0.17
  and libghostty-vt's tier-1 Linux aarch64 target.

## Not doing

Splits/tmux reimplementation, session restore, AI features, profiles UI.
Those are out of scope. The opinion is the tab bar placement.
