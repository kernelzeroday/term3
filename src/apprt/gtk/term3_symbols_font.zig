//! term3: make the embedded Symbols Nerd Font available to GTK.
//!
//! The terminal grid falls back to this font for Nerd Font icons, but GTK
//! labels (tab titles, the tab sidebar, tooltips) go through Pango, which
//! only knows about installed fonts. Without this, a title containing an
//! icon such as U+F0674 renders as a missing-glyph box.
//!
//! Registration goes through Pango rather than Fontconfig directly because
//! term3 may statically link its own Fontconfig, which is a separate
//! instance from the one Pango uses. The Pango symbols are looked up at
//! runtime because `pango_font_map_add_font_file` needs Pango 1.56 and older
//! distros should still start, just without icons in their tab titles.

const std = @import("std");
const builtin = @import("builtin");

const embedded = @import("../../font/embedded.zig");

const log = std.log.scoped(.term3_symbols_font);

/// The `RTLD_DEFAULT` pseudo-handle, which Zig's std doesn't define on Linux.
const rtld_default: ?*anyopaque = switch (builtin.os.tag) {
    .freebsd => @ptrFromInt(@as(usize, @bitCast(@as(isize, -2)))),
    else => null,
};

const GetDefaultFontMap = *const fn () callconv(.c) ?*anyopaque;
const AddFontFile = *const fn (
    font_map: *anyopaque,
    filename: [*:0]const u8,
    err: ?*anyopaque,
) callconv(.c) c_int;

/// Register the embedded symbols font with Pango's default font map. Failure
/// is only cosmetic, so it is logged and otherwise ignored.
pub fn register() void {
    const get_default: GetDefaultFontMap = @ptrCast(@alignCast(std.c.dlsym(
        rtld_default,
        "pango_cairo_font_map_get_default",
    ) orelse return unavailable()));
    const add_font_file: AddFontFile = @ptrCast(@alignCast(std.c.dlsym(
        rtld_default,
        "pango_font_map_add_font_file",
    ) orelse return unavailable()));
    const font_map = get_default() orelse return unavailable();

    // Pango reopens the font by path whenever it needs it, so the descriptor
    // stays open for the life of the process. It must be close-on-exec so
    // that shells started by the terminal don't inherit it.
    const fd = std.c.memfd_create("term3-symbols-nerd-font", 1); // MFD_CLOEXEC
    if (fd < 0) {
        log.warn("unable to create memfd for symbols font", .{});
        return;
    }

    var remaining: []const u8 = embedded.symbols_nerd_font;
    while (remaining.len > 0) {
        const n = std.c.write(fd, remaining.ptr, remaining.len);
        if (n <= 0) {
            log.warn("unable to write symbols font to memfd", .{});
            _ = std.c.close(fd);
            return;
        }
        remaining = remaining[@intCast(n)..];
    }

    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "/proc/self/fd/{d}", .{fd}, 0) catch unreachable;
    if (add_font_file(font_map, path.ptr, null) == 0) {
        log.warn("pango rejected the embedded symbols font", .{});
        _ = std.c.close(fd);
    }
}

fn unavailable() void {
    log.info("pango font registration unavailable, icons in tab titles may not render", .{});
}
