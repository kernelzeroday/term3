//! term3: read the desktop's monospace font so term3 matches GNOME
//! Terminal's default profile, which uses the system monospace font.
//!
//! The result is handed to the core config (`Config.term3_system_font`),
//! which applies it only to font options the user hasn't set.

const std = @import("std");
const gio = @import("gio");
const glib = @import("glib");

const configpkg = @import("../../config.zig");
const term3 = @import("../../term3.zig");

const log = std.log.scoped(.term3_system_font);

const schema_id = "org.gnome.desktop.interface";
const key = "monospace-font-name";

/// Storage for the family name; the config keeps a slice into it.
var family_buf: [256]u8 = undefined;

/// Read the system monospace font and publish it to the config module.
/// Safe on non-GNOME desktops: if the schema or key isn't installed, the
/// config keeps Ghostty's defaults. Call before loading config.
pub fn refresh() void {
    configpkg.Config.term3_system_font = read();
}

fn read() ?term3.SystemFont {
    // g_settings_new() aborts the process if the schema is missing, so
    // look it up first.
    const source = gio.SettingsSchemaSource.getDefault() orelse return null;
    const schema = source.lookup(schema_id, 1) orelse return null;
    defer schema.unref();
    if (schema.hasKey(key) == 0) return null;

    const settings = gio.Settings.new(schema_id);
    defer settings.unref();
    const value = settings.getString(key);
    defer glib.free(value);

    const font = term3.parseFontName(std.mem.span(value)) orelse {
        log.warn("unable to parse {s}={s}", .{ key, value });
        return null;
    };
    if (font.family.len > family_buf.len) return null;
    @memcpy(family_buf[0..font.family.len], font.family);
    log.debug("system monospace font family={s} size={d}", .{ font.family, font.size });
    return .{ .family = family_buf[0..font.family.len], .size = font.size };
}
