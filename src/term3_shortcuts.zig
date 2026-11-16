//! term3: the data behind the Keyboard Shortcuts dialog.
//!
//! Turns a keybind set into a list of shortcuts, one per action, grouped into
//! categories and given readable titles. Kept free of GTK so it can be unit
//! tested; the dialog itself is `apprt/gtk/shortcuts_dialog.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const input = @import("input.zig");
const Binding = input.Binding;
const Action = Binding.Action;
const Trigger = Binding.Trigger;

/// Dialog sections, in display order.
pub const Category = enum {
    tabs,
    windows,
    splits,
    clipboard,
    scrolling,
    search,
    font,
    terminal,
    application,

    pub fn title(self: Category) [:0]const u8 {
        return switch (self) {
            .tabs => "Tabs",
            .windows => "Windows",
            .splits => "Splits",
            .clipboard => "Copy and Paste",
            .scrolling => "Scrolling and Selection",
            .search => "Search",
            .font => "Font Size",
            .terminal => "Terminal",
            .application => "Application",
        };
    }
};

pub fn category(key: Action.Key) Category {
    return switch (key) {
        .new_tab,
        .previous_tab,
        .next_tab,
        .last_tab,
        .goto_tab,
        .move_tab,
        .move_tab_to_new_window,
        .toggle_tab_overview,
        .prompt_tab_title,
        .set_tab_title,
        .close_tab,
        => .tabs,

        .new_window,
        .goto_window,
        .prompt_window_title,
        .set_window_title,
        .reset_window_size,
        .set_window_theme,
        .close_window,
        .close_all_windows,
        .toggle_maximize,
        .toggle_fullscreen,
        .toggle_window_decorations,
        .toggle_window_float_on_top,
        .toggle_quick_terminal,
        .toggle_visibility,
        .toggle_background_opacity,
        => .windows,

        .new_split,
        .goto_split,
        .toggle_split_zoom,
        .resize_split,
        .equalize_splits,
        .close_surface,
        .prompt_surface_title,
        .set_surface_title,
        => .splits,

        .copy_to_clipboard,
        .paste_from_clipboard,
        .paste_from_selection,
        .copy_url_to_clipboard,
        .copy_title_to_clipboard,
        => .clipboard,

        .select_all,
        .scroll_to_top,
        .scroll_to_bottom,
        .scroll_to_selection,
        .scroll_to_row,
        .scroll_page_up,
        .scroll_page_down,
        .scroll_page_fractional,
        .scroll_page_lines,
        .adjust_selection,
        .jump_to_prompt,
        => .scrolling,

        .search,
        .search_selection,
        .navigate_search,
        .start_search,
        .end_search,
        => .search,

        .increase_font_size,
        .decrease_font_size,
        .reset_font_size,
        .set_font_size,
        => .font,

        .inspector,
        .show_gtk_inspector,
        .show_on_screen_keyboard,
        .open_config,
        .reload_config,
        .toggle_command_palette,
        .check_for_updates,
        .quit,
        => .application,

        // Everything else acts on the terminal itself (reset, clear,
        // sending text or escapes, key tables, ...).
        else => .terminal,
    };
}

pub const Shortcut = struct {
    title: [:0]const u8,
    category: Category,
    /// The action as written in a config file (e.g. `goto_tab:3`).
    action: [:0]const u8,
    /// Every key sequence bound to the action. Most are one trigger long;
    /// leader sequences (`ctrl+a>c`) are longer.
    sequences: []const []const Trigger,
};

/// Lists the shortcuts in `set`, sorted by category and then title. All
/// memory comes from `alloc`, which should be an arena.
pub fn collect(alloc: Allocator, set: *const Binding.Set) Allocator.Error![]Shortcut {
    var builder: Builder = .{ .alloc = alloc };
    var prefix: std.ArrayList(Trigger) = .empty;
    try builder.walk(set, &prefix);

    const result = try alloc.alloc(Shortcut, builder.order.items.len);
    for (builder.order.items, result) |key, *out| {
        const entry = builder.by_action.getPtr(key).?;
        out.* = .{
            .title = entry.title,
            .category = entry.category,
            .action = key,
            .sequences = entry.sequences.items,
        };
    }
    std.mem.sort(Shortcut, result, {}, lessThan);
    return result;
}

fn lessThan(_: void, a: Shortcut, b: Shortcut) bool {
    if (a.category != b.category) {
        return @backingInt(a.category) < @backingInt(b.category);
    }
    return switch (std.ascii.orderIgnoreCase(a.title, b.title)) {
        .lt => true,
        .gt => false,
        .eq => std.mem.order(u8, a.action, b.action) == .lt,
    };
}

const Builder = struct {
    alloc: Allocator,
    by_action: std.StringHashMapUnmanaged(Entry) = .empty,
    /// Action keys in first-seen order, so equal titles sort stably.
    order: std.ArrayList([:0]const u8) = .empty,

    const Entry = struct {
        title: [:0]const u8,
        category: Category,
        sequences: std.ArrayList([]const Trigger) = .empty,
    };

    fn walk(
        self: *Builder,
        set: *const Binding.Set,
        prefix: *std.ArrayList(Trigger),
    ) Allocator.Error!void {
        var it = set.bindings.iterator();
        while (it.next()) |binding| {
            try prefix.append(self.alloc, binding.key_ptr.*);
            defer _ = prefix.pop();

            switch (binding.value_ptr.*) {
                .leader => |next| try self.walk(next, prefix),
                .leaf => |leaf| try self.add(&.{leaf.action}, prefix.items),
                .leaf_chained => |leaf| try self.add(leaf.actions.items, prefix.items),
            }
        }
    }

    fn add(
        self: *Builder,
        actions: []const Action,
        sequence: []const Trigger,
    ) Allocator.Error!void {
        if (actions.len == 0) return;
        // `ignore` and `unbind` aren't shortcuts anyone wants listed.
        if (actions.len == 1) switch (actions[0]) {
            .ignore, .unbind => return,
            else => {},
        };

        const key = try formatActions(self.alloc, actions);
        const gop = try self.by_action.getOrPut(self.alloc, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .title = try title(self.alloc, actions, key),
                .category = category(actions[0]),
            };
            try self.order.append(self.alloc, key);
        }
        try gop.value_ptr.sequences.append(
            self.alloc,
            try self.alloc.dupe(Trigger, sequence),
        );
    }
};

fn formatActions(alloc: Allocator, actions: []const Action) Allocator.Error![:0]const u8 {
    var buf: std.Io.Writer.Allocating = .init(alloc);
    errdefer buf.deinit();
    for (actions, 0..) |action, i| {
        if (i > 0) buf.writer.writeAll(", ") catch return error.OutOfMemory;
        buf.writer.print("{f}", .{action}) catch return error.OutOfMemory;
    }
    return buf.toOwnedSliceSentinel(0);
}

/// The command palette's title for a single action when it has one, or a
/// title made from the action's config name (`goto_tab:3` -> "Goto tab: 3").
fn title(
    alloc: Allocator,
    actions: []const Action,
    formatted: [:0]const u8,
) Allocator.Error![:0]const u8 {
    if (actions.len == 1) {
        const h = actions[0].hash();
        for (input.command.defaults) |cmd| {
            if (cmd.action.hash() == h) return cmd.translated().title;
        }
    }
    return humanize(alloc, formatted);
}

fn humanize(alloc: Allocator, formatted: []const u8) Allocator.Error![:0]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    var in_param = false;
    for (formatted, 0..) |c, i| {
        if (in_param) {
            try buf.append(alloc, c);
            if (c == ',') in_param = false; // next chained action
            continue;
        }
        switch (c) {
            '_' => try buf.append(alloc, ' '),
            ':' => {
                try buf.appendSlice(alloc, ": ");
                in_param = true;
            },
            else => try buf.append(alloc, if (i == 0) std.ascii.toUpper(c) else c),
        }
    }
    return buf.toOwnedSliceSentinel(alloc, 0);
}

const testing = std.testing;
const Config = @import("config.zig").Config;

fn find(list: []const Shortcut, action: []const u8) ?Shortcut {
    for (list) |s| if (std.mem.eql(u8, s.action, action)) return s;
    return null;
}

test "term3: shortcuts: defaults are listed, sorted, and grouped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();

    const list = try collect(alloc, &cfg.keybind.set);
    try testing.expect(list.len > 10);

    // Sorted by category, then title.
    for (list[0 .. list.len - 1], list[1..]) |a, b| {
        try testing.expect(!lessThan({}, b, a));
    }

    // One row per action, never ignore/unbind, always at least one key.
    for (list, 0..) |s, i| {
        try testing.expect(s.sequences.len > 0);
        try testing.expect(!std.mem.eql(u8, s.action, "ignore"));
        try testing.expect(!std.mem.eql(u8, s.action, "unbind"));
        for (list[i + 1 ..]) |other| {
            try testing.expect(!std.mem.eql(u8, s.action, other.action));
        }
    }

    // new_tab is bound to both ctrl+shift+t and (term3) super+t.
    const new_tab = find(list, "new_tab").?;
    try testing.expectEqual(Category.tabs, new_tab.category);
    try testing.expect(new_tab.sequences.len >= 2);
    try testing.expect(new_tab.title.len > 0);
}

test "term3: shortcuts: leader sequences, chains, and fallback titles" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();
    var it: TestIterator = .{ .data = &.{
        "--keybind=ctrl+a>c=new_split:right",
        "--keybind=ctrl+a>x=ignore",
        "--keybind=f7=text:hi",
        "--keybind=f8=reset",
        "--keybind=chain=clear_screen",
    } };
    try cfg.loadIter(testing.allocator, &it);

    const list = try collect(alloc, &cfg.keybind.set);

    const split = find(list, "new_split:right").?;
    try testing.expectEqual(Category.splits, split.category);
    var saw_leader = false;
    for (split.sequences) |seq| {
        if (seq.len == 2) saw_leader = true;
    }
    try testing.expect(saw_leader);

    const text = find(list, "text:hi").?;
    try testing.expectEqualStrings("Text: hi", text.title);
    try testing.expectEqual(Category.terminal, text.category);

    const chained = find(list, "reset, clear_screen").?;
    try testing.expectEqualStrings("Reset, clear screen", chained.title);
}

test "term3: shortcuts: humanize" {
    const alloc = testing.allocator;
    const cases = [_][2][]const u8{
        .{ "goto_tab:3", "Goto tab: 3" },
        .{ "quit", "Quit" },
        .{ "text:a_b", "Text: a_b" },
        .{ "", "" },
    };
    for (cases) |c| {
        const got = try humanize(alloc, c[0]);
        defer alloc.free(got);
        try testing.expectEqualStrings(c[1], got);
    }
}

const TestIterator = struct {
    data: []const []const u8,
    i: usize = 0,

    pub fn next(self: *TestIterator) ?[]const u8 {
        if (self.i >= self.data.len) return null;
        const result = self.data[self.i];
        self.i += 1;
        return result;
    }
};
