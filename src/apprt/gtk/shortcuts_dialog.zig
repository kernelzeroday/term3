//! term3: the Keyboard Shortcuts dialog (main menu > Keyboard Shortcuts).
//!
//! Lists every keybind in the current config, one row per action, grouped
//! by category, with the dialog's built-in search over action titles. The
//! rows come from `term3_shortcuts.collect`; this file only builds widgets.
//!
//! This is an `Adw.PreferencesDialog` rather than `Adw.ShortcutsDialog`
//! because the latter needs libadwaita 1.8 and term3 supports 1.7.

const std = @import("std");
const adw = @import("adw");
const gtk = @import("gtk");

const i18n = @import("../../os/main.zig").i18n;
const configpkg = @import("../../config.zig");
const input = @import("../../input.zig");
const key = @import("key.zig");
const shortcuts = @import("../../term3_shortcuts.zig");

const log = std.log.scoped(.gtk_term3_shortcuts);

pub fn present(parent: *gtk.Widget, config: *const configpkg.Config) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const list = shortcuts.collect(alloc, &config.keybind.set) catch |err| {
        log.warn("failed to list keyboard shortcuts: {}", .{err});
        return;
    };

    const dialog = adw.PreferencesDialog.new();
    dialog.as(adw.Dialog).setTitle(i18n._("Keyboard Shortcuts"));
    dialog.as(adw.Dialog).setContentWidth(640);
    dialog.as(adw.Dialog).setContentHeight(720);
    dialog.setSearchEnabled(1);

    const page = adw.PreferencesPage.new();
    page.setTitle(i18n._("Keyboard Shortcuts"));
    page.setIconName("preferences-desktop-keyboard-shortcuts-symbolic");
    dialog.add(page);

    if (list.len == 0) {
        const group = adw.PreferencesGroup.new();
        group.setTitle(i18n._("No keyboard shortcuts are configured"));
        page.add(group);
    }

    // `list` is sorted by category, so start a new group whenever the
    // category changes.
    var group: ?*adw.PreferencesGroup = null;
    var current: ?shortcuts.Category = null;
    for (list) |s| {
        if (current != s.category) {
            current = s.category;
            const g = adw.PreferencesGroup.new();
            g.setTitle(i18n._(s.category.title()));
            page.add(g);
            group = g;
        }

        const row = adw.ActionRow.new();
        const prow = row.as(adw.PreferencesRow);
        // Titles and action names are plain text, not Pango markup.
        prow.setUseMarkup(0);
        prow.setTitle(s.title);
        // The config name, so the row says what to write in a keybind.
        row.setSubtitle(s.action);
        row.addSuffix(keysWidget(alloc, s.sequences));
        group.?.add(row.as(gtk.Widget));
    }

    dialog.as(adw.Dialog).present(parent);
}

/// An action's key sequences, one per line so rows with several bindings
/// stay narrow. A leader sequence's keys are separated by a dim "›".
fn keysWidget(
    alloc: std.mem.Allocator,
    sequences: []const []const input.Binding.Trigger,
) *gtk.Widget {
    const column = gtk.Box.new(.vertical, 4);
    column.as(gtk.Widget).setValign(.center);
    column.as(gtk.Widget).setMarginTop(6);
    column.as(gtk.Widget).setMarginBottom(6);

    for (sequences) |seq| {
        const line = gtk.Box.new(.horizontal, 6);
        line.as(gtk.Widget).setHalign(.end);
        for (seq, 0..) |trigger, j| {
            if (j > 0) line.append(dimLabel("›"));
            line.append(triggerWidget(alloc, trigger));
        }
        column.append(line.as(gtk.Widget));
    }

    return column.as(gtk.Widget);
}

fn triggerWidget(alloc: std.mem.Allocator, trigger: input.Binding.Trigger) *gtk.Widget {
    var buf: [128]u8 = undefined;
    if (key.accelFromTrigger(&buf, trigger) catch null) |accel| {
        return gtk.ShortcutLabel.new(accel).as(gtk.Widget);
    }

    // No GTK accelerator for this key (e.g. `catch_all`): show the
    // trigger as written in a config file.
    const text = std.fmt.allocPrintSentinel(alloc, "{f}", .{trigger}, 0) catch "?";
    return gtk.Label.new(text).as(gtk.Widget);
}

fn dimLabel(text: [:0]const u8) *gtk.Widget {
    const label = gtk.Label.new(text).as(gtk.Widget);
    label.addCssClass("dim-label");
    return label;
}
