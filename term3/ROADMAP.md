# term3 Roadmap

`0.1.0` is out. It is the stable Zig release, built on Ghostty. Next comes a
Rust rewrite (`0.2.0`) that ships the features we have today and nothing more:
the app becomes Rust, and Ghostty's terminal engine stays, used through
libghostty-vt's C API. The rewrite has not started.
After that, `0.3.0` adds a settings UI and the behavior changes that need it.
`0.4.0` may take on native tmux integration.

---

## 1. Executive Summary

- **The idea:** a GNOME Terminal-style successor to iTerm2. See
  [SCOPE.md](SCOPE.md) for how that guides defaults.
- **Core Mission:** A fast, native Linux terminal with one defining opinion:
  **tabs live in a vertical sidebar on the left**, paired with first-class GNOME
  Terminal aesthetics and defaults.
- **0.1.0 (released):** Stable Zig-based release, tagged `term3-v0.1.0` and
  promoted from `0.1.0-rc.7` after daily use on several machines and CPU
  architectures (x86_64 and aarch64). Remaining rough edges are mostly upstream
  design choices or GNOME limitations, not bugs.
- **0.2.0 (Rust rewrite, feature-frozen):** Replace term3's Zig application
  with an idiomatic Rust application on `gtk4-rs` and `libadwaita-rs`, keeping
  Ghostty's terminal engine through **libghostty-vt** (C API). Zig remains
  only as the build dependency for libghostty-vt (see section 4).
  **The 0.2.0 feature set is locked to the parity baseline:** the last Zig
  release, cut from main when the `rust` branch starts (section 5). New
  features and behavior changes after that wait for 0.3.0.
- **0.3.0 (Settings & behavior):** A proper graphical settings UI, plus
  behavior changes that should become user options rather than hardcoded
  choices, starting with whitespace selection (see section 7). Also the
  **session server**: an iTerm2-style client/server architecture, so tabs can
  move between any windows and shells outlive the UI.
- **0.4.0 (maybe: native tmux integration):** iTerm2-style tmux integration.
  Large and complex, so not committed to (see section 8).

---

## 2. Phase 0: 0.1.0 Release (Complete)

- Released as `term3-v0.1.0` (from `0.1.0-rc.7`, no code changes).
- Artifacts: `.rpm` (Fedora), `.deb` (Debian/Ubuntu),
  SRPM, source tarball, vendored Zig dependency tarball, and `SHA256SUMS`.
- `term3-v0.1.0` was the original parity baseline. It is superseded: main
  has shipped features since (see the baseline list in section 5), so 0.2.0
  is measured against the last Zig release instead.
- Known limitations carried forward (not bugs): see `BUGS.md` and section 7.

---

## 3. Why Migrate from Zig to Rust?

While the initial term3 prototype was built as a patch on Ghostty's Zig codebase,
replacing Zig with Rust provides long-term advantages:

1. **First-Class GTK4 / Libadwaita Ecosystem:**
   `gtk4-rs` and `libadwaita-rs` are official, exceptionally well-maintained GNOME
   bindings with type-safe GObject subclassing, signals, memory management, and
   macros. Writing GTK widgets in Zig requires verbose manual C ABI wrapping.
2. **Decoupling from Upstream Ghostty Churn:**
   Tracking Ghostty upstream requires tracking bleeding-edge Zig compiler
   changes (e.g., nightly 0.17 breaking changes) and ~400k lines of Zig, of
   which term3's own changes are ~3.3k. Most of it (the GTK app layer, fonts,
   renderer, config) term3 does not need from Ghostty; the part it does need,
   the terminal engine, is available on its own as libghostty-vt.
3. **Ecosystem & Tooling:**
   Rust's Cargo ecosystem provides standard cross-compilation, packaging tools
   (`cargo-deb`, `cargo-generate-rpm`), memory safety, concurrency primitives,
   and standard testing frameworks out of the box.
4. **Scope Alignment:**
   term3's scope is strictly a native Linux GTK4 terminal with a vertical tab
   sidebar. A focused Rust app achieves this with a fraction of the complexity
   and zero build-system fragility.

---

## 4. Phase 1: Architecture & Technical Strategy

### Architectural Choice: Standalone Rust App (`term3-rs`)

term3 becomes a native Libadwaita application written in Rust. The terminal
engine (VT parsing, screen and scrollback state, selection, search, key and
mouse encoding) is Ghostty's, used as a library through libghostty-vt's C API
rather than as term3 source:

```
┌─────────────────────────────────────────────────────────┐
│                       term3                             │
│  (AdwApplication / Window / Maximize & Restore Geometry) │
├──────────────────────────┬──────────────────────────────┤
│    Vertical Tab Sidebar  │        Terminal View         │
│  (TabSidebar in Rust /   │  (Rust renderer, fonts,      │
│   AdwTabView)            │   input; PTY supervisor)     │
├──────────────────────────┴──────────────────────────────┤
│  Config Engine (term3 config + GSettings font monitor)  │
├─────────────────────────────────────────────────────────┤
│  libghostty-vt (Zig, C ABI): VT parser, screen state,   │
│  selection, search, key/mouse encoding, render snapshot │
└─────────────────────────────────────────────────────────┘
```

#### Core Crates & Dependencies
- **UI / Desktop Integration:** `gtk4` (v4.14+), `libadwaita` (v1.5+), `gio`, `glib`.
- **PTY Management:** `portable-pty` or `nix` (forkpty, termios, signal handling).
- **Terminal Engine (decided): libghostty-vt.** A `term3-vt-sys` crate binds
  `include/ghostty/vt/*.h`; a safe `term3-vt` crate wraps it. This keeps
  Ghostty's VT behavior exactly (kitty keyboard and graphics protocols,
  `xterm-ghostty` terminfo, selection and search semantics), so parity with
  the Zig release is about the app, not the emulator.
  - The engine draws nothing: term3 still writes its own renderer and font
    shaping on top of libghostty-vt's render snapshots.
  - Its C API is young and may change; pin the libghostty-vt version.
- **Rejected engines:**
  - *`vte-rs` (VTE):* fastest to parity for basic use, but no kitty keyboard
    or graphics protocol, no `xterm-ghostty`, and VTE's widget owns the
    terminal state, which blocks moving that state into 0.3.0's session server.
  - *`alacritty_terminal`:* pure Rust, but different VT behavior from what
    0.1.x users have, so parity testing would mostly measure emulator
    differences.
- **Config:** read the existing Ghostty-style `key = value` file at
  `~/.config/term3/config` (including `keybind = ...` syntax), not TOML.
  Users' configs must keep working unchanged.
- **IPC:** `zbus` (D-Bus single-instance & desktop integration).

### Where Zig Remains

Zig stays only to build libghostty-vt. No term3 code is written in Zig after
0.2.0, and nothing in the Rust crates depends on Zig beyond linking the
library.
- Build libghostty-vt from a pinned Ghostty source in `build.rs`
  (`zig build -Demit-lib-vt`), or link a system/prebuilt `libghostty-vt`
  when one is available. The Zig toolchain becomes a build dependency of one
  crate, not of the app.
- Packaging (RPM/deb) still vendors the Zig compiler for that one step.
- **Long term:** replace libghostty-vt with a Rust engine when one can match
  its behavior, at which point Zig leaves the build entirely. Not scheduled;
  the session server (0.3.0) should land first, since it fixes where the
  engine lives.

---

## 5. Phase 2 (0.2.0): Implementation Roadmap on `rust` Branch

**Feature freeze:** 0.2.0 re-implements the parity baseline's features and
behavior, including upstream behaviors we disagree with (such as whitespace
selection). Anything new goes in section 7 (0.3.0), not here.

### Parity Baseline

The baseline is **the last Zig release, cut from main when the `rust` branch
starts** (tag it, for example `term3-v0.1.1`, before branching). Until then,
features keep landing on main and are added to the list below. Everything
here must work in 0.2.0:

- **From 0.1.0:** see SCOPE.md's "In scope" table (sidebar, title overflow,
  working-directory subtitle, GNOME font/colors/cursor, window sizing,
  identity, packaging).
- **Since 0.1.0:**
  - Drag tabs between windows and tear them off into a new window (BUG-003;
    within one process).
  - "Capture System Shortcuts" (`gtk-inhibit-system-shortcuts`, default on):
    Wayland keyboard-shortcuts-inhibit so `super+` combos reach term3 (BUG-008).
  - iTerm2 default shortcuts on `super` (~77 bindings, including
    `performable` ones that fall through to the program, e.g. `super+c`
    with no selection), with the ctrl+shift binding still shown in menus;
    toggle "iTerm2 Shortcuts" (`iterm-keybinds`, default on).
  - Keyboard Shortcuts dialog listing every configured keybind, grouped and
    searchable (BUG-009).
  - Copy on select, default `both`; toggle "Copy on Select".
  - New tabs start in the default working directory
    (`tab-inherit-working-directory = false`, BUG-004).
  - `maximize = true` by default.
  - Settings menu: each toggle persists to the config file and applies
    immediately; checkboxes resync after a config reload.
- **Inherited Ghostty behavior term3 relies on** (easy to miss because it is
  free today): the keybind engine (`performable`, chains, key tables,
  reverse mapping for menu accelerators), splits (create, navigate, resize,
  zoom), search, prompt jumping via shell integration, OSC 7 working
  directory, private `xterm-ghostty` terminfo, config reload (soft and hard).

### Milestone 1: Repository & Workspace Scaffolding
- [ ] Tag the parity baseline on main, then create branch `rust` (or
      `feature/rust-rewrite`) from it.
- [ ] Set up Cargo workspace:
  ```
  crates/
  ├── term3/           # Application binary, CLI options, D-Bus activation
  ├── term3-ui/        # GTK4/Adw window, tab sidebar widget, templates
  ├── term3-config/    # Ghostty-format config parser & GSettings font watcher
  ├── term3-pty/       # PTY process supervisor
  ├── term3-vt-sys/    # libghostty-vt C bindings + build.rs (Zig build step)
  └── term3-vt/        # Safe Rust wrapper over term3-vt-sys
  ```
- [ ] Add `Cargo.toml`, CI workflow, and build verification (`cargo check`, `cargo test`).

### Milestone 2: Window Shell & Sidebar Widget
- [ ] Port the window template and default geometry:
  - Match term3: `maximize` defaults to true; the
    "Start Maximized" menu toggle persists it. A maximized window maximizes after its first frame,
    so unmaximize restores on-screen (BUG-001).
  - Unmaximized size matches 0.1.0 (80% of the screen, 1280×800 fallback).
- [ ] Implement `TabSidebar` widget in Rust:
  - Vertical list of tabs bound to `AdwTabView` pages.
  - Fixed-height uniform rows.
  - Inner drag handle for resizing width (`gtk-sidebar-width`, 80–800px).
  - Drag-and-drop row reordering.
  - Tab interactions: click to switch, middle-click to close, hover close button,
    right-click context menu ("Change Tab Title...", "Close Tab").
  - Bell indicator dot for inactive tabs that sent an alert.
- [ ] Title overflow handling:
  - `ellipsize`: single line with ellipsis, full title in tooltip.
  - `scroll`: marquee text animation on hover.
  - `wrap`: multi-line title wrapping up to N configured lines.
- [ ] Working directory subtitles:
  - Extract and display cwd; hide when already prominent in tab title.

### Milestone 3: Terminal Emulation & PTY Engine

**Architecture constraint (not a feature):** keep the PTY and terminal state
behind an interface that doesn't assume it lives in the UI process. 0.2.0
still runs everything in one process, but 0.3.0's session server (section 7)
must be able to move this layer into a separate process without another
rewrite.
- [ ] Build and link libghostty-vt (`term3-vt-sys`); wrap terminal
      creation, feeding PTY output, resize, key/mouse encoding, selection,
      search and render snapshots in `term3-vt`.
- [ ] Renderer: draw libghostty-vt render snapshots in a GTK widget (font
      shaping, glyph cache, cursor, selection highlight).
- [ ] Integrate PTY and terminal session supervisor:
  - PTY allocation with correct window dimensions (`winsize`).
  - Signal handling (`SIGWINCH`, `SIGHUP`, `SIGCHLD`).
  - Shell launch with user's login shell and clean environment.
- [ ] Set up environment variables and terminfo:
  - `TERM=xterm-ghostty` or `term3` with private terminfo fallback.
  - `COLORTERM=truecolor`.
- [ ] Cursor and visual defaults:
  - Default to solid block cursor.
  - Palette default to GNOME dark theme colors.
- [ ] Dynamic font integration:
  - Read `org.gnome.desktop.interface monospace-font-name` via GSettings.
  - React live to system font changes without restarting.

### Milestone 4: Feature Parity & Test Validation
- [ ] Walk the Parity Baseline list feature by feature.
- [ ] Run parity checks comparing `term3` (Rust) against the baseline tag (Zig):
  - Memory consumption and startup latency.
  - Sidebar resize and drag behavior under stress.
  - Shell integration, exit code handling, and process termination.
- [ ] Automated testing suite:
  - Unit tests for sidebar model and config parser.
  - Headless UI tests with `xvfb-run`.

### Milestone 5: Complete Zig Decommissioning
- [ ] Remove term3's Zig application: `src/` (except what libghostty-vt
      builds from, if vendored), `build.zig`, `build.zig.zon`, and `.zig-*`.
- [ ] Remove vendored Zig C libraries no longer required.
- [ ] Update packaging scripts (`build-deb.sh`, `build-rpm.sh`) to use
      `cargo`, keeping the Zig toolchain only for the libghostty-vt build.
- [ ] Update documentation (`README.md`, `TERM3.md`, `SCOPE.md`, `HACKING.md`).
- [ ] Merge `rust` branch into `main`.
- [ ] Tag `term3-v0.2.0` (first Rust release; Zig only inside libghostty-vt).

---

## 6. Milestones Summary

| Version / Branch | Focus | Key Deliverables |
| --- | --- | --- |
| **0.1.0** *(main)* | Stable Zig release | Tagged `term3-v0.1.0`; `.deb`, `.rpm`, sources published |
| **0.1.x** *(main)* | Parity baseline | Last Zig release, tagged when the `rust` branch starts |
| **rust** (Branch) | Rust scaffolding | Cargo workspace, GTK4/Adw shell, PTY setup, libghostty-vt bindings |
| **rust** (Branch) | Sidebar port | `TabSidebar` widget with reordering, overflow, & badges |
| **rust** (Branch) | Parity | Feature-for-feature match with the baseline tag |
| **0.2.0** *(main)* | Rust release | App in Rust; Zig only builds libghostty-vt; **no new features** |
| **0.3.0** *(main)* | Settings, behavior & session server | Preferences window; traditional defaults (new shells in `$HOME`, whitespace selection); client/server sessions |
| **0.4.0** *(maybe)* | tmux integration | Native tmux windows/panes as term3 tabs and splits |

---

## 7. Phase 3 (0.3.0): Settings UI & Behavior Options

0.3.0 is the first release that adds features on top of the Rust codebase.
Its theme: behavior we disagree with becomes a user-visible option, not a
hardcoded choice.

### Whitespace Selection

**Current behavior (inherited from Ghostty):** selection only highlights and
copies cells that contain text. Trailing blank cells at the end of a line,
and empty lines, are not highlighted, so a selection looks ragged like a word
processor's, not a rectangle of terminal cells.

**Why change it:** a terminal is a grid of cells, not a document. Seeing
exactly which cells are selected is clearer, and it matches GNOME Terminal,
iTerm2, and most other terminals. We may come to like the current behavior,
but so far it feels like an upstream design choice we disagree with, not a
term3 opinion.

**Plan:**
- [ ] Add an option (for example `selection-include-whitespace = true|false`)
      controlling whether blank cells inside a selection are highlighted.
- [ ] Decide separately whether trailing whitespace is also *copied*, or only
      highlighted and still trimmed on copy (most terminals trim on copy).
- [ ] Expose it in the settings UI under Terminal Behavior.
- [ ] Pick the default after trying both; leaning toward highlighting whitespace.

### Traditional Terminal Defaults

Ghostty changes several long-standing terminal conventions. term3 expects to
restore most of them as defaults in 0.3.0, keeping Ghostty's behavior as an
option. Each one listed here is configurable today in `~/.config/term3/config`;
0.3.0 changes the default and exposes the setting in the settings UI.

| Behavior | Ghostty default | Planned term3 default | Option |
| --- | --- | --- | --- |
| New window/tab/split starts in the previous terminal's directory | inherit | start in `$HOME` | `window-`, `tab-`, `split-inherit-working-directory` |
| Selection highlights only text, not whitespace | text only | highlight cells (see above) | new option, TBD |

- [ ] **TODO: start new windows, tabs and splits in `$HOME`.** Default
      `window-inherit-working-directory`, `tab-inherit-working-directory` and
      `split-inherit-working-directory` to `false`. Tabs are done (BUG-004);
      windows and splits remain.
- [ ] **TODO: highlight whitespace in selections** (see Whitespace Selection).
- [ ] Flip each default in term3's config defaults, with a config test.
- [ ] Add toggles to the settings UI (General page for working directory).
- [ ] Note each changed default in the 0.3.0 changelog, so users who prefer
      Ghostty's behavior know which line restores it.
- [ ] Keep adding rows here as more conventions come up during daily use.

### Session Server (Client/Server Architecture)

**The iTerm2 idea:** shells don't belong to a window. iTerm2 keeps each
session's shell in a long-running server process, separate from the windows
that draw it. That is what lets tabs move freely between windows and lets
sessions survive the app restarting or crashing.

**Today (0.1.0, and 0.2.0 by design):** each term3 process owns its PTYs and
terminal state. Tabs can be dragged between windows only within one process
(BUG-003), so a `term3` started from a shell can't exchange tabs with the
desktop-launched one, and quitting term3 kills every shell.

**Plan for 0.3.0:**
- [ ] A per-user term3 session server owns the PTYs, child processes and
      terminal state (screen, scrollback, modes). It starts on demand and is
      reached over a Unix socket in `$XDG_RUNTIME_DIR`.
- [ ] Windows are clients: they render a session and send input and resizes.
      Any window of any term3 process can show any session.
- [ ] Drag a tab to any term3 window, regardless of which process opened it;
      this removes BUG-003's one-process limit and the `gtk-single-instance`
      workaround.
- [ ] Shells keep running when the UI quits or crashes; reopening term3
      reattaches them (iTerm2's session restoration). Whether quitting the
      app should also end its sessions becomes a setting.
- [ ] Decide what lives where: rendering stays in the client; the server
      keeps the terminal state needed to redraw a reattached session.

**Open questions:**
- [ ] One server per user, or one per session (iTerm2 has used both)?
- [ ] Protocol: our own versus an existing multiplexer model (WezTerm's mux,
      tmux control mode). This overlaps with 0.4.0's tmux integration, which
      would plug tmux in as another kind of session source.
- [ ] Security: socket permissions, and making sure only the user's own
      clients can attach.

### Settings UI: First-Class Graphical Configuration (`AdwPreferencesWindow`)

A primary motivation for term3's user-centric design is eliminating the
requirement to manually edit raw config files for basic preferences. Upstream
Ghostty forces users into text-only config files (`~/.config/ghostty/config`),
neglecting a proper desktop preferences dialog. term3 treats a native,
intuitive graphical settings interface as a tier-1 feature.

- [ ] **Native Libadwaita Preferences Window (`AdwPreferencesWindow`):**
  - **General Page:**
    - "Start Windows Maximized" switch (backed by `maximize = true/false`).
    - Default window geometry inputs (columns/rows or width/height).
    - Single-instance activation and new window shortcuts.
  - **Tabs & Sidebar Page:**
    - Sidebar placement selector: Left or Right (`gtk-tabs-location`).
    - Sidebar width slider: 80px to 800px (`gtk-sidebar-width`).
    - Tab title overflow options: `ellipsize`, `scroll` (hover marquee), or `wrap`.
    - Title wrap line count spinner: 1 to 8 lines (`gtk-sidebar-title-lines`).
    - Working-directory subtitle toggle: `working-directory` vs `none`.
  - **Appearance & Font Page:**
    - "Use System Monospace Font" toggle (syncing live with GNOME desktop settings).
    - Custom font picker (`GtkFontDialogButton`) when system font is unchecked.
    - Color palette & theme chooser (GNOME Dark default, light mode variant).
    - Cursor shape selector: Block (default), I-Beam, Underline.
  - **Terminal Behavior Page:**
    - Scrollback buffer depth.
    - Bell actions: Visual bell, audible bell, and tab notification dot.
    - Copy & paste behavior (copy-on-select toggle).
    - Selection: highlight whitespace toggle (see Whitespace Selection above).
- [ ] **Direct Two-Way Config Synchronization:**
  - The UI reads and displays current runtime configuration.
  - Modifying controls automatically writes formatted, clean configuration
    directly to `~/.config/term3/config`.
  - Immediate hot-reload: Changes take effect instantly without restarting.
  - Text config preservation: Comments and custom keys are respected.
- [ ] **Hamburger Menu Integration:**
  - Direct "Preferences…" menu item (`Ctrl+,`) placed prominently in the
    primary hamburger menu.

---

## 8. Phase 4 (0.4.0, maybe): Native tmux Integration

**Status: a maybe.** It is the iTerm2 feature most worth carrying over, but
it is large and complex. We decide after 0.3.0 whether to commit to it.

**What it means:** like iTerm2's `tmux -CC`, term3 talks to tmux in control
mode and shows tmux windows and panes as native term3 tabs (in the sidebar)
and splits, not as tmux's own drawn status bar and borders. Detaching and
reattaching, including over SSH, brings the same tabs back.

**Why it's big:**
- A control-mode client: parse tmux's `%`-notification protocol, keep a model
  of sessions, windows and panes, and send commands back.
- Mapping tmux layouts onto term3 tabs and splits in both directions: resizes,
  splits, closes and reorders made in term3 have to reach tmux, and changes
  made in tmux have to show up in term3.
- Feeding each pane's output into its own terminal, with scrollback history
  fetched from tmux when attaching.
- Edge cases: tmux version differences, nested sessions, slow links, and
  attaching to a session that's already open elsewhere.

**Open questions (to answer before committing):**
- [ ] Can tmux be another session source behind 0.3.0's session server, so
      tmux panes and local sessions share the same tab and split UI?
- [ ] How much is achievable on the Rust codebase, and is there a reusable
      control-mode crate or do we write our own?
- [ ] Minimum viable version: attach and show windows as tabs only, with
      splits later?
- [ ] Which iTerm2 tmux behaviors do long-time users actually rely on?
