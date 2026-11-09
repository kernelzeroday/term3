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
pub const version = "0.1.0-rc.3";

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
