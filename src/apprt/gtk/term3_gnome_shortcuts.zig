//! term3: `gtk-defuse-gnome-shortcuts`. Removes the GNOME shortcuts that
//! clash with term3's super keybinds and open something that takes keyboard
//! focus (`term3.gnome_defuse_shortcuts`), and puts back exactly what it
//! removed when the setting is turned off.
//!
//! What was removed is recorded in `$XDG_STATE_HOME/term3/defused-gnome-shortcuts`
//! (one `schema<TAB>key<TAB>accel` line each), so a restore never re-adds a
//! shortcut term3 didn't take away. Safe off GNOME: schemas or keys that
//! aren't installed are skipped (g_settings_new() would abort on them).

const std = @import("std");
const gio = @import("gio");
const glib = @import("glib");

const term3 = @import("../../term3.zig");

const log = std.log.scoped(.term3_gnome_shortcuts);

/// Bring GNOME's shortcuts in line with the setting. Idempotent, so it runs
/// at startup and on every config load: if GNOME's settings were reset
/// meanwhile, defusing again removes the shortcuts again.
pub fn apply(alloc: std.mem.Allocator, defuse: bool) void {
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const result = if (defuse) defuseAll(arena) else restoreAll(arena);
    result catch |err| log.warn("failed to {s} GNOME shortcuts: {s}", .{
        if (defuse) "defuse" else "restore",
        @errorName(err),
    });
    gio.Settings.sync();
}

fn defuseAll(arena: std.mem.Allocator) !void {
    const path = try statePath(arena);
    var removed: std.ArrayList(term3.GnomeShortcut) = .empty;

    // Keep earlier records: an accelerator removed by a previous run is no
    // longer in GNOME's list, so this run wouldn't see it again.
    if (try readFile(arena, path)) |old| {
        var it: term3.DefuseStateIterator = .init(old);
        while (it.next()) |e| try removed.append(arena, e);
    }
    const before = removed.items.len;

    for (term3.gnome_defuse_shortcuts) |s| {
        const settings = open(arena, s.schema, s.key) orelse continue;
        defer settings.unref();
        const list = try getStrv(arena, settings, s.key);
        const i = term3.findAccel(list, s.accel) orelse continue;
        const spelled = list[i]; // record GNOME's own spelling, e.g. <Mod4>V
        const out = (try term3.removeAccel(arena, list, s.accel)).?;
        try setStrv(arena, settings, s.key, out);
        log.info("defused GNOME shortcut {s} {s} {s}", .{ s.schema, s.key, spelled });
        try removed.append(arena, .{ .schema = s.schema, .key = s.key, .accel = spelled });
    }

    if (removed.items.len != before) {
        try writeFile(arena, path, try term3.formatDefuseState(arena, removed.items));
    }
}

fn restoreAll(arena: std.mem.Allocator) !void {
    const path = try statePath(arena);
    const state = try readFile(arena, path) orelse return;
    var it: term3.DefuseStateIterator = .init(state);
    while (it.next()) |e| {
        const settings = open(arena, e.schema, e.key) orelse continue;
        defer settings.unref();
        const list = try getStrv(arena, settings, e.key);
        // Bound again meanwhile (by the user or a reset): leave it alone.
        const out = (try term3.addAccel(arena, list, e.accel)) orelse continue;
        // Back to GNOME's own default: reset the key rather than store a
        // reordered copy, so it follows future changes to the default again.
        const key_z = try arena.dupeSentinel(u8, e.key, 0);
        if (try defaultStrv(arena, settings, key_z)) |def| if (term3.sameAccelSet(out, def)) {
            settings.reset(key_z);
            log.info("restored GNOME shortcut {s} {s} to its default", .{ e.schema, e.key });
            continue;
        };
        try setStrv(arena, settings, e.key, out);
        log.info("restored GNOME shortcut {s} {s} {s}", .{ e.schema, e.key, e.accel });
    }
    const z = try arena.dupeSentinel(u8, path, 0);
    if (glib.unlink(z) != 0) log.warn("could not remove {s}", .{path});
}

/// The settings object for `schema`, or null if `schema` or its `key` isn't
/// installed (not GNOME, or an older GNOME without that shortcut).
fn open(arena: std.mem.Allocator, schema_id: []const u8, key: []const u8) ?*gio.Settings {
    const id = arena.dupeSentinel(u8, schema_id, 0) catch return null;
    const key_z = arena.dupeSentinel(u8, key, 0) catch return null;
    const source = gio.SettingsSchemaSource.getDefault() orelse return null;
    const schema = source.lookup(id, 1) orelse return null;
    defer schema.unref();
    if (schema.hasKey(key_z) == 0) return null;
    return gio.Settings.new(id);
}

fn getStrv(arena: std.mem.Allocator, settings: *gio.Settings, key: []const u8) ![]const []const u8 {
    const key_z = try arena.dupeSentinel(u8, key, 0);
    const raw: [*:null]?[*:0]u8 = @ptrCast(settings.getStrv(key_z));
    defer glib.strfreev(raw);
    const items = std.mem.sliceTo(raw, null);
    const out = try arena.alloc([]const u8, items.len);
    for (items, out) |item, *o| o.* = try arena.dupe(u8, std.mem.span(item.?));
    return out;
}

/// The schema's default value for a strv `key`.
fn defaultStrv(arena: std.mem.Allocator, settings: *gio.Settings, key: [:0]const u8) !?[]const []const u8 {
    const v = settings.getDefaultValue(key) orelse return null;
    defer v.unref();
    const raw = v.getStrv(null);
    defer glib.free(@ptrCast(@constCast(raw)));
    const items = std.mem.sliceTo(raw, null);
    const out = try arena.alloc([]const u8, items.len);
    for (items, out) |item, *o| o.* = try arena.dupe(u8, std.mem.span(item.?));
    return out;
}

fn setStrv(arena: std.mem.Allocator, settings: *gio.Settings, key: []const u8, list: []const []const u8) !void {
    const key_z = try arena.dupeSentinel(u8, key, 0);
    const arr = try arena.allocSentinel(?[*:0]const u8, list.len, null);
    for (list, arr) |item, *a| a.* = try arena.dupeSentinel(u8, item, 0);
    if (settings.setStrv(key_z, @ptrCast(arr.ptr)) == 0) return error.SettingNotWritable;
}

fn statePath(arena: std.mem.Allocator) ![]const u8 {
    const dir = std.mem.span(glib.getUserStateDir());
    return std.fs.path.join(arena, &.{ dir, "term3", "defused-gnome-shortcuts" });
}

fn readFile(arena: std.mem.Allocator, path: []const u8) !?[]const u8 {
    const z = try arena.dupeSentinel(u8, path, 0);
    var contents: [*]u8 = undefined;
    var len: usize = 0;
    var err: ?*glib.Error = null;
    if (glib.fileGetContents(z, &contents, &len, &err) == 0) {
        if (err) |e| e.free();
        return null; // No record: nothing was removed.
    }
    defer glib.free(contents);
    return try arena.dupe(u8, contents[0..len]);
}

fn writeFile(arena: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const dir = try arena.dupeSentinel(u8, std.fs.path.dirname(path) orelse return error.BadPath, 0);
    if (glib.mkdirWithParents(dir, 0o700) != 0) return error.MkdirFailed;
    const z = try arena.dupeSentinel(u8, path, 0);
    var err: ?*glib.Error = null;
    if (glib.fileSetContents(z, data.ptr, @intCast(data.len), &err) == 0) {
        if (err) |e| {
            log.warn("could not write {s}: {s}", .{ path, e.f_message orelse "?" });
            e.free();
        }
        return error.WriteFailed;
    }
}
