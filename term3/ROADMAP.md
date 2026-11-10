# term3 Roadmap: 0.1.0 Release and Rust Migration

This document outlines the roadmap for term3: stabilizing and releasing `0.1.0`
from the current Zig baseline, followed by launching a dedicated branch to
replace the Zig codebase with a modern, memory-safe Rust implementation.

---

## 1. Executive Summary

- **Core Mission:** A fast, native Linux terminal with one defining opinion:
  **tabs live in a vertical sidebar on the left**, paired with first-class GNOME
  Terminal aesthetics and defaults.
- **Immediate Milestone (0.1.0):** Complete the soak period for `0.1.0-rc.5`.
  If no regressions or blocking bugs are encountered over the next few days,
  tag and publish `term3-v0.1.0` as the definitive Zig-based release.
- **Next Milestone (Rust Replatforming):** Branch from `0.1.0` to eliminate Zig
  entirely, replacing it with an idiomatic Rust application built on
  `gtk4-rs`, `libadwaita-rs`, and a dedicated terminal engine.

---

## 2. Phase 0: Stabilization & 0.1.0 Release

### Soak Period (Current)
- Current candidate: `0.1.0-rc.5` (commit `d5875cebd`).
- Verification criteria during daily-driver use:
  - **Window Geometry:** Defaults to maximized; unmaximizing restores to large
    browser-proportioned dimensions (1200×800) without jitter.
  - **Sidebar Usability:** Stable tab dragging/reordering, uniform row heights,
    title overflow (`ellipsize`, `scroll`, `wrap`), and working-directory subtitles.
  - **Terminal Compatibility:** Private terminfo (`/usr/share/term3/terminfo`)
    and system terminfo (`/usr/share/terminfo/x/xterm-ghostty`) function properly
    across `sudo`, `su`, and remote SSH sessions.
  - **Visual Defaults:** GNOME desktop monospace font auto-detection, GNOME dark
    color palette, and block cursor.

### Release Steps for 0.1.0
1. Verify git working tree is clean and synced with remote.
2. Update version from `0.1.0-rc.5` to `0.1.0`:
   - `src/term3.zig` (`pub const version = "0.1.0"`)
   - `term3/CHANGELOG.md` (finalize 0.1.0 release notes)
3. Run test tiers:
   ```sh
   term3/tests/run.sh
   ```
4. Build release packages:
   - Debian package (`term3/scripts/build-deb.sh`)
   - RPM package (`term3/scripts/build-rpm.sh`)
5. Tag and push:
   - Tag: `term3-v0.1.0`
   - Push commit and tag to `origin/main`
6. Publish GitHub Release with `.deb`, `.rpm`, source tarballs, and SHA256 checksums.
7. Mark `term3-v0.1.0` as the immutable reference baseline for parity testing.

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
   changes (e.g., nightly 0.17 breaking changes) and ~380k lines of complex Zig
   internals that term3 does not need.
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

Instead of maintaining a multi-megabyte C/Zig engine, the Rust implementation
will structure term3 as a native Libadwaita application with a decoupled backend:

```
┌─────────────────────────────────────────────────────────┐
│                       term3                             │
│  (AdwApplication / Window / Maximize & Restore Geometry) │
├──────────────────────────┬──────────────────────────────┤
│    Vertical Tab Sidebar  │        Terminal View         │
│  (GhosttyTabSidebar in   │  (PTY + VT Emulation +       │
│   Rust / AdwTabView)     │   Text Grid & Font Shaping)  │
├──────────────────────────┴──────────────────────────────┤
│  Config Engine (term3 config + GSettings font monitor)  │
└─────────────────────────────────────────────────────────┘
```

#### Core Crates & Dependencies
- **UI / Desktop Integration:** `gtk4` (v4.14+), `libadwaita` (v1.5+), `gio`, `glib`.
- **PTY Management:** `portable-pty` or `nix` (forkpty, termios, signal handling).
- **Terminal Backend Options:**
  - *Option A (Direct VTE Integration via `vte-rs`):* Instant 100% VT parity,
    accessibility, font fallback, IME, and low maintenance.
  - *Option B (Pure Rust Terminal Core via `alacritty_terminal`):* GPU-accelerated
    rendering, standalone VT grid and parser, zero C runtime dependencies.
- **Config & IPC:** `serde`, `toml`, `zbus` (D-Bus single-instance & desktop integration).

---

## 5. Phase 2: Implementation Roadmap on `rust` Branch

### Milestone 1: Repository & Workspace Scaffolding
- [ ] Create and check out branch `rust` (or `feature/rust-rewrite`) from `term3-v0.1.0`.
- [ ] Set up Cargo workspace:
  ```
  crates/
  ├── term3/           # Application binary, CLI options, D-Bus activation
  ├── term3-ui/        # GTK4/Adw window, tab sidebar widget, templates
  ├── term3-config/    # Config file parser & GNOME GSettings font watcher
  └── term3-pty/       # Terminal emulation / PTY process supervisor
  ```
- [ ] Add `Cargo.toml`, CI workflow, and build verification (`cargo check`, `cargo test`).

### Milestone 2: Window Shell & Sidebar Widget
- [ ] Port the window template and default geometry:
  - Default to maximized on startup.
  - Unmaximized restore size set to 1200×800.
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

### Milestone 4: First-Class Graphical Configuration UI (`AdwPreferencesWindow`)

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
- [ ] **Direct Two-Way Config Synchronization:**
  - The UI reads and displays current runtime configuration.
  - Modifying controls automatically writes formatted, clean configuration
    directly to `~/.config/term3/config`.
  - Immediate hot-reload: Changes take effect instantly without restarting.
  - Text config preservation: Comments and custom keys are respected.
- [ ] **Hamburger Menu Integration:**
  - Direct "Preferences…" menu item (`Ctrl+,`) placed prominently in the
    primary hamburger menu.

### Milestone 5: Feature Parity & Test Validation
- [ ] Run parity checks comparing `term3` (Rust) against `term3-v0.1.0` (Zig):
  - Memory consumption and startup latency.
  - Sidebar resize and drag behavior under stress.
  - Shell integration, exit code handling, and process termination.
- [ ] Automated testing suite:
  - Unit tests for sidebar model and config parser.
  - Headless UI tests with `xvfb-run`.

### Milestone 6: Complete Zig Decommissioning
- [ ] Remove Zig source directory `src/`, `build.zig`, `build.zig.zon`, and `.zig-*`.
- [ ] Remove vendored Zig C libraries no longer required.
- [ ] Update packaging scripts (`build-deb.sh`, `build-rpm.sh`) to use `cargo`.
- [ ] Update documentation (`README.md`, `TERM3.md`, `SCOPE.md`, `HACKING.md`).
- [ ] Merge `rust` branch into `main`.
- [ ] Tag `term3-v0.2.0` (First Pure-Rust Release).

---

## 6. Milestones Summary

| Version / Branch | Focus | Key Deliverables |
| --- | --- | --- |
| **0.1.0-rc.5** *(main)* | Stabilization | Soak testing, verifying window size & terminfo fixes |
| **0.1.0** *(main)* | Milestone Release | Final Zig release tagged; `.deb` and `.rpm` published |
| **rust** (Branch) | Rust Scaffolding | Cargo workspace, GTK4/Adw shell, PTY setup |
| **rust** (Branch) | Sidebar Port | `TabSidebar` widget with reordering, overflow, & badges |
| **rust** (Branch) | Preferences UI | `AdwPreferencesWindow` for graphical settings |
| **0.2.0** *(main)* | Pure Rust Release | Zig fully removed; Rust replaces Zig on `main` |
