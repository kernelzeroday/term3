# term3 Bug Tracker & Known Issues

This document tracks known issues, reproduction steps, technical investigations,
and status of bugs identified in term3 releases and release candidates.

---

## BUG-001: Unmaximizing window via header bar double-click places window partially off-screen (bottom-right)

- **Discovered:** 2026-11-10 (during 0.1.0-rc.5 soak testing)
- **Environment:** Debian 13 (Trixie), GNOME Shell 48.x (Mutter), Wayland session
- **Severity:** Low / Annoyance (recoverable via `<Super>+Up` or dragging titlebar)
- **Status:** Fixed in 0.1.0-rc.6 via deferred idle maximization (`glib.idleAddOnce`)

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

### Potential Solutions
1. **Deferred Maximization (Idle tick after map):**
   Allow the window to be presented (`gtk_window_present()`) so Mutter executes normal
   centered floating placement and records valid `saved_rect` coordinates, and then
   invoke `gtk_window_maximize()` via `g_idle_add` on the next main loop iteration.
2. **Default `maximize = false` with Large Initial Geometry:**
   Keep the default window size set to 80% screen / `1280×800` (browser proportions),
   but default `maximize = false`. This guarantees GNOME/Mutter centers the window
   cleanly on startup, and any subsequent manual maximize/unmaximize cycles retain the
   proper centered restore coordinates.
3. **Mutter / Desktop State Restoration:**
   Rely on GSettings session state or save/restore geometry across restarts rather
   than hardcoding `maximize` in the C/Zig initialization path.
