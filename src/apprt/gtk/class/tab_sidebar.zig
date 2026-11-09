//! term3: the vertical tab sidebar.
//!
//! This widget shows the pages of an `Adw.TabView` as a vertical list and
//! is used in place of `Adw.TabBar` when `gtk-tabs-location` is `left` or
//! `right`. It deliberately has no state of its own beyond presentation:
//! the tab view's page model is the source of truth for which tabs exist,
//! their order, their titles, and which one is selected. Every action
//! (select, close, reorder) is performed on the tab view, and the list
//! rebuilds itself from the model's change notifications.
//!
//! Rows have a uniform, fixed height so the sidebar never changes shape as
//! tabs are added or retitled. The sidebar's width only changes when the
//! user drags its inner edge or the config changes.

const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const configpkg = @import("../../../config.zig");
const term3 = @import("../../../term3.zig");
const i18n = @import("../../../os/main.zig").i18n;
const ext = @import("../ext.zig");
const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const Surface = @import("surface.zig").Surface;
const Tab = @import("tab.zig").Tab;

const log = std.log.scoped(.gtk_ghostty_tab_sidebar);

pub const TitleOverflow = configpkg.Config.GtkSidebarTitleOverflow;
pub const Subtitle = configpkg.Config.GtkSidebarSubtitle;

/// Which side of the window the sidebar is on. This determines which edge
/// the resize handle is on and which way dragging it grows the sidebar.
pub const Side = term3.Side;

/// Marquee timing for the `scroll` title overflow mode.
const marquee: term3.Marquee = .{};

/// Object data keys used to stash marquee state on a row's scrolled window.
const marquee_tick_key = "term3-marquee-tick";
const marquee_start_key = "term3-marquee-start";

pub const TabSidebar = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyTabSidebar",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        pub const @"tab-view" = struct {
            pub const name = "tab-view";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*adw.TabView,
                .{
                    .accessor = .{
                        .getter = getTabViewValue,
                        .setter = setTabViewValue,
                    },
                },
            );
        };
    };

    const Private = struct {
        /// The tab view whose pages we display. We hold a strong ref.
        tab_view: ?*adw.TabView = null,

        /// Signal handlers connected to `tab_view` and its page model, so
        /// they can be disconnected when the tab view changes.
        selected_handler: c_ulong = 0,
        items_handler: c_ulong = 0,

        /// True while we are changing the list selection ourselves so that
        /// `row-selected` doesn't feed back into the tab view.
        syncing_selection: bool = false,

        /// Presentation options, set by the window from the config.
        overflow: TitleOverflow = .ellipsize,
        title_lines: u8 = 2,
        subtitle: Subtitle = .@"working-directory",
        side: Side = .left,
        width: c_int = 220,

        /// The width at the start of a resize drag.
        drag_start_width: c_int = 0,

        // Template bindings
        root: *gtk.Box,
        content: *gtk.Box,
        list: *gtk.ListBox,
        handle: *gtk.Separator,
        row_popover: *gtk.PopoverMenu,

        pub var offset: c_int = 0;
    };

    pub fn new() *Self {
        return gobject.ext.newInstance(Self, .{});
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
        const priv = self.private();

        // The resize handle.
        const handle = priv.handle.as(gtk.Widget);
        handle.setCursorFromName("col-resize");
        const drag = gtk.GestureDrag.new();
        _ = gtk.GestureDrag.signals.drag_begin.connect(
            drag,
            *Self,
            handleDragBegin,
            self,
            .{},
        );
        _ = gtk.GestureDrag.signals.drag_update.connect(
            drag,
            *Self,
            handleDragUpdate,
            self,
            .{},
        );
        handle.addController(drag.as(gtk.EventController));

        // Dropping a tab row onto the list reorders it.
        const drop = gtk.DropTarget.new(
            adw.TabPage.getGObjectType(),
            .{ .move = true },
        );
        _ = gtk.DropTarget.signals.drop.connect(
            drop,
            *Self,
            listDrop,
            self,
            .{},
        );
        _ = gtk.DropTarget.signals.motion.connect(
            drop,
            *Self,
            listDropMotion,
            self,
            .{},
        );
        _ = gtk.DropTarget.signals.leave.connect(
            drop,
            *Self,
            listDropLeave,
            self,
            .{},
        );
        priv.list.as(gtk.Widget).addController(drop.as(gtk.EventController));

        self.applyWidth();
    }

    //---------------------------------------------------------------
    // Public API

    pub fn getTabView(self: *Self) ?*adw.TabView {
        return self.private().tab_view;
    }

    pub fn setTabView(self: *Self, tab_view_: ?*adw.TabView) void {
        const priv = self.private();
        if (tab_view_ == priv.tab_view) return;

        self.disconnectTabView();

        if (tab_view_) |tab_view| {
            priv.tab_view = @ptrCast(tab_view.as(gobject.Object).ref());
            priv.selected_handler = gobject.Object.signals.notify.connect(
                tab_view,
                *Self,
                tabViewSelectedPage,
                self,
                .{ .detail = "selected-page" },
            );
            priv.items_handler = gio.ListModel.signals.items_changed.connect(
                tab_view.getPages().as(gio.ListModel),
                *Self,
                pagesItemsChanged,
                self,
                .{ .after = true },
            );
        }

        self.rebuild();
        self.as(gobject.Object).notifyByPspec(
            properties.@"tab-view".impl.param_spec,
        );
    }

    /// Set presentation options. Rows are rebuilt only if something that
    /// affects them changed. The width is applied only when `width`
    /// differs from the last configured width, so a config reload that
    /// doesn't touch `gtk-sidebar-width` keeps a width the user dragged to.
    pub fn setOptions(self: *Self, opts: struct {
        side: Side,
        width: u32,
        overflow: TitleOverflow,
        title_lines: u8,
        subtitle: Subtitle,
    }) void {
        const priv = self.private();

        const lines = term3.clampTitleLines(opts.title_lines);
        const rows_changed = opts.overflow != priv.overflow or
            lines != priv.title_lines or
            opts.subtitle != priv.subtitle;
        priv.overflow = opts.overflow;
        priv.title_lines = lines;
        priv.subtitle = opts.subtitle;

        if (opts.side != priv.side) {
            priv.side = opts.side;
            const root = priv.root;
            const handle = priv.handle.as(gtk.Widget);
            const content = priv.content.as(gtk.Widget);
            switch (opts.side) {
                .left => root.reorderChildAfter(handle, content),
                .right => root.reorderChildAfter(content, handle),
            }
        }

        const width: c_int = term3.clampWidth(opts.width);
        if (width != priv.width) {
            priv.width = width;
            self.applyWidth();
        }

        if (rows_changed) self.rebuild();
    }

    //---------------------------------------------------------------
    // Model binding

    fn disconnectTabView(self: *Self) void {
        const priv = self.private();
        const tab_view = priv.tab_view orelse return;
        if (priv.selected_handler != 0) {
            gobject.signalHandlerDisconnect(
                tab_view.as(gobject.Object),
                priv.selected_handler,
            );
            priv.selected_handler = 0;
        }
        if (priv.items_handler != 0) {
            gobject.signalHandlerDisconnect(
                tab_view.getPages().as(gobject.Object),
                priv.items_handler,
            );
            priv.items_handler = 0;
        }
        priv.list.bindModel(null, null, null, null);
        tab_view.unref();
        priv.tab_view = null;
    }

    /// Recreate every row from the tab view's page model.
    fn rebuild(self: *Self) void {
        const priv = self.private();
        priv.list.bindModel(null, null, null, null);
        const tab_view = priv.tab_view orelse return;
        priv.list.bindModel(
            tab_view.getPages().as(gio.ListModel),
            createRow,
            self,
            null,
        );
        self.syncSelection();
    }

    /// Select the row for the tab view's selected page.
    fn syncSelection(self: *Self) void {
        const priv = self.private();
        const tab_view = priv.tab_view orelse return;
        priv.syncing_selection = true;
        defer priv.syncing_selection = false;

        const page = tab_view.getSelectedPage() orelse {
            priv.list.unselectAll();
            return;
        };
        const row = priv.list.getRowAtIndex(tab_view.getPagePosition(page));
        priv.list.selectRow(row);
    }

    /// Returns the page at `index` in the tab view. The returned page is
    /// borrowed; the tab view keeps it alive.
    fn pageAt(self: *Self, index: c_int) ?*adw.TabPage {
        const tab_view = self.private().tab_view orelse return null;
        if (index < 0 or index >= tab_view.getNPages()) return null;
        return tab_view.getNthPage(index);
    }

    /// True if `page` belongs to our tab view.
    fn ownsPage(self: *Self, page: *adw.TabPage) bool {
        const tab_view = self.private().tab_view orelse return false;
        var i: c_int = 0;
        const n = tab_view.getNPages();
        while (i < n) : (i += 1) {
            if (tab_view.getNthPage(i) == page) return true;
        }
        return false;
    }

    fn tabViewSelectedPage(
        _: *adw.TabView,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.syncSelection();
    }

    fn pagesItemsChanged(
        _: *gio.ListModel,
        _: c_uint,
        _: c_uint,
        _: c_uint,
        self: *Self,
    ) callconv(.c) void {
        // The list box recreated rows for the changed range in its own
        // (earlier) handler, which drops their selection. Restore it.
        self.syncSelection();
    }

    fn rowSelected(
        _: *gtk.ListBox,
        row_: ?*gtk.ListBoxRow,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        if (priv.syncing_selection) return;
        const row = row_ orelse return;
        const tab_view = priv.tab_view orelse return;
        const page = self.pageAt(row.getIndex()) orelse return;
        tab_view.setSelectedPage(page);
    }

    //---------------------------------------------------------------
    // Rows

    fn createRow(
        item: *gobject.Object,
        ud: ?*anyopaque,
    ) callconv(.c) *gtk.Widget {
        const self: *Self = @ptrCast(@alignCast(ud.?));
        const priv = self.private();
        const page: *adw.TabPage = gobject.ext.cast(adw.TabPage, item).?;
        const page_obj = page.as(gobject.Object);

        const row = gtk.ListBoxRow.new();
        const row_widget = row.as(gtk.Widget);
        row_widget.setFocusable(0);
        row_widget.addCssClass("tab-sidebar-row");

        const box = gtk.Box.new(.horizontal, 6);
        row.setChild(box.as(gtk.Widget));

        // Bell / attention indicator.
        const attention = gtk.Image.newFromIconName("media-record-symbolic");
        attention.as(gtk.Widget).addCssClass("tab-sidebar-attention");
        attention.as(gtk.Widget).setValign(.center);
        _ = page_obj.bindProperty(
            "needs-attention",
            attention.as(gobject.Object),
            "visible",
            .{ .sync_create = true },
        );
        box.append(attention.as(gtk.Widget));

        // Title, and optionally a subtitle beneath it.
        const text_box = gtk.Box.new(.vertical, 0);
        const text_widget = text_box.as(gtk.Widget);
        text_widget.setHexpand(1);
        text_widget.setValign(.center);
        box.append(text_widget);

        const label = gtk.Label.new(null);
        const label_widget = label.as(gtk.Widget);
        label_widget.addCssClass("tab-sidebar-title");
        label.setXalign(0);
        label.setYalign(0.5);
        // Keep the label's natural width tiny so a long title never asks
        // the sidebar to grow; it fills whatever width the row has.
        label.setMaxWidthChars(1);
        _ = page_obj.bindProperty(
            "title",
            label.as(gobject.Object),
            "label",
            .{ .sync_create = true },
        );
        switch (priv.overflow) {
            .ellipsize => {
                label.setEllipsize(.end);
                label.setSingleLineMode(1);
                label_widget.setHexpand(1);
                text_box.append(label_widget);
            },

            .wrap => {
                const lines: c_int = priv.title_lines;
                label.setWrap(1);
                label.setWrapMode(.word_char);
                label.setLines(lines);
                label.setEllipsize(.end);
                label.setYalign(0);
                label_widget.setHexpand(1);

                // Reserve the same height in every row, whether or not the
                // title actually needs every line, so rows stay uniform.
                const layout = label_widget.createPangoLayout("Ag");
                defer layout.unref();
                var line_height: c_int = 0;
                layout.getPixelSize(null, &line_height);
                label_widget.setSizeRequest(-1, line_height * lines);
                text_box.append(label_widget);
            },

            .scroll => {
                label.setSingleLineMode(1);

                const scroller = gtk.ScrolledWindow.new();
                const scroller_widget = scroller.as(gtk.Widget);
                scroller.setPolicy(.external, .never);
                scroller.setPropagateNaturalHeight(1);
                scroller_widget.setHexpand(1);
                scroller_widget.setCanTarget(0);
                scroller.setChild(label_widget);
                text_box.append(scroller_widget);

                const motion = gtk.EventControllerMotion.new();
                _ = gtk.EventControllerMotion.signals.enter.connect(
                    motion,
                    *gtk.ScrolledWindow,
                    marqueeEnter,
                    scroller,
                    .{},
                );
                _ = gtk.EventControllerMotion.signals.leave.connect(
                    motion,
                    *gtk.ScrolledWindow,
                    marqueeLeave,
                    scroller,
                    .{},
                );
                row_widget.addController(motion.as(gtk.EventController));
            },
        }

        switch (priv.subtitle) {
            .none => {},
            .@"working-directory" => text_box.append(createPwdLabel(page)),
        }

        // Close button, shown on hover and on the selected row via CSS.
        const close = gtk.Button.newFromIconName("window-close-symbolic");
        const close_widget = close.as(gtk.Widget);
        close_widget.addCssClass("flat");
        close_widget.addCssClass("circular");
        close_widget.addCssClass("tab-sidebar-close");
        close_widget.setValign(.center);
        close_widget.setFocusable(0);
        close_widget.setFocusOnClick(0);
        close_widget.setTooltipText(i18n._("Close Tab"));
        _ = gtk.Button.signals.clicked.connect(
            close,
            *adw.TabPage,
            closeClicked,
            page,
            .{},
        );
        box.append(close_widget);

        // The full title as the tooltip, for titles that are cut off.
        _ = page_obj.bindProperty(
            "title",
            row.as(gobject.Object),
            "tooltip-text",
            .{ .sync_create = true },
        );

        // Middle-click closes, right-click opens the tab menu.
        const click = gtk.GestureClick.new();
        click.as(gtk.GestureSingle).setButton(0);
        _ = gtk.GestureClick.signals.pressed.connect(
            click,
            *adw.TabPage,
            rowPressed,
            page,
            .{},
        );
        row_widget.addController(click.as(gtk.EventController));

        // Rows can be dragged to reorder tabs.
        const drag = gtk.DragSource.new();
        drag.setActions(.{ .move = true });
        _ = gtk.DragSource.signals.prepare.connect(
            drag,
            *adw.TabPage,
            rowDragPrepare,
            page,
            .{},
        );
        _ = gtk.DragSource.signals.drag_begin.connect(
            drag,
            *gtk.ListBoxRow,
            rowDragBegin,
            row,
            .{},
        );
        row_widget.addController(drag.as(gtk.EventController));

        return row_widget;
    }

    /// A label showing the working directory of the page's focused
    /// terminal. It is bound with a GtkExpression on the tab's title and
    /// the property chain tab -> active-surface -> pwd, which GTK keeps up
    /// to date as the title changes, the focused split changes, or the
    /// shell reports a new directory. It is left blank when the title
    /// already shows the directory. The label always occupies one line,
    /// even when empty, so every row has the same height.
    fn createPwdLabel(page: *adw.TabPage) *gtk.Widget {
        const label = gtk.Label.new("");
        const widget = label.as(gtk.Widget);
        widget.addCssClass("tab-sidebar-subtitle");
        widget.addCssClass("dim-label");
        label.setXalign(0);
        label.setSingleLineMode(1);
        label.setMaxWidthChars(1);
        // Keep the end of a long path, which is the part that tells
        // directories apart.
        label.setEllipsize(.start);

        const surface_expr = gtk.PropertyExpression.new(
            Tab.getGObjectType(),
            null,
            "active-surface",
        );
        const pwd_expr = gtk.PropertyExpression.new(
            Surface.getGObjectType(),
            surface_expr.as(gtk.Expression),
            "pwd",
        );
        const title_expr = gtk.PropertyExpression.new(
            Tab.getGObjectType(),
            null,
            "title",
        );
        var params = [_]*gtk.Expression{
            title_expr.as(gtk.Expression),
            pwd_expr.as(gtk.Expression),
        };
        const display_expr = gtk.CClosureExpression.new(
            gobject.ext.types.string,
            null,
            params.len,
            &params,
            @ptrCast(&formatPwd),
            null,
            null,
        );
        // Takes ownership of the expression; the watch ends when the
        // label or the tab is finalized.
        _ = display_expr.as(gtk.Expression).bind(
            label.as(gobject.Object),
            "label",
            page.getChild().as(gobject.Object),
        );
        return widget;
    }

    /// Closure for createPwdLabel: the display form of a working directory.
    /// Returns a newly allocated string, which GTK takes ownership of.
    fn formatPwd(
        _: ?*gobject.Object,
        title_: ?[*:0]const u8,
        pwd_: ?[*:0]const u8,
        _: ?*anyopaque,
    ) callconv(.c) ?[*:0]const u8 {
        const pwd = std.mem.span(pwd_ orelse return glib.ext.dupeZ(u8, ""));
        var buf: [4096]u8 = undefined;
        const home = std.mem.span(glib.getHomeDir());
        const display = term3.abbreviateHome(&buf, pwd, home);
        const title = if (title_) |t| std.mem.span(t) else "";
        if (term3.subtitleRepeatsTitle(title, display, pwd)) {
            return glib.ext.dupeZ(u8, "");
        }
        return glib.ext.dupeZ(u8, display);
    }

    /// Find the sidebar that contains `widget`.
    fn fromChild(widget: *gtk.Widget) ?*Self {
        return ext.getAncestor(Self, widget);
    }

    fn closeClicked(button: *gtk.Button, page: *adw.TabPage) callconv(.c) void {
        const self = fromChild(button.as(gtk.Widget)) orelse return;
        const tab_view = self.private().tab_view orelse return;
        tab_view.closePage(page);
    }

    fn rowPressed(
        gesture: *gtk.GestureClick,
        _: c_int,
        x: f64,
        y: f64,
        page: *adw.TabPage,
    ) callconv(.c) void {
        const controller = gesture.as(gtk.EventController);
        const widget = controller.getWidget() orelse return;
        const self = fromChild(widget) orelse return;
        const priv = self.private();
        const tab_view = priv.tab_view orelse return;

        switch (gesture.as(gtk.GestureSingle).getCurrentButton()) {
            gdk.BUTTON_MIDDLE => {
                _ = gesture.as(gtk.Gesture).setState(.claimed);
                tab_view.closePage(page);
            },

            gdk.BUTTON_SECONDARY => {
                _ = gesture.as(gtk.Gesture).setState(.claimed);

                // The menu actions act on the selected tab.
                tab_view.setSelectedPage(page);

                var px: f64 = 0;
                var py: f64 = 0;
                if (widget.translateCoordinates(
                    priv.row_popover.as(gtk.Widget).getParent() orelse return,
                    x,
                    y,
                    &px,
                    &py,
                ) == 0) return;

                const rect: gdk.Rectangle = .{
                    .f_x = @intFromFloat(px),
                    .f_y = @intFromFloat(py),
                    .f_width = 1,
                    .f_height = 1,
                };
                const popover = priv.row_popover.as(gtk.Popover);
                popover.setPointingTo(&rect);
                popover.popup();
            },

            else => {},
        }
    }

    //---------------------------------------------------------------
    // Drag to reorder

    fn rowDragPrepare(
        _: *gtk.DragSource,
        _: f64,
        _: f64,
        page: *adw.TabPage,
    ) callconv(.c) ?*gdk.ContentProvider {
        var val = gobject.ext.Value.newFrom(page);
        defer val.unset();
        return gdk.ContentProvider.newForValue(&val);
    }

    fn rowDragBegin(
        src: *gtk.DragSource,
        _: *gdk.Drag,
        row: *gtk.ListBoxRow,
    ) callconv(.c) void {
        const paintable = gtk.WidgetPaintable.new(row.as(gtk.Widget));
        defer paintable.unref();
        src.setIcon(paintable.as(gdk.Paintable), 0, 0);
    }

    fn listDropMotion(
        _: *gtk.DropTarget,
        _: f64,
        y: f64,
        self: *Self,
    ) callconv(.c) gdk.DragAction {
        const list = self.private().list;
        if (list.getRowAtY(@intFromFloat(y))) |row| {
            list.dragHighlightRow(row);
        } else {
            list.dragUnhighlightRow();
        }
        return .{ .move = true };
    }

    fn listDropLeave(_: *gtk.DropTarget, self: *Self) callconv(.c) void {
        self.private().list.dragUnhighlightRow();
    }

    fn listDrop(
        _: *gtk.DropTarget,
        value: *gobject.Value,
        _: f64,
        y: f64,
        self: *Self,
    ) callconv(.c) c_int {
        const priv = self.private();
        priv.list.dragUnhighlightRow();
        const tab_view = priv.tab_view orelse return 0;

        const page = gobject.ext.Value.get(value, ?*adw.TabPage) orelse return 0;

        // Tabs dragged from another window's tab bar or sidebar aren't
        // ours to reorder; ignore them.
        if (!self.ownsPage(page)) return 0;

        const target: c_int = if (priv.list.getRowAtY(@intFromFloat(y))) |row|
            row.getIndex()
        else
            tab_view.getNPages() - 1;

        _ = tab_view.reorderPage(page, target);
        tab_view.setSelectedPage(page);
        return 1;
    }

    //---------------------------------------------------------------
    // Resizing

    fn applyWidth(self: *Self) void {
        const priv = self.private();
        self.as(gtk.Widget).setSizeRequest(priv.width, -1);
    }

    fn handleDragBegin(
        _: *gtk.GestureDrag,
        _: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        priv.drag_start_width = priv.width;
    }

    fn handleDragUpdate(
        _: *gtk.GestureDrag,
        offset_x: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        priv.width = term3.dragWidth(priv.drag_start_width, offset_x, priv.side);
        self.applyWidth();
    }

    //---------------------------------------------------------------
    // Marquee (title overflow = scroll)

    fn marqueeEnter(
        _: *gtk.EventControllerMotion,
        _: f64,
        _: f64,
        scroller: *gtk.ScrolledWindow,
    ) callconv(.c) void {
        const obj = scroller.as(gobject.Object);
        if (obj.getData(marquee_tick_key) != null) return;
        const id = scroller.as(gtk.Widget).addTickCallback(marqueeTick, null, null);
        obj.setData(marquee_tick_key, @ptrFromInt(id));
        obj.setData(marquee_start_key, null);
    }

    fn marqueeLeave(
        _: *gtk.EventControllerMotion,
        scroller: *gtk.ScrolledWindow,
    ) callconv(.c) void {
        const obj = scroller.as(gobject.Object);
        if (obj.getData(marquee_tick_key)) |id| {
            scroller.as(gtk.Widget).removeTickCallback(@intCast(@intFromPtr(id)));
        }
        obj.setData(marquee_tick_key, null);
        obj.setData(marquee_start_key, null);
        scroller.getHadjustment().setValue(0);
    }

    fn marqueeTick(
        widget: *gtk.Widget,
        clock: *gdk.FrameClock,
        _: ?*anyopaque,
    ) callconv(.c) c_int {
        const scroller = gobject.ext.cast(gtk.ScrolledWindow, widget) orelse return 0;
        const obj = scroller.as(gobject.Object);
        const now = clock.getFrameTime();

        // Frame times are microseconds since an arbitrary, positive epoch.
        const start: i64 = if (obj.getData(marquee_start_key)) |v|
            @intCast(@intFromPtr(v))
        else start: {
            obj.setData(marquee_start_key, @ptrFromInt(@as(usize, @intCast(now))));
            break :start now;
        };

        const adj = scroller.getHadjustment();
        const overflow = adj.getUpper() - adj.getPageSize();
        const elapsed_s = @as(f64, @floatFromInt(now - start)) / std.time.us_per_s;
        adj.setValue(marquee.offset(elapsed_s, overflow));
        return 1;
    }

    //---------------------------------------------------------------
    // Properties

    fn getTabViewValue(self: *Self, value: *gobject.Value) void {
        gobject.ext.Value.set(value, self.private().tab_view);
    }

    fn setTabViewValue(self: *Self, value: *const gobject.Value) void {
        self.setTabView(gobject.ext.Value.get(value, ?*adw.TabView));
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn dispose(self: *Self) callconv(.c) void {
        self.disconnectTabView();

        // Detach our child (the template's `root`) from AdwBin ourselves.
        // Otherwise disposeTemplate releases `root` first and AdwBin's
        // dispose then unparents a dead widget ("gtk_widget_unparent:
        // assertion 'GTK_IS_WIDGET (widget)' failed"), found by the GUI
        // test. The template still holds a ref, so `root` stays valid
        // until disposeTemplate below.
        self.as(adw.Bin).setChild(null);

        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 0,
                    .name = "tab-sidebar",
                }),
            );

            gobject.ext.registerProperties(class, &.{
                properties.@"tab-view".impl,
            });

            class.bindTemplateChildPrivate("root", .{});
            class.bindTemplateChildPrivate("content", .{});
            class.bindTemplateChildPrivate("list", .{});
            class.bindTemplateChildPrivate("handle", .{});
            class.bindTemplateChildPrivate("row_popover", .{});

            class.bindTemplateCallback("row_selected", &rowSelected);

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
