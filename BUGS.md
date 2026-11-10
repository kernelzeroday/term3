# term3 Bug Tracker & Known Issues

This document tracks known issues, reproduction steps, technical investigations,
and status of bugs identified in term3 releases and release candidates.

---

## BUG-001: Unmaximizing window via header bar double-click places window partially off-screen (bottom-right)

- **Discovered:** 2026-11-10 (during 0.1.0-rc.5 soak testing)
- **Environment:** Debian 13 (Trixie), GNOME Shell 48.x (Mutter), Wayland session
- **Severity:** Low / Annoyance (recoverable via `<Super>+Up` or dragging titlebar)
- **Status:** Resolved in 0.1.0-rc.6 via Option 1 (default `maximize = false` with 80% screen restore geometry and Settings UI toggle)

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
