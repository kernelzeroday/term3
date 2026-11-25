//! term3: identity and pure, toolkit-independent logic.
//!
//! Everything here is free of GTK so it can be unit- and property-tested
//! with `zig build test -Dtest-filter=term3` without a display. The GTK
//! sidebar (src/apprt/gtk/class/tab_sidebar.zig) calls into this module.

const std = @import("std");

/// term3's own release version (semver). This is independent of Ghostty's
/// version, which stays as upstream's because programs use it (via
/// XTVERSION and friends) to detect terminal features.
///
/// Pre-releases use semver's `-rc.N` form; see term3/RELEASING.md.
/// `term3/scripts/version.sh` reads this line, so keep it a single literal.
pub const version = "0.1.0";

/// Which side of the window the tab sidebar is on.
pub const Side = enum { left, right };

/// Width limits for the tab sidebar, in pixels.
pub const min_width: i32 = 80;
pub const max_width: i32 = 800;

/// Clamp a requested sidebar width into the allowed range.
pub fn clampWidth(width: i64) i32 {
    return @intCast(std.math.clamp(width, min_width, max_width));
}

/// The sidebar width while dragging its resize handle: the width at the
/// start of the drag plus the pointer's horizontal travel, where travel
/// toward the terminal grows the sidebar. The handle is on the right edge
/// of a left sidebar and the left edge of a right sidebar.
pub fn dragWidth(start_width: i32, offset_x: f64, side: Side) i32 {
    const travel: f64 = switch (side) {
        .left => offset_x,
        .right => -offset_x,
    };
    if (!std.math.isFinite(travel)) return clampWidth(start_width);
    const clamped = std.math.clamp(travel, -@as(f64, max_width), @as(f64, max_width));
    return clampWidth(@as(i64, start_width) + @as(i64, @intFromFloat(clamped)));
}

/// The number of title lines in `wrap` mode, clamped to 1...8.
pub fn clampTitleLines(lines: u8) u8 {
    return std.math.clamp(lines, 1, 8);
}

/// The horizontal scroll ("marquee") of an overflowing title in `scroll`
/// mode. One cycle is: hold at the start, scroll at a constant speed to
/// the end, hold at the end, then jump back to the start.
pub const Marquee = struct {
    pause_start_s: f64 = 0.8,
    pause_end_s: f64 = 1.2,
    speed_px_per_s: f64 = 50.0,

    /// The length of one full cycle, in seconds.
    pub fn cycle(self: Marquee, overflow_px: f64) f64 {
        return self.pause_start_s + overflow_px / self.speed_px_per_s + self.pause_end_s;
    }

    /// The scroll offset in pixels, `elapsed_s` seconds after the pointer
    /// entered, for a title `overflow_px` pixels wider than its space.
    /// Always within [0, overflow_px]; 0 when nothing overflows.
    pub fn offset(self: Marquee, elapsed_s: f64, overflow_px: f64) f64 {
        if (!(overflow_px > 0) or !std.math.isFinite(overflow_px)) return 0;
        if (!(elapsed_s > 0) or !std.math.isFinite(elapsed_s)) return 0;
        const t = @mod(elapsed_s, self.cycle(overflow_px));
        return std.math.clamp(
            (t - self.pause_start_s) * self.speed_px_per_s,
            0,
            overflow_px,
        );
    }
};

/// Whether a tab's working-directory subtitle would just repeat its title.
/// Shells commonly title the terminal with the directory ("~/code"), or
/// with a prefix such as "user@host:~/code" or "user@host: ~/code". The
/// subtitle is redundant if the title is the directory (as shown, `~`
/// form, or full path), or ends with it right after a ':' or a space.
pub fn subtitleRepeatsTitle(title: []const u8, pwd_display: []const u8, pwd_full: []const u8) bool {
    const t = std.mem.trim(u8, title, " \t");
    for ([_][]const u8{ pwd_display, pwd_full }) |p| {
        if (p.len == 0) continue;
        if (std.mem.eql(u8, t, p)) return true;
        if (t.len > p.len and std.mem.endsWith(u8, t, p)) {
            const before = t[t.len - p.len - 1];
            if (before == ':' or before == ' ') return true;
        }
    }
    return false;
}

/// A font as described by the desktop (e.g. GNOME's
/// `org.gnome.desktop.interface monospace-font-name`).
pub const SystemFont = struct {
    family: []const u8,
    /// Size in points.
    size: f32,
};

/// Parse a Pango-style font name such as "Adwaita Mono 11" or
/// "Source Code Pro Medium 10.5" into a family and point size: the last
/// space-separated word is the size and everything before it the family.
/// Returns null if there is no usable size or family. Style words that are
/// part of the family string ("Medium") are kept; fontconfig resolves them.
pub fn parseFontName(name: []const u8) ?SystemFont {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    const space = std.mem.lastIndexOfScalar(u8, trimmed, ' ') orelse return null;
    const family = std.mem.trimEnd(u8, trimmed[0..space], " ,");
    const size_str = std.mem.trimStart(u8, trimmed[space + 1 ..], " ");
    if (family.len == 0) return null;
    const size = std.fmt.parseFloat(f32, size_str) catch return null;
    if (!std.math.isFinite(size) or size < 1 or size > 255) return null;
    return .{ .family = family, .size = size };
}

/// Write `path` into `buf` with a leading `home` directory replaced by
/// `~`, the way shells and file managers display paths. Returns the
/// written slice, or `path` unchanged if it isn't under `home` or doesn't
/// fit in `buf`.
pub fn abbreviateHome(buf: []u8, path: []const u8, home: []const u8) []const u8 {
    // Normalize a trailing slash on home ("/home/me/" -> "/home/me").
    var h = home;
    while (h.len > 1 and h[h.len - 1] == '/') h = h[0 .. h.len - 1];
    if (h.len == 0 or std.mem.eql(u8, h, "/")) return path;
    if (!std.mem.startsWith(u8, path, h)) return path;

    const rest = path[h.len..];
    // Only a whole path component matches: "/home/me2" is not under "/home/me".
    if (rest.len > 0 and rest[0] != '/') return path;
    if (rest.len + 1 > buf.len) return path;

    buf[0] = '~';
    @memcpy(buf[1..][0..rest.len], rest);
    return buf[0 .. rest.len + 1];
}

//---------------------------------------------------------------------
// Tests
//
// Example-based tests pin specific behaviour; the property tests check
// invariants over many seeded random inputs (deterministic, so failures
// reproduce). Run: zig build test -Dtest-filter=term3

const testing = std.testing;

/// Iterations for each property test.
const property_runs = 20_000;

fn prng(seed: u64) std.Random.DefaultPrng {
    return std.Random.DefaultPrng.init(seed);
}

/// A random f64 drawn from a mix of ordinary values and nasty edge cases.
fn anyF64(r: std.Random) f64 {
    return switch (r.uintLessThan(u8, 10)) {
        0 => std.math.nan(f64),
        1 => std.math.inf(f64),
        2 => -std.math.inf(f64),
        3 => 0,
        4 => -0.0,
        5 => @as(f64, @floatFromInt(r.int(i32))) * 1e6,
        else => (r.float(f64) - 0.5) * 4000,
    };
}

test "term3: version is valid semver" {
    _ = try std.SemanticVersion.parse(version);
}

test "term3: clampWidth examples" {
    try testing.expectEqual(@as(i32, 80), clampWidth(0));
    try testing.expectEqual(@as(i32, 80), clampWidth(-5));
    try testing.expectEqual(@as(i32, 220), clampWidth(220));
    try testing.expectEqual(@as(i32, 800), clampWidth(10_000));
    try testing.expectEqual(@as(i32, 800), clampWidth(std.math.maxInt(i64)));
    try testing.expectEqual(@as(i32, 80), clampWidth(std.math.minInt(i64)));
}

test "term3: property: clampWidth is in range and idempotent" {
    var p = prng(0x7e3a_0001);
    const r = p.random();
    for (0..property_runs) |_| {
        const w = r.int(i64);
        const c = clampWidth(w);
        try testing.expect(c >= min_width and c <= max_width);
        try testing.expectEqual(c, clampWidth(c));
        if (w >= min_width and w <= max_width) try testing.expectEqual(@as(i64, c), w);
    }
}

test "term3: dragWidth examples" {
    try testing.expectEqual(@as(i32, 250), dragWidth(220, 30, .left));
    try testing.expectEqual(@as(i32, 190), dragWidth(220, 30, .right));
    try testing.expectEqual(@as(i32, 80), dragWidth(220, -1000, .left));
    try testing.expectEqual(@as(i32, 220), dragWidth(220, std.math.nan(f64), .left));
}

test "term3: property: dragWidth is in range, monotonic, and mirrored" {
    var p = prng(0x7e3a_0002);
    const r = p.random();
    for (0..property_runs) |_| {
        const start = clampWidth(r.intRangeAtMost(i64, -100, 1000));
        const dx = anyF64(r);
        const left = dragWidth(start, dx, .left);
        const right = dragWidth(start, dx, .right);

        // Always a legal width, whatever the pointer does.
        try testing.expect(left >= min_width and left <= max_width);
        try testing.expect(right >= min_width and right <= max_width);

        if (!std.math.isFinite(dx)) continue;

        // Mirror image: dragging a right sidebar's handle left is the
        // same as dragging a left sidebar's handle right.
        try testing.expectEqual(left, dragWidth(start, -dx, .right));

        // Monotonic: moving further toward the terminal never shrinks it.
        const more = dx + @abs(anyF64(r));
        if (std.math.isFinite(more)) {
            try testing.expect(dragWidth(start, more, .left) >= left);
        }

        // No movement, no change.
        try testing.expectEqual(start, dragWidth(start, 0, .left));
    }
}

test "term3: property: clampTitleLines is in 1...8 and idempotent" {
    var lines: u16 = 0;
    while (lines <= 255) : (lines += 1) {
        const c = clampTitleLines(@intCast(lines));
        try testing.expect(c >= 1 and c <= 8);
        try testing.expectEqual(c, clampTitleLines(c));
    }
}

test "term3: Marquee examples" {
    const m: Marquee = .{};
    // Holds at the start...
    try testing.expectEqual(@as(f64, 0), m.offset(0.5, 100));
    // ...scrolls at 50px/s after the 0.8s pause...
    try testing.expectApproxEqAbs(@as(f64, 50), m.offset(1.8, 100), 1e-9);
    // ...holds at the end...
    try testing.expectEqual(@as(f64, 100), m.offset(0.8 + 2.0 + 1.0, 100));
    // ...and starts over.
    try testing.expectEqual(@as(f64, 0), m.offset(m.cycle(100) + 0.1, 100));
    // Nothing to scroll.
    try testing.expectEqual(@as(f64, 0), m.offset(5, 0));
    try testing.expectEqual(@as(f64, 0), m.offset(5, -3));
}

test "term3: property: Marquee offset is bounded, periodic, and monotonic per cycle" {
    var p = prng(0x7e3a_0003);
    const r = p.random();
    const m: Marquee = .{};
    for (0..property_runs) |_| {
        const overflow = anyF64(r);
        const t = anyF64(r);
        const x = m.offset(t, overflow);

        // Bounded and never NaN, for any input.
        try testing.expect(!std.math.isNan(x));
        try testing.expect(x >= 0);
        if (overflow > 0 and std.math.isFinite(overflow)) {
            try testing.expect(x <= overflow);
        } else {
            try testing.expectEqual(@as(f64, 0), x);
            continue;
        }
        if (!(t > 0) or !std.math.isFinite(t) or t > 1e6) continue;

        // Within one cycle, the offset never moves backward.
        const cycle = m.cycle(overflow);
        const phase = @mod(t, cycle);
        const later = phase + r.float(f64) * (cycle - phase);
        if (later < cycle) {
            try testing.expect(m.offset(t - phase + later, overflow) >= x - 1e-6);
        }

        // Periodic.
        try testing.expectApproxEqAbs(x, m.offset(t + cycle, overflow), 1e-6 * overflow + 1e-6);
    }
}

test "term3: parseFontName examples" {
    const a = parseFontName("Adwaita Mono 11").?;
    try testing.expectEqualStrings("Adwaita Mono", a.family);
    try testing.expectEqual(@as(f32, 11), a.size);
    const b = parseFontName("  Source Code Pro Medium 10.5 ").?;
    try testing.expectEqualStrings("Source Code Pro Medium", b.family);
    try testing.expectEqual(@as(f32, 10.5), b.size);
    const c = parseFontName("Monospace, 12").?;
    try testing.expectEqualStrings("Monospace", c.family);
    try testing.expect(parseFontName("") == null);
    try testing.expect(parseFontName("Monospace") == null);
    try testing.expect(parseFontName("11") == null);
    try testing.expect(parseFontName(" 11") == null);
    try testing.expect(parseFontName("Mono 0") == null);
    try testing.expect(parseFontName("Mono nan") == null);
    try testing.expect(parseFontName("Mono inf") == null);
    try testing.expect(parseFontName("Mono 1e9") == null);
}

test "term3: property: parseFontName never crashes and round-trips" {
    var p = prng(0x7e3a_0005);
    const r = p.random();
    const alphabet = "Mono Sans 0123456789.,-e";
    var buf: [40]u8 = undefined;
    for (0..property_runs) |_| {
        // Garbage in: never crashes, and any result is sane.
        const s = buf[0..r.uintAtMost(usize, buf.len)];
        for (s) |*ch| ch.* = alphabet[r.uintLessThan(usize, alphabet.len)];
        if (parseFontName(s)) |f| {
            try testing.expect(f.family.len > 0);
            try testing.expect(f.size >= 1 and f.size <= 255);
        }

        // Well-formed in: the family and size come back out.
        const size: f32 = @floatFromInt(r.intRangeAtMost(u8, 1, 200));
        var out: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&out, "Fam Ily {d}", .{size});
        const f = parseFontName(name).?;
        try testing.expectEqualStrings("Fam Ily", f.family);
        try testing.expectEqual(size, f.size);
    }
}

test "term3: subtitleRepeatsTitle examples" {
    const r = subtitleRepeatsTitle;
    try testing.expect(r("~/code", "~/code", "/home/me/code"));
    try testing.expect(r("/home/me/code", "~/code", "/home/me/code"));
    try testing.expect(r("  ~/code ", "~/code", "/home/me/code"));
    try testing.expect(r("me@host:~/code", "~/code", "/home/me/code"));
    try testing.expect(r("me@host: ~/code", "~/code", "/home/me/code"));
    try testing.expect(r("~", "~", "/home/me"));
    // Not the directory: keep the subtitle.
    try testing.expect(!r("vim notes.md", "~/code", "/home/me/code"));
    try testing.expect(!r("~/code2", "~/code", "/home/me/code"));
    try testing.expect(!r("x~/code", "~/code", "/home/me/code"));
    try testing.expect(!r("make", "", ""));
    try testing.expect(!r("", "~/code", "/home/me/code"));
}

test "term3: property: subtitleRepeatsTitle matches the definition" {
    var p = prng(0x7e3a_0006);
    const r = p.random();
    const alphabet = "~/a: ";
    var tb: [12]u8 = undefined;
    var pb: [6]u8 = undefined;
    for (0..property_runs) |_| {
        const t = tb[0..r.uintAtMost(usize, tb.len)];
        for (t) |*c| c.* = alphabet[r.uintLessThan(usize, alphabet.len)];
        const pwd = pb[0..r.uintAtMost(usize, pb.len)];
        for (pwd) |*c| c.* = alphabet[r.uintLessThan(usize, alphabet.len)];
        const got = subtitleRepeatsTitle(t, pwd, "");

        // Reference implementation, written differently on purpose.
        const tt = std.mem.trim(u8, t, " \t");
        var want = false;
        if (pwd.len > 0) {
            if (std.mem.eql(u8, tt, pwd)) want = true;
            var i: usize = 0;
            while (i < tt.len) : (i += 1) {
                if ((tt[i] == ':' or tt[i] == ' ') and std.mem.eql(u8, tt[i + 1 ..], pwd)) want = true;
            }
        }
        try testing.expectEqual(want, got);

        // Any title made as "<prefix>:<pwd>" is always detected.
        if (pwd.len > 0 and std.mem.trim(u8, pwd, " \t").len == pwd.len) {
            var buf: [32]u8 = undefined;
            const made = std.fmt.bufPrint(&buf, "u@h:{s}", .{pwd}) catch unreachable;
            try testing.expect(subtitleRepeatsTitle(made, pwd, ""));
        }
    }
}

test "term3: abbreviateHome examples" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("~", abbreviateHome(&buf, "/home/me", "/home/me"));
    try testing.expectEqualStrings("~/code", abbreviateHome(&buf, "/home/me/code", "/home/me"));
    try testing.expectEqualStrings("~/code", abbreviateHome(&buf, "/home/me/code", "/home/me/"));
    try testing.expectEqualStrings("/home/me2/x", abbreviateHome(&buf, "/home/me2/x", "/home/me"));
    try testing.expectEqualStrings("/etc", abbreviateHome(&buf, "/etc", "/home/me"));
    try testing.expectEqualStrings("/etc", abbreviateHome(&buf, "/etc", "/"));
    try testing.expectEqualStrings("/etc", abbreviateHome(&buf, "/etc", ""));
    var tiny: [3]u8 = undefined;
    try testing.expectEqualStrings("/home/me/long", abbreviateHome(&tiny, "/home/me/long", "/home/me"));
}

test "term3: property: abbreviateHome round-trips and never grows" {
    var p = prng(0x7e3a_0004);
    const r = p.random();
    const alphabet = "/ab~.";
    var path_buf: [32]u8 = undefined;
    var home_buf: [16]u8 = undefined;
    var out: [64]u8 = undefined;
    for (0..property_runs) |_| {
        const path = path_buf[0..r.uintAtMost(usize, path_buf.len)];
        for (path) |*c| c.* = alphabet[r.uintLessThan(usize, alphabet.len)];
        const home = home_buf[0..r.uintAtMost(usize, home_buf.len)];
        for (home) |*c| c.* = alphabet[r.uintLessThan(usize, alphabet.len)];
        // Often make home a real prefix of path.
        const h = if (r.boolean() and home.len <= path.len) path[0..home.len] else home;

        const a = abbreviateHome(&out, path, h);
        try testing.expect(a.len <= path.len or a.ptr == path.ptr);
        if (a.ptr != path.ptr) {
            // Abbreviated: "~" + the rest, and expanding gives the path back.
            try testing.expect(a[0] == '~');
            var trimmed = h;
            while (trimmed.len > 1 and trimmed[trimmed.len - 1] == '/') trimmed = trimmed[0 .. trimmed.len - 1];
            try testing.expect(std.mem.startsWith(u8, path, trimmed));
            try testing.expectEqualStrings(path[trimmed.len..], a[1..]);
        }
    }
}

/// Update or set the `maximize = <val>` key in a configuration file's text content.
/// If a `maximize = ...` line exists, it is replaced in place.
/// Otherwise, `maximize = <val>\n` is appended.
pub fn setConfigMaximize(alloc: std.mem.Allocator, content: []const u8, val: bool) ![]const u8 {
    return setConfigBool(alloc, content, "maximize", val);
}

/// Update or set the `<key> = <val>` line in a configuration file's text
/// content. Every existing `<key> = ...` line is replaced in place;
/// otherwise `<key> = <val>\n` is appended.
pub fn setConfigBool(
    alloc: std.mem.Allocator,
    content: []const u8,
    key: []const u8,
    val: bool,
) ![]const u8 {
    return setConfigValue(alloc, content, key, if (val) "true" else "false");
}

/// Like `setConfigBool`, but writes `<key> = <val>` for any value string.
pub fn setConfigValue(
    alloc: std.mem.Allocator,
    content: []const u8,
    key: []const u8,
    val: []const u8,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    const val_str = try std.fmt.allocPrint(alloc, "{s} = {s}", .{ key, val });
    defer alloc.free(val_str);

    var found = false;
    var line_it = std.mem.splitScalar(u8, content, '\n');
    var is_first = true;
    while (line_it.next()) |line| {
        if (!is_first) {
            try out.append(alloc, '\n');
        }
        is_first = false;

        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, key) and
            (trimmed.len == key.len or
                trimmed[key.len] == ' ' or
                trimmed[key.len] == '=' or
                trimmed[key.len] == '\t'))
        {
            try out.appendSlice(alloc, val_str);
            found = true;
        } else {
            try out.appendSlice(alloc, line);
        }
    }

    if (!found) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') {
            try out.append(alloc, '\n');
        }
        try out.appendSlice(alloc, val_str);
        try out.append(alloc, '\n');
    } else {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') {
            try out.append(alloc, '\n');
        }
    }

    return out.toOwnedSlice(alloc);
}

test "term3: setConfigMaximize empty" {
    const alloc = testing.allocator;
    const res = try setConfigMaximize(alloc, "", true);
    defer alloc.free(res);
    try testing.expectEqualStrings("maximize = true\n", res);

    const res_f = try setConfigMaximize(alloc, "", false);
    defer alloc.free(res_f);
    try testing.expectEqualStrings("maximize = false\n", res_f);
}

test "term3: setConfigMaximize replace existing" {
    const alloc = testing.allocator;
    const input = "# Term3 config\nfont-size = 14\nmaximize = true\ngtk-tabs-location = left\n";
    const res = try setConfigMaximize(alloc, input, false);
    defer alloc.free(res);
    try testing.expectEqualStrings("# Term3 config\nfont-size = 14\nmaximize = false\ngtk-tabs-location = left\n", res);

    const res2 = try setConfigMaximize(alloc, res, true);
    defer alloc.free(res2);
    try testing.expectEqualStrings("# Term3 config\nfont-size = 14\nmaximize = true\ngtk-tabs-location = left\n", res2);
}

test "term3: setConfigBool other key" {
    const alloc = testing.allocator;
    const input = "maximize = true\ngtk-inhibit-system-shortcuts=false\n";
    const res = try setConfigBool(alloc, input, "gtk-inhibit-system-shortcuts", true);
    defer alloc.free(res);
    try testing.expectEqualStrings("maximize = true\ngtk-inhibit-system-shortcuts = true\n", res);

    // A key that is a prefix of another key must not match it.
    const res2 = try setConfigBool(alloc, "gtk-inhibit-system-shortcuts-x = 1\n", "gtk-inhibit-system-shortcuts", false);
    defer alloc.free(res2);
    try testing.expectEqualStrings("gtk-inhibit-system-shortcuts-x = 1\ngtk-inhibit-system-shortcuts = false\n", res2);
}

test "term3: setConfigMaximize append if missing" {
    const alloc = testing.allocator;
    const input = "# Term3 config\nfont-size = 14\n";
    const res = try setConfigMaximize(alloc, input, true);
    defer alloc.free(res);
    try testing.expectEqualStrings("# Term3 config\nfont-size = 14\nmaximize = true\n", res);
}

test "term3: setConfigValue replaces and appends enum values" {
    const alloc = testing.allocator;
    const res = try setConfigValue(alloc, "font-size = 14\ncopy-on-select = primary\n", "copy-on-select", "none");
    defer alloc.free(res);
    try testing.expectEqualStrings("font-size = 14\ncopy-on-select = none\n", res);

    const res2 = try setConfigValue(alloc, "font-size = 14", "copy-on-select", "both");
    defer alloc.free(res2);
    try testing.expectEqualStrings("font-size = 14\ncopy-on-select = both\n", res2);
}

// ---------------------------------------------------------------------------
// Defusing GNOME shortcuts that clash with term3's super keybinds
//
// term3 only holds the keyboard-shortcuts inhibit while super is down (see
// Window.syncShortcutsInhibit), and it can only ask once it has seen super
// go down. When the next key follows within a few milliseconds, the
// compositor handles the combo before the inhibit exists. For most combos
// that just does GNOME's action. For the ones below it opens a shell popup
// or mode that takes keyboard focus, so every term3 tab seems to stop
// responding until it is closed: fast super+v opens the notification list
// with its Clear button focused. `gtk-defuse-gnome-shortcuts` removes exactly
// these accelerators from GNOME and puts back what it removed when turned off.

/// One GNOME accelerator term3 may remove: `accel` in the `key` strv of the
/// GSettings `schema`.
pub const GnomeShortcut = struct {
    schema: []const u8,
    key: []const u8,
    accel: []const u8,
};

/// The GNOME shortcuts that both clash with a default term3 super keybind
/// and open something that takes keyboard focus. Keep in sync with
/// `itermBinds` in Config.zig (a test there checks every entry is bound).
pub const gnome_defuse_shortcuts = [_]GnomeShortcut{
    // Notification list. GNOME keeps super+m for it.
    .{ .schema = "org.gnome.shell.keybindings", .key = "toggle-message-tray", .accel = "<Super>v" },
    // App grid (overview, whose search entry takes typing).
    .{ .schema = "org.gnome.shell.keybindings", .key = "toggle-application-view", .accel = "<Super>a" },
    // Focuses the newest notification.
    .{ .schema = "org.gnome.shell.keybindings", .key = "focus-active-notification", .accel = "<Super>n" },
    // Open or move the overview (term3: goto_split up/down).
    .{ .schema = "org.gnome.shell.keybindings", .key = "shift-overview-up", .accel = "<Super><Alt>Up" },
    .{ .schema = "org.gnome.shell.keybindings", .key = "shift-overview-down", .accel = "<Super><Alt>Down" },
};

/// Modifiers of a GTK accelerator string (`<Super><Shift>v`).
pub const AccelMods = packed struct(u8) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
    hyper: bool = false,
    meta: bool = false,
    _pad: u2 = 0,
};

pub const Accel = struct {
    mods: AccelMods,
    key: []const u8,
};

/// Parse a GTK accelerator the way GSettings keybindings spell them:
/// `<Mod>` tokens (any case, with the usual aliases) followed by a key name.
/// Returns null for anything else, including an empty or disabled entry.
pub fn parseAccel(s: []const u8) ?Accel {
    var mods: AccelMods = .{};
    var rest = s;
    while (rest.len > 0 and rest[0] == '<') {
        const end = std.mem.indexOfScalar(u8, rest, '>') orelse return null;
        const name = rest[1..end];
        const eq = std.ascii.eqlIgnoreCase;
        if (eq(name, "shift")) {
            mods.shift = true;
        } else if (eq(name, "control") or eq(name, "ctrl") or eq(name, "ctl") or eq(name, "primary")) {
            mods.ctrl = true;
        } else if (eq(name, "alt") or eq(name, "mod1")) {
            mods.alt = true;
        } else if (eq(name, "super") or eq(name, "mod4")) {
            mods.super = true;
        } else if (eq(name, "hyper")) {
            mods.hyper = true;
        } else if (eq(name, "meta")) {
            mods.meta = true;
        } else return null;
        rest = rest[end + 1 ..];
    }
    if (rest.len == 0) return null;
    for (rest) |c| if (c == '<' or c == '>' or c <= ' ') return null;
    return .{ .mods = mods, .key = rest };
}

/// Whether two accelerator strings name the same key combination, so
/// `<Mod4>V` matches `<Super>v`. Strings that don't parse never match.
pub fn accelEqual(a: []const u8, b: []const u8) bool {
    const pa = parseAccel(a) orelse return false;
    const pb = parseAccel(b) orelse return false;
    return pa.mods == pb.mods and std.ascii.eqlIgnoreCase(pa.key, pb.key);
}

/// The index of the entry in `list` that names the same combination as
/// `accel`, if any.
pub fn findAccel(list: []const []const u8, accel: []const u8) ?usize {
    for (list, 0..) |item, i| if (accelEqual(item, accel)) return i;
    return null;
}

/// `list` without every entry naming `accel`'s combination, or null if
/// there was none. The result is allocated; its items borrow from `list`.
pub fn removeAccel(
    alloc: std.mem.Allocator,
    list: []const []const u8,
    accel: []const u8,
) !?[]const []const u8 {
    if (findAccel(list, accel) == null) return null;
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);
    for (list) |item| if (!accelEqual(item, accel)) try out.append(alloc, item);
    return try out.toOwnedSlice(alloc);
}

/// `list` with `accel` appended, or null if it already names that
/// combination. The result is allocated; its items borrow from the inputs.
pub fn addAccel(
    alloc: std.mem.Allocator,
    list: []const []const u8,
    accel: []const u8,
) !?[]const []const u8 {
    if (findAccel(list, accel) != null) return null;
    const out = try alloc.alloc([]const u8, list.len + 1);
    @memcpy(out[0..list.len], list);
    out[list.len] = accel;
    return out;
}

/// Whether two accelerator lists bind the same set of combinations,
/// ignoring order, spelling and duplicates (entries that don't parse, like
/// GNOME's '' placeholder, are ignored too). A restore that yields GNOME's
/// default set resets the key instead of storing a reordered copy of it.
pub fn sameAccelSet(a: []const []const u8, b: []const []const u8) bool {
    for (a) |x| if (parseAccel(x) != null and findAccel(b, x) == null) return false;
    for (b) |x| if (parseAccel(x) != null and findAccel(a, x) == null) return false;
    return true;
}

/// The record of what term3 removed, one `schema<TAB>key<TAB>accel` line
/// per accelerator, so turning the setting off restores exactly that.
pub fn formatDefuseState(alloc: std.mem.Allocator, removed: []const GnomeShortcut) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (removed) |r| {
        if (!validStateField(r.schema) or !validStateField(r.key) or !validStateField(r.accel))
            return error.InvalidField;
        try out.print(alloc, "{s}\t{s}\t{s}\n", .{ r.schema, r.key, r.accel });
    }
    return try out.toOwnedSlice(alloc);
}

fn validStateField(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (c == '\t' or c == '\n' or c == '\r') return false;
    return true;
}

/// Iterates the entries of a defuse state file. Malformed lines (from a
/// damaged or hand-edited file) are skipped rather than restored.
pub const DefuseStateIterator = struct {
    lines: std.mem.SplitIterator(u8, .scalar),

    pub fn init(content: []const u8) DefuseStateIterator {
        return .{ .lines = std.mem.splitScalar(u8, content, '\n') };
    }

    pub fn next(self: *DefuseStateIterator) ?GnomeShortcut {
        while (self.lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            var fields = std.mem.splitScalar(u8, line, '\t');
            const schema = fields.next() orelse continue;
            const key = fields.next() orelse continue;
            const accel = fields.next() orelse continue;
            if (fields.next() != null) continue;
            if (schema.len == 0 or key.len == 0 or parseAccel(accel) == null) continue;
            return .{ .schema = schema, .key = key, .accel = accel };
        }
        return null;
    }
};

test "term3: parseAccel examples" {
    const a = parseAccel("<Super>v").?;
    try testing.expect(a.mods.super and !a.mods.shift and !a.mods.ctrl and !a.mods.alt);
    try testing.expectEqualStrings("v", a.key);

    const b = parseAccel("<Super><Alt>Up").?;
    try testing.expect(b.mods.super and b.mods.alt);
    try testing.expectEqualStrings("Up", b.key);

    // Aliases and case.
    try testing.expect(parseAccel("<Mod4>V").?.mods.super);
    try testing.expect(parseAccel("<primary>c").?.mods.ctrl);
    try testing.expect(parseAccel("<CONTROL><ctl><Ctrl>c").?.mods.ctrl);
    try testing.expect(parseAccel("<mod1>Tab").?.mods.alt);
    try testing.expect(parseAccel("XF86AudioMute").?.mods == AccelMods{});

    // Not accelerators: empty/disabled entries, unknown or broken modifiers,
    // a modifier with no key, stray brackets or spaces.
    for ([_][]const u8{ "", "<Super>", "<Super", "<Bogus>v", "<Super>v>", "<Super><v", "<Super> v", "a b", "<>v" }) |s| {
        try testing.expect(parseAccel(s) == null);
    }
}

test "term3: accelEqual matches aliases and case, not other combos" {
    try testing.expect(accelEqual("<Super>v", "<Super>v"));
    try testing.expect(accelEqual("<Super>v", "<Mod4>V"));
    try testing.expect(accelEqual("<Super><Alt>Up", "<Alt><Super>up"));
    try testing.expect(!accelEqual("<Super>v", "<Super><Shift>v"));
    try testing.expect(!accelEqual("<Super>v", "<Super>m"));
    try testing.expect(!accelEqual("<Super>v", "v"));
    try testing.expect(!accelEqual("", ""));
    try testing.expect(!accelEqual("<Bogus>v", "<Bogus>v"));
}

test "term3: removeAccel keeps the other bindings in order" {
    const alloc = testing.allocator;
    const gnome_default = [_][]const u8{ "<Super>v", "<Super>m" };
    const out = (try removeAccel(alloc, &gnome_default, "<Super>v")).?;
    defer alloc.free(out);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("<Super>m", out[0]);

    // Every spelling of the combination goes, nothing else does.
    const messy = [_][]const u8{ "<Mod4>V", "<Super>m", "<Super>v", "" };
    const out2 = (try removeAccel(alloc, &messy, "<Super>v")).?;
    defer alloc.free(out2);
    try testing.expectEqual(@as(usize, 2), out2.len);
    try testing.expectEqualStrings("<Super>m", out2[0]);
    try testing.expectEqualStrings("", out2[1]);

    // Absent: nothing to do.
    try testing.expect((try removeAccel(alloc, &[_][]const u8{"<Super>m"}, "<Super>v")) == null);
    try testing.expect((try removeAccel(alloc, &[_][]const u8{}, "<Super>v")) == null);
}

test "term3: addAccel appends once" {
    const alloc = testing.allocator;
    const out = (try addAccel(alloc, &[_][]const u8{"<Super>m"}, "<Super>v")).?;
    defer alloc.free(out);
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqualStrings("<Super>m", out[0]);
    try testing.expectEqualStrings("<Super>v", out[1]);
    // Already bound (in any spelling): unchanged.
    try testing.expect((try addAccel(alloc, &[_][]const u8{ "<Super>m", "<Mod4>V" }, "<Super>v")) == null);
}

test "term3: sameAccelSet ignores order, spelling and placeholders" {
    const L = []const []const u8;
    try testing.expect(sameAccelSet(&[_][]const u8{ "<Super>m", "<Super>v" }, &[_][]const u8{ "<Super>v", "<Super>m" }));
    try testing.expect(sameAccelSet(&[_][]const u8{ "<Mod4>V", "<Super>m" }, &[_][]const u8{ "<Super>m", "<Super>v", "<Super>v" }));
    try testing.expect(sameAccelSet(&[_][]const u8{ "", "<Super>F1" }, &[_][]const u8{"<Super>F1"}));
    try testing.expect(sameAccelSet(@as(L, &.{}), @as(L, &.{})));
    try testing.expect(!sameAccelSet(&[_][]const u8{"<Super>m"}, &[_][]const u8{ "<Super>m", "<Super>v" }));
    try testing.expect(!sameAccelSet(&[_][]const u8{ "<Super>m", "<Super>v" }, &[_][]const u8{"<Super>m"}));
    try testing.expect(!sameAccelSet(&[_][]const u8{"<Super>v"}, &[_][]const u8{"<Super><Shift>v"}));
}

test "term3: property: removing then re-adding gives back the same accelerator set" {
    const alloc = testing.allocator;
    var p = prng(0x5a3e_5e7);
    const r = p.random();
    const pool = [_][]const u8{ "<Super>v", "<Super>m", "<Super>a", "<Mod4>V", "<Super><Shift>v", "", "<Alt>Tab" };
    for (0..property_runs) |_| {
        var buf: [6][]const u8 = undefined;
        const n = r.uintLessThan(usize, buf.len + 1);
        for (buf[0..n]) |*item| item.* = pool[r.uintLessThan(usize, pool.len)];
        const list = buf[0..n];
        const accel = pool[r.uintLessThan(usize, 4)];
        // Only lists that bind the accelerator get it removed (and recorded).
        const removed = (try removeAccel(alloc, list, accel)) orelse continue;
        defer alloc.free(removed);
        try testing.expect(!sameAccelSet(list, removed));
        const restored = (try addAccel(alloc, removed, accel)).?;
        defer alloc.free(restored);
        try testing.expect(sameAccelSet(list, restored));
    }
}

test "term3: the defuse list only names popups GNOME binds by default" {
    for (gnome_defuse_shortcuts) |s| {
        const a = parseAccel(s.accel).?;
        try testing.expect(a.mods.super);
        try testing.expectEqualStrings("org.gnome.shell.keybindings", s.schema);
    }
    // Super+M must stay bound to the notification list.
    for (gnome_defuse_shortcuts) |s| try testing.expect(!accelEqual(s.accel, "<Super>m"));
}

test "term3: defuse state round-trips" {
    const alloc = testing.allocator;
    const removed = [_]GnomeShortcut{
        .{ .schema = "org.gnome.shell.keybindings", .key = "toggle-message-tray", .accel = "<Super>v" },
        .{ .schema = "org.gnome.shell.keybindings", .key = "toggle-application-view", .accel = "<Mod4>A" },
    };
    const text = try formatDefuseState(alloc, &removed);
    defer alloc.free(text);
    try testing.expectEqualStrings(
        "org.gnome.shell.keybindings\ttoggle-message-tray\t<Super>v\n" ++
            "org.gnome.shell.keybindings\ttoggle-application-view\t<Mod4>A\n",
        text,
    );
    var it: DefuseStateIterator = .init(text);
    for (removed) |want| {
        const got = it.next().?;
        try testing.expectEqualStrings(want.schema, got.schema);
        try testing.expectEqualStrings(want.key, got.key);
        try testing.expectEqualStrings(want.accel, got.accel);
    }
    try testing.expect(it.next() == null);

    try testing.expectError(error.InvalidField, formatDefuseState(alloc, &[_]GnomeShortcut{
        .{ .schema = "a\tb", .key = "k", .accel = "<Super>v" },
    }));
}

test "term3: defuse state skips malformed lines" {
    const text =
        "\n" ++
        "garbage\n" ++
        "only\ttwo\n" ++
        "too\tmany\t<Super>v\tfields\n" ++
        "\tkey\t<Super>v\n" ++
        "schema\t\t<Super>v\n" ++
        "schema\tkey\t<Bogus>v\n" ++
        "org.gnome.shell.keybindings\ttoggle-message-tray\t<Super>v\r\n" ++
        "trailing-no-newline\tk\t<Super>a";
    var it: DefuseStateIterator = .init(text);
    const a = it.next().?;
    try testing.expectEqualStrings("toggle-message-tray", a.key);
    try testing.expectEqualStrings("<Super>v", a.accel);
    const b = it.next().?;
    try testing.expectEqualStrings("trailing-no-newline", b.schema);
    try testing.expect(it.next() == null);
}

/// A random accelerator for `combo` with random modifier order, aliases and
/// key case, all naming the same combination.
fn respell(r: std.Random, buf: []u8, mods: AccelMods, key: []const u8) []const u8 {
    const names = [_][]const []const u8{
        &.{ "Shift", "shift", "SHIFT" },
        &.{ "Control", "Ctrl", "ctl", "Primary", "control" },
        &.{ "Alt", "Mod1", "alt" },
        &.{ "Super", "Mod4", "super" },
        &.{ "Hyper", "hyper" },
        &.{ "Meta", "META" },
    };
    const on = [_]bool{ mods.shift, mods.ctrl, mods.alt, mods.super, mods.hyper, mods.meta };
    var order = [_]usize{ 0, 1, 2, 3, 4, 5 };
    r.shuffle(usize, &order);
    var n: usize = 0;
    for (order) |i| if (on[i]) {
        const alts = names[i];
        const name = alts[r.uintLessThan(usize, alts.len)];
        // Sometimes repeat a modifier: GTK accepts that and it changes nothing.
        const times: usize = if (r.uintLessThan(u8, 8) == 0) 2 else 1;
        for (0..times) |_| {
            buf[n] = '<';
            @memcpy(buf[n + 1 ..][0..name.len], name);
            buf[n + 1 + name.len] = '>';
            n += name.len + 2;
        }
    };
    for (key) |c| {
        buf[n] = if (r.boolean()) std.ascii.toUpper(c) else std.ascii.toLower(c);
        n += 1;
    }
    return buf[0..n];
}

test "term3: property: accelEqual ignores spelling and tells combos apart" {
    var p = prng(0x7e3_def05e);
    const r = p.random();
    const keys = [_][]const u8{ "v", "a", "n", "m", "Up", "Down", "Tab", "space", "F1", "XF86AudioMute" };
    var b1: [128]u8 = undefined;
    var b2: [128]u8 = undefined;
    for (0..property_runs) |_| {
        const m1: AccelMods = @bitCast(r.int(u8) & 0x3f);
        const k1 = keys[r.uintLessThan(usize, keys.len)];
        const s1 = respell(r, &b1, m1, k1);
        const s1b = respell(r, &b2, m1, k1);
        // Same combination, any spelling: equal, both ways, and reflexive.
        try testing.expect(accelEqual(s1, s1b));
        try testing.expect(accelEqual(s1b, s1));
        try testing.expect(accelEqual(s1, s1));

        const m2: AccelMods = @bitCast(r.int(u8) & 0x3f);
        const k2 = keys[r.uintLessThan(usize, keys.len)];
        const s2 = respell(r, &b2, m2, k2);
        const same = m1 == m2 and std.ascii.eqlIgnoreCase(k1, k2);
        try testing.expectEqual(same, accelEqual(s1, s2));
    }
}

test "term3: property: removing then adding an accelerator restores the combos" {
    const alloc = testing.allocator;
    var p = prng(0x5eed_acce1);
    const r = p.random();
    const pool = [_][]const u8{ "<Super>v", "<Super>m", "<Super>a", "<Mod4>V", "<Super><Shift>v", "", "<Alt>Tab", "XF86AudioMute" };
    for (0..property_runs) |_| {
        var list_buf: [6][]const u8 = undefined;
        const n = r.uintLessThan(usize, list_buf.len + 1);
        for (list_buf[0..n]) |*item| item.* = pool[r.uintLessThan(usize, pool.len)];
        const list = list_buf[0..n];
        const accel = pool[r.uintLessThan(usize, 4)];

        const had = findAccel(list, accel) != null;
        const removed = try removeAccel(alloc, list, accel);
        defer if (removed) |x| alloc.free(x);
        try testing.expectEqual(had, removed != null);

        const after = removed orelse list;
        // Nothing naming the combination survives; everything else does, in order.
        try testing.expect(findAccel(after, accel) == null);
        var j: usize = 0;
        for (list) |item| if (!accelEqual(item, accel)) {
            try testing.expectEqualStrings(item, after[j]);
            j += 1;
        };
        try testing.expectEqual(j, after.len);

        // Adding it back binds the combination exactly once more.
        const added = (try addAccel(alloc, after, accel)).?;
        defer alloc.free(added);
        try testing.expect(findAccel(added, accel) != null);
        try testing.expectEqual(after.len + 1, added.len);
        try testing.expect((try addAccel(alloc, added, accel)) == null);
    }
}

test "term3: property: defuse state round-trips any valid entries" {
    const alloc = testing.allocator;
    var p = prng(0xde_f05e_57a7e);
    const r = p.random();
    const charset = "abcdefghijklmnopqrstuvwxyz.-_0123456789<>";
    for (0..2_000) |_| {
        var entries: [5]GnomeShortcut = undefined;
        var bufs: [5][2][24]u8 = undefined;
        var accel_bufs: [5][96]u8 = undefined;
        const n = r.uintLessThan(usize, entries.len + 1);
        for (0..n) |i| {
            var fields: [3][]const u8 = undefined;
            for (0..2) |f| {
                const len = 1 + r.uintLessThan(usize, 20);
                for (bufs[i][f][0..len]) |*c| c.* = charset[r.uintLessThan(usize, charset.len - 2)];
                fields[f] = bufs[i][f][0..len];
            }
            fields[2] = respell(r, &accel_bufs[i], @bitCast(r.int(u8) & 0x0f), "v");
            entries[i] = .{ .schema = fields[0], .key = fields[1], .accel = fields[2] };
        }
        const text = try formatDefuseState(alloc, entries[0..n]);
        defer alloc.free(text);
        var it: DefuseStateIterator = .init(text);
        for (entries[0..n]) |want| {
            const got = it.next().?;
            try testing.expectEqualStrings(want.schema, got.schema);
            try testing.expectEqualStrings(want.key, got.key);
            try testing.expectEqualStrings(want.accel, got.accel);
        }
        try testing.expect(it.next() == null);
    }
}

test "term3: property: parseAccel never crashes on junk" {
    var p = prng(0xbad_acce1);
    const r = p.random();
    var buf: [32]u8 = undefined;
    const charset = "<>SuperAltShiftCtrlMod4vV \t";
    for (0..property_runs) |_| {
        const len = r.uintLessThan(usize, buf.len);
        for (buf[0..len]) |*c| c.* = if (r.uintLessThan(u8, 4) == 0) r.int(u8) else charset[r.uintLessThan(usize, charset.len)];
        if (parseAccel(buf[0..len])) |a| {
            try testing.expect(a.key.len > 0);
            for (a.key) |c| try testing.expect(c != '<' and c != '>' and c > ' ');
        }
    }
}
