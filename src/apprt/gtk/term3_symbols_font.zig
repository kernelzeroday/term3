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
//!
//! A font added this way does not survive the font map rebuilding its font
//! list: `pango_fc_font_map_cache_clear` rebuilds it from Fontconfig alone.
//! GTK does that whenever the system fonts change (installing a package
//! that ships fonts bumps `gtk-fontconfig-timestamp`, and GTK then calls
//! `pango_fc_font_map_config_changed`), after which tab titles show
//! missing-glyph boxes until term3 restarts. The rebuild announces itself
//! through the font map's `GListModel::items-changed` signal, before GTK
//! lays the labels out again, so the font is added back from there.

const std = @import("std");
const builtin = @import("builtin");

const embedded = @import("../../font/embedded.zig");

const log = std.log.scoped(.term3_symbols_font);

/// The family name inside the embedded font, used to tell whether the font
/// map still has it.
const family_name = "Symbols Nerd Font";

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
const GetFamily = *const fn (
    font_map: *anyopaque,
    name: [*:0]const u8,
) callconv(.c) ?*anyopaque;
const SignalConnectData = *const fn (
    instance: *anyopaque,
    detailed_signal: [*:0]const u8,
    handler: *const fn () callconv(.c) void,
    data: ?*anyopaque,
    destroy_data: ?*anyopaque,
    flags: c_uint,
) callconv(.c) c_ulong;
const ItemsChanged = *const fn (
    font_map: *anyopaque,
    position: c_uint,
    removed: c_uint,
    added: c_uint,
    data: ?*anyopaque,
) callconv(.c) void;

/// Everything needed to add the font again later. Only touched on the GTK
/// main thread, which is where the font map emits its signals.
var state: struct {
    add_font_file: AddFontFile,
    get_family: GetFamily,
    path_buf: [64]u8 = undefined,
    path: [:0]const u8 = "",
    /// True while adding the font, which itself emits `items-changed`.
    adding: bool = false,
} = undefined;

fn lookup(comptime T: type, name: [:0]const u8) ?T {
    return @ptrCast(@alignCast(std.c.dlsym(rtld_default, name) orelse return null));
}

/// Register the embedded symbols font with Pango's default font map, and keep
/// it registered when the font map is rebuilt. Failure is only cosmetic, so
/// it is logged and otherwise ignored.
pub fn register() void {
    const get_default = lookup(GetDefaultFontMap, "pango_cairo_font_map_get_default") orelse
        return unavailable();
    const add_font_file = lookup(AddFontFile, "pango_font_map_add_font_file") orelse
        return unavailable();
    // Both exist in every Pango that has pango_font_map_add_font_file.
    const get_family = lookup(GetFamily, "pango_font_map_get_family") orelse
        return unavailable();
    const connect = lookup(SignalConnectData, "g_signal_connect_data") orelse
        return unavailable();
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

    state = .{ .add_font_file = add_font_file, .get_family = get_family };
    state.path = std.fmt.bufPrintSentinel(&state.path_buf, "/proc/self/fd/{d}", .{fd}, 0) catch unreachable;
    if (!add(font_map)) {
        log.warn("pango rejected the embedded symbols font", .{});
        _ = std.c.close(fd);
        return;
    }

    const handler: ItemsChanged = &onItemsChanged;
    _ = connect(font_map, "items-changed", @ptrCast(handler), null, null, 0);
}

fn add(font_map: *anyopaque) bool {
    state.adding = true;
    defer state.adding = false;
    return state.add_font_file(font_map, state.path.ptr, null) != 0;
}

/// Puts the font back after the font map rebuilds its list without it.
fn onItemsChanged(
    font_map: *anyopaque,
    _: c_uint,
    _: c_uint,
    _: c_uint,
    _: ?*anyopaque,
) callconv(.c) void {
    if (state.adding) return;
    if (state.get_family(font_map, family_name) != null) return;
    if (add(font_map)) {
        log.debug("font map was rebuilt, symbols font registered again", .{});
    } else {
        log.warn("pango rejected the embedded symbols font after a font change", .{});
    }
}

fn unavailable() void {
    log.info("pango font registration unavailable, icons in tab titles may not render", .{});
}
