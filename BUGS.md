# term3 Bug Tracker & Known Issues

This document tracks known issues, reproduction steps, technical investigations,
and status of bugs identified in term3 releases and release candidates.

---

## BUG-001: Unmaximizing window via header bar double-click places window partially off-screen (bottom-right)

- **Discovered:** 2026-11-10 (during 0.1.0-rc.5 soak testing)
- **Environment:** Debian 13 (Trixie), GNOME Shell 48.x (Mutter), Wayland session
- **Severity:** Low / Annoyance (recoverable via `<Super>+Up` or dragging titlebar)
- **Status:** Fixed in 0.1.0-rc.7. rc.6 only avoided it by defaulting `maximize = false`; with Start Maximized enabled it still reproduced. See "Confirmed Root Cause & Fix (0.1.0-rc.7)" below.

### Description
When launching term3 with default settings (where `maximize = true` starts the
window maximized), double-clicking the top of the window (header bar) to
unmaximize it results in the restored floating window appearing displaced toward
the bottom-right of the screen, with approximately two-thirds of the window hanging
off-screen and only the upper-left quadrant remaining visible.

### Reproduction Steps
1. Launch term3 on GNOME under Wayland with default configuration (`maximize = true`).
2. The window opens fully maximized.
3. Double-click the header bar near the top to restore / unmaximize the window.
4. **Observed:** The window shrinks to its restored size (e.g. 1280×800 or 80% screen),
   but its coordinates are shifted heavily toward the bottom-right corner of the monitor,
   leaving ~2/3 of the window off-screen.
5. **Expected:** The restored window should be centered and completely visible on the display.

### Investigation & Root Cause
1. **Mutter Wayland Geometry Tracking:**
   Under Wayland, client applications have no direct control over global screen
   coordinates `(x, y)`; all placement is determined by the compositor (Mutter).
   Mutter maintains a cached `saved_rect` structure representing the window's
   unmaximized floating geometry (position and dimensions).
2. **Initial Map as Maximized:**
   In `0.1.0-rc.5`, `maximize = true` causes `gtk_window_maximize()` to be called
   during window initialization (`src/apprt/gtk/class/window.zig:409`) before the
   window is realized or presented.
   Because the window maps immediately in a maximized state, Mutter never performs
   initial floating window placement (`meta_window_place()`). Consequently, Mutter's
   `saved_rect` lacks a valid floating position.
3. **Double-Click Unmaximize Behavior:**
   When the user double-clicks the header bar to unmaximize, Mutter attempts to restore
   the window. Because no prior centered floating position was ever recorded, Mutter
   miscalculates the unmaximized anchor coordinates (often anchoring relative to the
   click position or unconstrained cascade offset), resulting in the window being placed
   far down and to the right.

### Why 0.1.0-rc.6 Fix (`glib.idleAddOnce`) Failed
In `0.1.0-rc.6`, initialization was changed to defer `maximize()` using `glib.idleAddOnce(idleMaximize, ...)`. Testing in 0.1.0-rc.6 confirmed that the bug still reproduced identically:
1. **GLib Idle Priority vs. Wayland IPC Handshake:**
   In GTK4 under Wayland, `gtk_window_present()` generates the initial Wayland requests
   (`wl_surface`, `xdg_surface`, `xdg_toplevel`) and flushes them to the Wayland socket.
   The compositor (Mutter in `gnome-shell`) runs in a separate process and responds asynchronously
   with `xdg_surface.configure`.
2. **Immediate Execution on First Main Context Iteration:**
   `glib.idleAddOnce` registers an idle source with `G_PRIORITY_DEFAULT_IDLE` (200).
   On the very first iteration of the GLib main loop (in `g_application_run`), idle sources
   run before the Wayland socket poll and event dispatch from Mutter complete.
3. **Mutter Receives Set-Maximized in the Initial Batch:**
   When `idleMaximize` calls `gtk_window_maximize()`, GTK emits `xdg_toplevel.set_maximized`.
   From Mutter's perspective, this request is received alongside the initial window creation
   batch *before* the window has ever mapped or drawn its initial frame. Mutter treats the
   window as initially maximized from frame 1, entirely bypassing `meta_window_place()`.
4. **The Flawed Alternative of Timed Delays:**
   Delaying maximization until after the window is actively rendered (e.g. via `g_timeout_add`
   after 300–500ms) would populate `saved_rect`, but causes an unacceptable visual glitch:
   every time term3 starts, the window would flash/pop up floating in the screen center and
   then abruptly jump to maximized a moment later.

### Evaluated Solutions & Recommended Path
1. **Option 1: Default `maximize = false` with 80% screen size (Recommended):**
   - Retain the browser-proportioned 80% screen width & height (`1280×800` fallback) default window geometry.
   - Set `maximize: bool = false` as default in `src/config/Config.zig`.
   - **Result:** Mutter maps the window floating, centers it cleanly on startup (honoring `org.gnome.mutter center-new-windows`), and populates `saved_rect` with valid centered coordinates. If the user later maximizes (via titlebar double-click, window controls, or `<Super>+Up`) and then unmaximizes, it returns perfectly to the center of the display with zero offset.
   - Conforms strictly to GNOME Human Interface Guidelines (HIG) and GNOME Terminal conventions (where no standard desktop terminal defaults to start maximized).
   - Preserves user choice: users who explicitly want new windows to open maximized can enable the stateful "Start Maximized" toggle in the hamburger "Settings" menu added in 0.1.0-rc.6.

2. **Option 2: Wayland / Mutter Session Geometry State Restoration:**
   - Rather than hardcoding window states in client initialization paths, rely on desktop session state or GSettings window state persistence.

### Confirmed Root Cause & Fix (0.1.0-rc.7)
Bisected on GNOME Shell 48.7 / Wayland, 1920×1200 at 100% scaling (fractional
scaling ruled out):

- An explicit `window-width`/`window-height` (which skips term3's 80% sizing
  block) still reproduced, so term3's sizing code is **not** the cause.
- `<Super>+Down` reproduced identically, so the header bar double-click is
  **not** the cause.
- A screenshot showed the restored window's top-left corner at the exact
  screen center (≈960, 600).
- With `org.gnome.mutter center-new-windows` set to `false` the window
  restored to the top-left corner (0, 0) instead.

So when a window is mapped already maximized, Mutter has no floating
geometry for it and places a zero-size rect on unmaximize: centered (top-left
corner at screen center, window hangs off the bottom-right) with
`center-new-windows = true`, or at the origin otherwise. Deferring the
`maximize()` call to an idle callback (rc.6) did not help because the
request still reached Mutter before the first frame was committed.

**Fix:** `src/apprt/gtk/class/window.zig` no longer calls `maximize()` during
init. With `maximize = true` it adds a frame-clock tick callback
(`maximizeAfterFirstFrame`) that maximizes on the second tick, i.e. after
the first floating frame has been committed and Mutter has placed the window
and recorded its floating geometry. Verified: unmaximize restores the window
centered and fully on screen, and the one-frame floating state is not
noticeable. `maximize = false` remains the default.

---

## BUG-002: CLI status bar playback triangles (U+23F5 ⏵) render as '?' replacement glyphs

- **Discovered:** 2026-11-10
- **Environment:** Debian 13 (Trixie), GNOME Shell 48.x, term3 0.1.0-rc.6
- **Severity:** Medium (missing glyphs / visual degradation in modern CLI tools like Claude Code / Antigravity)
- **Status:** Fixed in 0.1.0-rc.7 via Option 2 (`DeferredFace.Fontconfig.presentation()` requires `FC_COLOR` in addition to `und-zsye`). Workaround for older builds: `font-codepoint-map = U+23F4-U+23FA=Symbola`

### Description
When running CLI tools that display status indicators with playback symbols—such as
Claude Code's status bar:
```text
  ⏵⏵ bypass permissions on · 1 shell · esc to interrupt · ↓ to manage
```
the indicator characters `⏵` (Unicode `U+23F5 BLACK MEDIUM RIGHT-POINTING TRIANGLE`)
fail to render in term3 and instead display as `?` glyphs:
```text
  ?? bypass permissions on · 1 shell · esc to interrupt · ↓ to manage
```
The remaining characters (`·` `U+00B7`, `↓` `U+2193`) render normally.

In contrast, **GNOME Terminal renders this string completely and cleanly**, confirming
that the system has the requisite fonts and that the failure is caused by term3's font
fallback/filtering pipeline.

### Reproduction Steps
1. Launch `term3` alongside `gnome-terminal`.
2. In both terminals, execute:
   ```bash
   printf "  \u23f5\u23f5 bypass permissions on \u00b7 1 shell \u00b7 esc to interrupt \u00b7 \u2193 to manage\n"
   ```
3. **Observed in term3:** The two `⏵` symbols render as question mark `?` icons (Unicode Replacement Character `U+FFFD`).
4. **Observed in gnome-terminal:** The two `⏵` symbols render as crisp, solid right-pointing triangles `⏵⏵`.
5. **Expected:** term3 should render the fallback glyph identically to GNOME Terminal.

### Investigation & Technical Root Cause

1. **Why GNOME Terminal Works:**
   - GNOME Terminal / VTE uses Pango and HarfBuzz for text shaping and font fallback.
   - Tracing Pango's itemizer (`pango_itemize`) for `U+23F5` under `Monospace 11`:
     ```text
     Item offset 0 len 1 font: Symbola Semi-Condensed 12
     ```
     Pango queries Fontconfig, receives `Symbola` (`/usr/share/fonts/truetype/ancient-scripts/Symbola_hint.ttf`, installed via `fonts-symbola`), verifies that the glyph exists in `Symbola`, and renders it.

2. **Why term3 Rejects the Exact Same Font:**
   - Under Fontconfig, term3's `disco.discoverFallback()` creates a pattern with `FC_CHARSET = { 0x23F5 }` and runs `FcFontSort()`.
   - Running `FcFontSort()` with term3's exact query pattern confirms that **`Symbola` is returned as match #0**:
     ```text
     [0] Symbola (Symbola_hint.ttf): has_cp=1, has_und_zsye=1
     [1] DejaVu Sans Mono (DejaVuSansMono.ttf): has_cp=0
     ...
     ```
   - When term3 inspects match #0 (`Symbola`) in `src/font/CodepointResolver.zig`, it checks `face.hasCodepoint(cp, p_mode)`:
     ```zig
     // src/font/DeferredFace.zig:342-353
     const emoji_lang = "und-zsye";
     const is_emoji = switch (fc.langset) {
         .lang_set => |ls| ls.hasLang(emoji_lang),
         .string => |s| std.mem.eql(u8, s, emoji_lang),
         else => |v| false,
     };
     const actual: Presentation = if (is_emoji) .emoji else .text;
     return desired == actual;
     ```
   - Because `Symbola` includes Unicode emoji blocks, Fontconfig tags `Symbola` with the language tag `und-zsye` (Emoji script).
   - `DeferredFace` assumes that *any* font whose `langset` includes `und-zsye` is strictly an `.emoji` font (`actual = .emoji`), ignoring that it is an outline text font (`FC_COLOR = False`) supporting hundreds of scripts and mathematical/technical symbols.
   - For `U+23F5`, `desired` is `.text` (`uucode.get(.is_emoji_presentation, 0x23F5) == false`).
   - Because `desired (.text) != actual (.emoji)`, `DeferredFace.hasCodepoint()` returns `false` and **discards `Symbola`**!
   - None of the remaining candidate fonts in the Fontconfig result set contain `U+23F5`. Discovery ends with `no fallback face found for cp=23F5`.

3. **Shaper Fallback to `U+FFFD`:**
   - When discovery returns no face, `src/font/shaper/run.zig:231-236` substitutes `0xFFFD` (Unicode Replacement Character ``).
   - In `DejaVu Sans Mono`, `0xFFFD` renders as `?` inside a box/diamond glyph, producing the visible `?` icons.

4. **Absence of Built-in Sprite Fallback:**
   - While term3 / Ghostty includes a vector sprite renderer (`src/font/sprite/`) for common terminal symbols (Box Drawing, Block Elements, Braille, Powerline, legacy computing), `U+23F4..U+23F7` (medium triangles) are not currently implemented.

### Evaluated Solutions & Recommended Fixes

1. **Option 1: Add Sprite Rasterization for `U+23F4..U+23F7` (Recommended):**
   - Implement draw functions in `src/font/sprite/draw/` (e.g. in `geometric_shapes.zig` or a new `technical.zig`) for:
     - `U+23F4` (`⏴` BLACK MEDIUM LEFT-POINTING TRIANGLE)
     - `U+23F5` (`⏵` BLACK MEDIUM RIGHT-POINTING TRIANGLE)
     - `U+23F6` (`⏶` BLACK MEDIUM UP-POINTING TRIANGLE)
     - `U+23F7` (`⏷` BLACK MEDIUM DOWN-POINTING TRIANGLE)
   - **Benefits:**
     - Completely self-contained: works regardless of which system fonts are installed or what OS/distro is running.
     - Crisp, pixel-aligned vector rendering scaled to cell metrics.
     - Eliminates reliance on external fallback fonts for CLI AV playback symbols.

2. **Option 2: Correct Presentation Detection in `DeferredFace.zig`:**
   - Under `.fontconfig_freetype`, check `FC_COLOR` rather than relying solely on `und-zsye` in `langset`, or do not restrict a font to `.emoji` only if it also contains text languages/scripts.
   - Enables multi-purpose symbol fonts like `Symbola` to satisfy `.text` presentation fallback queries.

3. **Combined Approach:**
   - Implement Option 1 to give built-in, zero-dependency support for `U+23F4..U+23F7`, and Option 2 to fix general Fontconfig fallback for other non-color symbol fonts.

---

## BUG-003: Tabs can't be dragged between windows, or torn off into a new window

- **Discovered:** 2026-11-10
- **Environment:** All (GTK sidebar, `gtk-tabs-location = left|right`)
- **Severity:** Medium / Missing feature vs. stock Ghostty and iTerm2
- **Status:** Fixed (unreleased); needs manual testing on GNOME Wayland and X11.

### Description
Dragging a sidebar row onto another term3 window's sidebar did nothing, and
dropping it outside any window didn't open a new window. Stock Ghostty's
`Adw.TabBar` does both; the sidebar that replaces it only reordered tabs.

### Root Cause
`listDrop` in `src/apprt/gtk/class/tab_sidebar.zig` deliberately rejected pages
from other tab views ("aren't ours to reorder"), and the row's `DragSource`
had no `drag-cancel` handler, so drops onto nothing just snapped back.

### Fix
- A drop from another window's sidebar moves the tab with
  `Adw.TabView.transferPage`. The PTY and surface move with it and nothing
  restarts. A source window left with no tabs closes itself (`tabViewNPages`).
- `drag-cancel` with reason `no_target` tears the tab off into a new window
  (`Window.moveTabPageToNewWindow`), the way `Adw.TabBar` does. Escape still
  cancels. The only tab in a window isn't torn off.

### Limitation (by design)
This only works between windows of **one term3 process**. A tab owns a live
PTY and renderer state, which can't move to another process; iTerm2 has the
same limit, but it always runs as one process. With the default
`gtk-single-instance = detect`, desktop launches share one process, but running
`term3` from a shell starts a **separate** one, so tabs can't move between its
windows and the others. Set `gtk-single-instance = true` to avoid that.

### Manual Test
1. Open two windows (Ctrl+Shift+N) with two or more tabs each.
2. Drag a row from window A onto a row in window B: the tab is inserted above
   that row, selected, and still running.
3. Drag a row below B's last row: it's appended.
4. Drag A's last tab to B: A closes.
5. Drag a row onto the desktop: it opens in a new window. Esc mid-drag: snaps back.

---

## BUG-004: New tabs inherit the prior tab's working directory instead of starting in user home

- **Discovered:** 2026-11-15
- **Environment:** All
- **Severity:** Low / UX preference
- **Status:** Fixed (unreleased).

### Description
Opening a new tab currently inherits the working directory of the previously active tab rather than starting in the user's home directory (`~`).

### Expected Behavior
New tabs should default to starting in the user's home directory rather than inheriting the prior tab's working directory.

### Fix
`tab-inherit-working-directory` now defaults to `false` in
`src/config/Config.zig`, so a new tab starts in the `working-directory`
default, like iTerm2 and GNOME Terminal. `tab-inherit-working-directory = true`
restores Ghostty's behavior.

- **Desktop launch** (the usual case): `working-directory` resolves to home,
  so new tabs open in `~`.
- **Launched from a shell:** Ghostty's `working-directory` default is
  `inherit`, i.e. the directory term3 was started in, so new tabs open there,
  not in `~`. Set `working-directory = home` to always get `~`.
- New windows and splits still inherit. The ROADMAP's 0.3.0 "Traditional
  Terminal Defaults" item covers those.

---

## BUG-005: Missing drag-and-drop animations and mid-flight drop indicator on left tab sidebar

- **Discovered:** 2026-11-15
- **Environment:** All (GTK sidebar, `gtk-tabs-location = left|right`)
- **Severity:** Medium / UX degradation
- **Status:** Open

### Description
When dragging and dropping tabs to rearrange them on the left tab sidebar, there are no drag-and-drop animations or clear mid-flight visual indicators showing where the tab will land upon release. This makes it difficult to predict the resulting tab order before letting go.

### Expected Behavior
During a drag-and-drop rearrangement on the tab sidebar, an insertion/drop-target indicator (and/or row displacement animation) should clearly show mid-flight where the dragged tab will be placed when released.

---

## BUG-006: Flickering when adjusting the left tab sidebar width

- **Discovered:** 2026-11-15
- **Environment:** All (GTK sidebar, `gtk-tabs-location = left|right`)
- **Severity:** Medium / Visual glitch
- **Status:** Open

### Description
Resizing / adjusting the width of the left tab sidebar causes visible flickering during the adjustment.

### Expected Behavior
Adjusting the left tab sidebar width should resize smoothly without flickering.

---

## BUG-007: Tab label is not properly centered when only the directory is displayed

- **Discovered:** 2026-11-15
- **Environment:** All (GTK sidebar, `gtk-tabs-location = left|right`)
- **Severity:** Low / Visual polish
- **Status:** Open

### Description
When a tab in the sidebar displays only the directory (without the program name), the text is not properly centered vertically/visually within the tab row.

### Expected Behavior
When only the directory is displayed on a tab (no program name), the label should be properly centered within the tab.

---

## BUG-008: Super+Arrow keybindings never reach term3 on GNOME

- **Discovered:** 2026-11-15
- **Environment:** GNOME Shell (Mutter), Wayland and X11
- **Severity:** Medium / Missing feature vs. iTerm2 (Cmd+Arrow navigation)
- **Status:** Prototype implemented (unreleased); needs manual testing on GNOME Wayland.

### Description
I'd like to bind `super+arrow` keys in term3 (e.g. `keybind = super+left=previous_tab`,
or split/pane navigation), the way iTerm2 uses Cmd+Arrow. On GNOME those keys
never reach the app: Mutter handles them first.

### Why It Doesn't Work Today
GNOME's window manager owns these combos by default:
- `<Super>Up` / `<Super>Down`: `org.gnome.desktop.wm.keybindings maximize` / `unmaximize`
- `<Super>Left` / `<Super>Right`: `org.gnome.mutter.keybindings toggle-tiled-left` / `toggle-tiled-right`
- `Super` alone: `org.gnome.mutter overlay-key` (Activities overview on release)

Compositor keybindings are matched before key events are sent to the focused
client, so term3's keybind table never sees them.

### Chosen Direction: Wayland keyboard-shortcuts-inhibit (passthrough)
Freeing the keys with `gsettings` is ruled out (it's global and pushes setup
onto users). A different default modifier is also out, since Super+Arrows is
the point. The plan is for term3 to request passthrough itself.

GTK4 exposes `zwp_keyboard_shortcuts_inhibit_v1` through
`gdk_toplevel_inhibit_system_shortcuts()` /
`gdk_toplevel_restore_system_shortcuts()`, and Mutter implements it (VNC/RDP
clients and VMs use it). While it's active, Mutter forwards its own shortcuts
to the focused window. term3 already gets the window's `gdk.Toplevel` in
`src/apprt/gtk/class/window.zig` (around line 1169), so that's where the call
would go.

Open questions:
- **All or nothing:** it inhibits *every* WM shortcut (Alt+Tab, Super for the
  overview, workspace switching), not just Super+Arrows. It's scoped to the
  focused term3 window, though, so clicking another window gets them back.
  There's no way to hand an unbound combo back to Mutter, so this needs
  real-use testing to see if losing Alt+Tab while term3 is focused is
  acceptable.
- **Permission dialog:** Mutter asks once per app ("allow term3 to inhibit
  shortcuts?"). The answer is remembered by the permission store. If denied,
  `shortcuts-inhibited` stays false and term3 should fall back gracefully.
- **Escape hatch:** Super+Escape (`org.gnome.mutter.wayland.keybindings
  restore-shortcuts`) always cancels the inhibit. term3 has to re-request it
  (watch `gdk.Toplevel:shortcuts-inhibited`).
- **When to inhibit:** always while focused, or only when the config has a
  `super+` keybind that collides with a WM shortcut. Decided: a config
  option, on by default (always inhibit while focused).
- **X11:** no equivalent short of a full keyboard grab; X11 stays as-is.

### Prototype
- New config option `gtk-inhibit-system-shortcuts` (default `true`), with a
  checkable **Settings > Capture System Shortcuts** item in the hamburger menu
  (`app.toggle-inhibit-system-shortcuts`). The menu item applies the change to
  every open window right away and saves it to the config file, the same way
  "Start Maximized" does (both now use `term3.setConfigBool`).
- `Window.syncShortcutsInhibit` (`src/apprt/gtk/class/window.zig`) calls
  `gdk_toplevel_inhibit_system_shortcuts` the first time the window is active
  with the option on, and `gdk_toplevel_restore_system_shortcuts` when it's
  turned off. Changes to `shortcuts-inhibited` are logged at info level.
- iTerm2's default Cmd shortcuts are now default super keybinds on Linux,
  taken from iTerm2's `MainMenu.xib` and `DefaultGlobalKeyMap.plist`
  (`super+left/right` switch tabs, `super+shift+left/right` move the tab,
  `super+up/down` scroll a line, plus `super+t/w/c/v/...`; see
  `Keybinds.init` in `src/config/Config.zig`), so no config is needed to test.

### Manual Test (GNOME Wayland)
1. (Defaults already bind `super+left`/`super+right` to previous/next tab.)
2. Settings > Capture System Shortcuts is on by default. Mutter asks whether
   to allow it; allow. The log shows `system shortcuts inhibited=true`.
3. Super+Left/Right switch tabs instead of tiling the window; Super+Up/Down
   don't maximize it.
4. Focus another app: Super+Arrows tile it as usual. Refocus term3: they go
   back to term3.
5. Super+Escape: GNOME's shortcuts work in term3 again until it's refocused.
6. Untick the menu item: GNOME's shortcuts work in term3 immediately.
7. Restart term3: the menu item and behavior persist.


### Only inhibit while Super is held
Holding the inhibit for as long as term3 was focused also swallowed the
media and brightness keys (gsd-media-keys grabs go through Mutter's
keybinding table) and GNOME's Ctrl+Alt+Left/Right workspace switching.
Since the protocol is all or nothing, `syncShortcutsInhibit` now holds it
only while Super is down in an active term3 window. It watches the seat
keyboard's `gdk.Device:modifier-state` (fed by `wl_keyboard.modifiers`,
which Mutter sends even though it consumes the Super press) and requests
the inhibit on Super press, drops it on release or focus loss.

- The Super press itself still reaches Mutter, which marks the overlay key
  as pressed alone; Mutter keeps handling its release regardless of the
  inhibit, so tapping Super still opens Activities.
- While Super is held, every GNOME Super shortcut goes to term3, bound or
  not (Super+A, Super+V, Super+Alt+Arrows).
- Race: the request has to round-trip (and gnome-shell checks the
  permission store over D-Bus) before the arrow press arrives. Fine for
  normal typing; pressing both keys at the exact same instant may still
  tile the window.

Manual test: media/brightness keys and Ctrl+Alt+Left/Right work with term3
focused; Super+Left/Right still switch tabs; tapping Super opens Activities;
Alt+Tab works.

---

## BUG-009: No way to see the keyboard shortcuts from the UI

- **Discovered:** 2026-11-15
- **Environment:** All (GTK)
- **Severity:** Low / Missing feature vs. iTerm2 and GNOME apps
- **Status:** Fixed (unreleased); needs manual testing.

### Description
The only ways to see which keys do what were the config file and
`term3 +list-keybinds`. GNOME apps put a Keyboard Shortcuts window in the
main menu.

### Fix
Main menu > **Keyboard Shortcuts** (just above About, `win.shortcuts`) opens
a dialog listing every keybind in the current config, one row per action:
the command palette's title, the config action name (e.g. `goto_tab:3`) as
the subtitle, and each binding as keycaps, one per line. Rows are grouped
into Tabs, Windows, Splits, Copy and Paste, Scrolling and Selection, Search,
Font Size, Terminal and Application, and the dialog's search filters by title.
Leader sequences show as `Ctrl+A › C`. `ignore`/`unbind` are left out.

- Data: `src/term3_shortcuts.zig` (GTK-free, unit tested:
  `zig build test -Dtest-filter="term3: shortcuts"`).
- Dialog: `src/apprt/gtk/shortcuts_dialog.zig`, an `Adw.PreferencesDialog`
  (`Adw.ShortcutsDialog` needs libadwaita 1.8; term3 supports 1.7).
- No default keybind yet (GNOME uses Ctrl+?); that needs a new core action.

### Manual Test
1. Main menu > Keyboard Shortcuts. The dialog opens with grouped rows.
2. Search "tab": only matching rows remain.
3. Add `keybind = ctrl+a>c=new_split:right` and reload config: reopening the
   dialog shows `Ctrl+A › C` under Splits.

## BUG-010: A fast Super+V opens GNOME's notification list and every tab stops taking keys

- **Discovered:** 2026-11-25
- **Environment:** GNOME Shell 51 (Mutter), Wayland, `gtk-inhibit-system-shortcuts = true`
- **Severity:** High / Looks like a hang: no tab responds to Enter, arrows or Ctrl combos
- **Status:** Fixed by the opt-in `gtk-defuse-gnome-shortcuts` (Settings > "Defuse Clashing GNOME Shortcuts"); reproduced and covered by `term3/tests/gnome.sh`.

### Description
Paste with Super+V into a terminal (seen in Claude Code): the paste may or may
not appear, then Enter, arrows and Ctrl combos do nothing, in every tab. Typing
other keys or clicking around eventually brings it back.

### Cause
Since e6a361386 term3 only holds the keyboard-shortcuts inhibit while Super is
down, and it can only request it after it has seen the Super press. When V
follows within a few milliseconds (a fast, rolled Super+V; more often while the
main thread is busy, e.g. with streaming output), Mutter matches Super+V before
the inhibit exists and runs GNOME's `toggle-message-tray`. The notification
list opens with keyboard focus on its Clear button, so every key goes to the
shell popup instead of term3 until it closes. term3's main thread stays idle in
`poll` throughout; nothing is hung. In the headless test a gap of 0–5 ms loses
the race and 10 ms wins it.

The race can't be closed from term3: the inhibit is all or nothing, and holding
it whenever a window is focused (the pre-e6a361386 behaviour) swallows media,
brightness and Ctrl+Alt+Arrow keys.

### Fix
`gtk-defuse-gnome-shortcuts` (default off, since it changes the desktop's own
settings, see BUG-008) removes only the GNOME shortcuts that clash with term3's
own super keybinds *and* open something that takes keyboard focus: `<Super>v`
(notification list; `<Super>m` keeps it), `<Super>a` (app grid), `<Super>n`
(focus notification) and `<Super><Alt>Up/Down` (overview). A combo that then
wins the race has nothing to trigger in GNOME, so the key reaches term3 and the
paste still happens. term3 records what it removed in
`$XDG_STATE_HOME/term3/defused-gnome-shortcuts` and, when turned off, puts back
only that (resetting a key to GNOME's default when that's what it adds up to).
Other clashes (e.g. Super+Left/Right tiling) can still lose the race, but they
only run GNOME's action and don't take the keyboard.
