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
