const std = @import("std");
const dvui = @import("../dvui.zig");

const Event = dvui.Event;
const Options = dvui.Options;
const Point = dvui.Point;
const Rect = dvui.Rect;
const RectScale = dvui.RectScale;
const Size = dvui.Size;
const Widget = dvui.Widget;
const WidgetData = dvui.WidgetData;
const FloatingWidget = dvui.FloatingWidget;

const TextLayoutWidget = @This();

pub var defaults: Options = .{
    .name = "TextLayout",
    .margin = Rect.all(4),
    .padding = Rect.all(4),
    .background = true,
    .min_size_content = .{ .w = 250 },
};

pub const InitOptions = struct {
    selection: ?*Selection = null,
    break_lines: bool = true,

    // Whether to enter touch editing mode on a touch-release (no drag) if we
    // were not focused before the touch.
    touch_edit_just_focused: bool = true,
};

pub const Selection = struct {
    cursor: usize = 0,
    start: usize = 0,
    end: usize = 0,

    pub fn empty(self: *Selection) bool {
        return self.start == self.end;
    }

    pub fn selectAll(self: *Selection) void {
        self.start = 0;
        self.cursor = 0;
        self.end = std.math.maxInt(usize);
    }

    pub fn moveCursor(self: *Selection, idx: usize, shift: bool) void {
        if (shift) {
            if (self.cursor == self.start) {
                // move the start
                self.cursor = idx;
                self.start = idx;
            } else {
                // move the end
                self.cursor = idx;
                self.end = idx;
            }
        } else {
            // not an expanded selection
            self.cursor = idx;
            self.start = idx;
            self.end = idx;
        }

        self.order();
    }

    pub fn order(self: *Selection) void {
        if (self.end < self.start) {
            const tmp = self.start;
            self.start = self.end;
            self.end = tmp;
        }
    }
};

wd: WidgetData = undefined,
corners: [4]?Rect = [_]?Rect{null} ** 4,
corners_min_size: [4]?Size = [_]?Size{null} ** 4,
corners_last_seen: ?u8 = null,
insert_pt: Point = Point{},
current_line_height: f32 = 0.0,
prevClip: Rect = Rect{},
first_line: bool = true,
break_lines: bool = undefined,
touch_edit_just_focused: bool = undefined,

cursor_pt: ?Point = null,
click_pt: ?Point = null,
click_num: u8 = 0,

bytes_seen: usize = 0,
selection_in: ?*Selection = null,
selection: *Selection = undefined,
selection_store: Selection = .{},
sel_mouse_down_pt: ?Point = null,
sel_mouse_down_bytes: ?usize = null,
sel_mouse_drag_pt: ?Point = null,
sel_left_right: i8 = 0,
sel_left_right_buf: [10]u8 = [1]u8{0} ** 10,
sel_start_r: Rect = .{},
sel_start_r_new: ?Rect = null,
sel_end_r: Rect = .{},
sel_end_r_new: ?Rect = null,
sel_pts: [2]?Point = [2]?Point{ null, null },
sel_word: enum { none, precursor, aftcursor } = .none,
sel_word_last_space: usize = 0,

cursor_seen: bool = false,
cursor_rect: ?Rect = null,
cursor_updown: i8 = 0, // positive is down
cursor_updown_drag: bool = true,
cursor_updown_pt: ?Point = null,
scroll_to_cursor: bool = false,

add_text_done: bool = false,

copy_sel: ?Selection = null,
copy_slice: ?[]u8 = null,

// when this is true and we have focus, show the floating widget with select all, copy, etc.
touch_editing: bool = false,
te_first: bool = true,
te_show_draggables: bool = true,
te_show_context_menu: bool = true,
te_focus_on_touchdown: bool = false,
focus_at_start: bool = false,
te_floating: FloatingWidget = undefined,

pub fn init(src: std.builtin.SourceLocation, init_opts: InitOptions, opts: Options) TextLayoutWidget {
    const options = defaults.override(opts);
    var self = TextLayoutWidget{ .wd = WidgetData.init(src, .{}, options), .selection_in = init_opts.selection };
    self.break_lines = init_opts.break_lines;
    self.touch_edit_just_focused = init_opts.touch_edit_just_focused;
    self.touch_editing = dvui.dataGet(null, self.wd.id, "_touch_editing", bool) orelse false;
    self.te_first = dvui.dataGet(null, self.wd.id, "_te_first", bool) orelse true;
    self.te_show_draggables = dvui.dataGet(null, self.wd.id, "_te_show_draggables", bool) orelse true;
    self.te_show_context_menu = dvui.dataGet(null, self.wd.id, "_te_show_context_menu", bool) orelse true;
    self.te_focus_on_touchdown = dvui.dataGet(null, self.wd.id, "_te_focus_on_touchdown", bool) orelse false;

    self.sel_start_r = dvui.dataGet(null, self.wd.id, "_sel_start_r", Rect) orelse .{};
    self.sel_end_r = dvui.dataGet(null, self.wd.id, "_sel_end_r", Rect) orelse .{};

    self.click_num = dvui.dataGet(null, self.wd.id, "_click_num", u8) orelse 0;

    return self;
}

pub fn install(self: *TextLayoutWidget, opts: struct { focused: ?bool = null, show_touch_draggables: bool = true }) !void {
    self.focus_at_start = opts.focused orelse (self.wd.id == dvui.focusedWidgetId());

    try self.wd.register();
    dvui.parentSet(self.widget());

    if (self.selection_in) |sel| {
        self.selection = sel;
    } else {
        if (dvui.dataGet(null, self.wd.id, "_selection", Selection)) |s| {
            self.selection_store = s;
        }
        self.selection = &self.selection_store;
    }

    if (dvui.captured(self.wd.id)) {
        if (dvui.dataGet(null, self.wd.id, "_sel_mouse_down_bytes", usize)) |p| {
            self.sel_mouse_down_bytes = p;
        }
    }

    if (dvui.dataGet(null, self.wd.id, "_cursor_updown_pt", Point)) |p| {
        self.cursor_updown_pt = p;
        dvui.dataRemove(null, self.wd.id, "_cursor_updown_pt");
        if (dvui.dataGet(null, self.wd.id, "_cursor_updown_drag", bool)) |cud| {
            self.cursor_updown_drag = cud;
        }
    }

    const rs = self.wd.contentRectScale();

    try self.wd.borderAndBackground(.{});

    self.prevClip = dvui.clip(rs.r);

    if (opts.show_touch_draggables and self.touch_editing and self.te_show_draggables and self.focus_at_start and self.wd.visible()) {
        const size = 36;
        {

            // calculate visible before FloatingWidget changes clip

            // We only draw if visible (to prevent drawing way outside the
            // textLayout), but we always process the floating window so that
            // we maintain capture.  That way you can drag a draggable off the
            // textLayout (so it's not visible), which causes a scroll, but
            // when the draggable shows back up you are still dragging it.

            // sel_start_r might be just off the right-hand edge, so widen it
            var cursor = self.sel_start_r;
            cursor.x -= 1;
            cursor.w += 1;
            const visible = !dvui.clipGet().intersect(rs.rectToScreen(cursor)).empty();

            var rect = self.sel_start_r;
            rect.y += rect.h; // move to below the line
            const srs = self.screenRectScale(rect);
            rect = dvui.windowRectScale().rectFromScreen(srs.r);
            rect.x -= size;
            rect.w = size;
            rect.h = size;

            var fc = dvui.FloatingWidget.init(@src(), .{ .rect = rect });
            try fc.install();

            var offset: Point = dvui.dataGet(null, fc.wd.id, "_offset", Point) orelse .{};

            const fcrs = fc.wd.rectScale();
            const evts = dvui.events();
            for (evts) |*e| {
                if (!dvui.eventMatch(e, .{ .id = fc.wd.id, .r = fcrs.r }))
                    continue;

                if (e.evt == .mouse) {
                    const me = e.evt.mouse;
                    if (me.action == .press and me.button.touch()) {
                        dvui.captureMouse(fc.wd.id);
                        self.te_show_context_menu = false;
                        offset = fcrs.r.topRight().diff(me.p);

                        // give an extra offset of half the cursor height
                        offset.y -= self.sel_start_r.h * 0.5 * rs.s;
                    } else if (me.action == .release and me.button.touch()) {
                        dvui.captureMouse(null);
                    } else if (me.action == .motion and dvui.captured(fc.wd.id)) {
                        const corner = me.p.plus(offset);
                        self.sel_pts[0] = self.wd.contentRectScale().pointFromScreen(corner);
                        self.sel_pts[1] = self.sel_end_r.topLeft().plus(.{ .y = self.sel_end_r.h / 2 });

                        self.sel_pts[0].?.y = @min(self.sel_pts[0].?.y, self.sel_pts[1].?.y);

                        var scrolldrag = Event{ .evt = .{ .scroll_drag = .{
                            .mouse_pt = e.evt.mouse.p,
                            .screen_rect = self.wd.rectScale().r,
                            .capture_id = self.wd.id,
                        } } };
                        self.processEvent(&scrolldrag, true);
                    }
                }
            }

            if (visible) {
                try dvui.pathAddPoint(.{ .x = fcrs.r.x + fcrs.r.w, .y = fcrs.r.y });
                try dvui.pathAddArc(.{ .x = fcrs.r.x + fcrs.r.w / 2, .y = fcrs.r.y + fcrs.r.h / 2 }, fcrs.r.w / 2, std.math.pi, 0, true);
                try dvui.pathFillConvex(dvui.themeGet().color_fill_control);

                try dvui.pathAddPoint(.{ .x = fcrs.r.x + fcrs.r.w, .y = fcrs.r.y });
                try dvui.pathAddArc(.{ .x = fcrs.r.x + fcrs.r.w / 2, .y = fcrs.r.y + fcrs.r.h / 2 }, fcrs.r.w / 2, std.math.pi, 0, true);
                try dvui.pathStroke(true, 1.0, .none, self.wd.options.color(.border));
            }

            dvui.dataSet(null, fc.wd.id, "_offset", offset);
            fc.deinit();
        }

        {
            // calculate visible before FloatingWidget changes clip

            // sel_end_r might be just off the right-hand edge, so widen it
            var cursor = self.sel_end_r;
            cursor.x -= 1;
            cursor.w += 1;
            const visible = !dvui.clipGet().intersect(rs.rectToScreen(cursor)).empty();

            var rect = self.sel_end_r;
            rect.y += rect.h; // move to below the line
            const srs = self.screenRectScale(rect);
            rect = dvui.windowRectScale().rectFromScreen(srs.r);
            rect.w = size;
            rect.h = size;

            var fc = dvui.FloatingWidget.init(@src(), .{ .rect = rect });
            try fc.install();

            var offset: Point = dvui.dataGet(null, fc.wd.id, "_offset", Point) orelse .{};

            const fcrs = fc.wd.rectScale();
            const evts = dvui.events();
            for (evts) |*e| {
                if (!dvui.eventMatch(e, .{ .id = fc.wd.id, .r = fcrs.r }))
                    continue;

                if (e.evt == .mouse) {
                    const me = e.evt.mouse;
                    if (me.action == .press and me.button.touch()) {
                        dvui.captureMouse(fc.wd.id);
                        self.te_show_context_menu = false;
                        offset = fcrs.r.topLeft().diff(me.p);

                        // give an extra offset of half the cursor height
                        offset.y -= self.sel_start_r.h * 0.5 * rs.s;
                    } else if (me.action == .release and me.button.touch()) {
                        dvui.captureMouse(null);
                    } else if (me.action == .motion and dvui.captured(fc.wd.id)) {
                        const corner = me.p.plus(offset);
                        self.sel_pts[0] = self.sel_start_r.topLeft().plus(.{ .y = self.sel_start_r.h / 2 });
                        self.sel_pts[1] = self.wd.contentRectScale().pointFromScreen(corner);

                        self.sel_pts[1].?.y = @max(self.sel_pts[0].?.y, self.sel_pts[1].?.y);

                        var scrolldrag = Event{ .evt = .{ .scroll_drag = .{
                            .mouse_pt = e.evt.mouse.p,
                            .screen_rect = self.wd.rectScale().r,
                            .capture_id = self.wd.id,
                        } } };
                        self.processEvent(&scrolldrag, true);
                    }
                }
            }

            if (visible) {
                try dvui.pathAddPoint(.{ .x = fcrs.r.x, .y = fcrs.r.y });
                try dvui.pathAddArc(.{ .x = fcrs.r.x + fcrs.r.w / 2, .y = fcrs.r.y + fcrs.r.h / 2 }, fcrs.r.w / 2, std.math.pi, 0, true);
                try dvui.pathFillConvex(dvui.themeGet().color_fill_control);

                try dvui.pathAddPoint(.{ .x = fcrs.r.x, .y = fcrs.r.y });
                try dvui.pathAddArc(.{ .x = fcrs.r.x + fcrs.r.w / 2, .y = fcrs.r.y + fcrs.r.h / 2 }, fcrs.r.w / 2, std.math.pi, 0, true);
                try dvui.pathStroke(true, 1.0, .none, self.wd.options.color(.border));
            }

            dvui.dataSet(null, fc.wd.id, "_offset", offset);
            fc.deinit();
        }
    }
}

pub fn format(self: *TextLayoutWidget, comptime fmt: []const u8, args: anytype, opts: Options) !void {
    const cw = dvui.currentWindow();
    const l = try std.fmt.allocPrint(cw.arena, fmt, args);
    try self.addText(l, opts);
}

pub fn addText(self: *TextLayoutWidget, text: []const u8, opts: Options) !void {
    _ = try self.addTextEx(text, false, opts);
}

pub fn addTextClick(self: *TextLayoutWidget, text: []const u8, opts: Options) !bool {
    return try self.addTextEx(text, true, opts);
}

fn addTextEx(self: *TextLayoutWidget, text: []const u8, clickable: bool, opts: Options) !bool {
    var clicked = false;

    const options = self.wd.options.override(opts);
    const msize = try options.fontGet().textSize("m");
    const line_height = try options.fontGet().lineHeight();
    self.current_line_height = @max(self.current_line_height, line_height);
    var txt = text;

    const rect = self.wd.contentRect();
    var container_width = rect.w;
    if (container_width == 0) {
        // if we are not being shown at all, probably this is the first
        // frame for us and we should calculate our min height assuming we
        // get at least our min width

        // do this dance so we aren't repeating the contentRect
        // calculations here
        const given_width = self.wd.rect.w;
        self.wd.rect.w = @max(given_width, self.wd.min_size.w);
        container_width = self.wd.contentRect().w;
        self.wd.rect.w = given_width;
    }

    while (txt.len > 0) {
        var linestart: f32 = 0;
        var linewidth = container_width;
        var width = linewidth - self.insert_pt.x;
        var width_after: f32 = 0;
        for (self.corners, 0..) |corner, i| {
            if (corner) |cor| {
                if (@max(cor.y, self.insert_pt.y) < @min(cor.y + cor.h, self.insert_pt.y + self.current_line_height)) {
                    linewidth -= cor.w;
                    if (linestart == cor.x) {
                        // used below - if we moved over for a widget, we
                        // can drop to the next line expecting more room
                        // later
                        linestart = (cor.x + cor.w);
                    }

                    if (self.insert_pt.x <= (cor.x + cor.w)) {
                        width -= cor.w;
                        if (self.insert_pt.x >= cor.x) {
                            // widget on left side, skip over it
                            self.insert_pt.x = (cor.x + cor.w);
                        } else {
                            // widget on right side, need to add width to min_size below
                            width_after = self.corners_min_size[i].?.w;
                        }
                    }
                }
            }
        }

        var end: usize = undefined;

        // get slice of text that fits within width or ends with newline
        var s = try options.fontGet().textSizeEx(txt, if (self.break_lines) width else null, &end, .before);

        // ensure we always get at least 1 codepoint so we make progress
        if (end == 0) {
            end = std.unicode.utf8ByteSequenceLength(txt[0]) catch 1;
            s = try options.fontGet().textSize(txt[0..end]);
        }

        const newline = (txt[end - 1] == '\n');

        //std.debug.print("{d} 1 txt to {d} \"{s}\"\n", .{ container_width, end, txt[0..end] });

        // if we are boxed in too much by corner widgets drop to next line
        if (self.break_lines and s.w > width and linewidth < container_width) {
            self.insert_pt.y += self.current_line_height;
            self.insert_pt.x = 0;
            self.current_line_height = line_height;
            continue;
        }

        // try to break on space if:
        // - slice ended due to width (not newline)
        // - linewidth is long enough (otherwise too narrow to break on space)
        if (self.break_lines and end < txt.len and !newline and linewidth > (10 * msize.w)) {
            const space: []const u8 = &[_]u8{' '};
            // now we are under the length limit but might be in the middle of a word
            // look one char further because we might be right at the end of a word
            const spaceIdx = std.mem.lastIndexOfLinear(u8, txt[0 .. end + 1], space);
            if (spaceIdx) |si| {
                end = si + 1;
                s = try options.fontGet().textSize(txt[0..end]);
            } else if (self.insert_pt.x > linestart) {
                // can't fit breaking on space, but we aren't starting at the left edge
                // so drop to next line
                self.insert_pt.y += self.current_line_height;
                self.insert_pt.x = 0;
                self.current_line_height = line_height;
                continue;
            }
        }

        // now we know the line of text we are about to render
        // see if selection needs to be updated

        // if the text changed our selection might be in the middle of utf8 chars, so fix it up
        while (self.selection.start >= self.bytes_seen and self.selection.start < self.bytes_seen + end and txt[self.selection.start - self.bytes_seen] & 0xc0 == 0x80) {
            self.selection.start += 1;
        }

        while (self.selection.cursor >= self.bytes_seen and self.selection.cursor < self.bytes_seen + end and txt[self.selection.cursor - self.bytes_seen] & 0xc0 == 0x80) {
            self.selection.cursor += 1;
        }

        while (self.selection.end >= self.bytes_seen and self.selection.end < self.bytes_seen + end and txt[self.selection.end - self.bytes_seen] & 0xc0 == 0x80) {
            self.selection.end += 1;
        }

        if (clickable) {
            if (self.cursor_pt) |p| {
                const rs = Rect{ .x = self.insert_pt.x, .y = self.insert_pt.y, .w = s.w, .h = s.h };
                if (p.x > rs.x and p.x < (rs.x + rs.w) and p.y > rs.y and p.y < (rs.y + rs.h)) {
                    // point is in this text
                    dvui.cursorSet(.hand);
                }
            }

            if (self.click_pt) |p| {
                const rs = Rect{ .x = self.insert_pt.x, .y = self.insert_pt.y, .w = s.w, .h = s.h };
                if (p.x > rs.x and p.x < (rs.x + rs.w) and p.y > rs.y and p.y < (rs.y + rs.h)) {
                    clicked = true;
                }
            }
        }

        if (self.sel_mouse_down_pt) |p| {
            const rs = Rect{ .x = self.insert_pt.x, .y = self.insert_pt.y, .w = s.w, .h = s.h };
            if (p.y < rs.y or (p.y < (rs.y + rs.h) and p.x < rs.x)) {
                // point is before this text
                self.sel_mouse_down_bytes = self.bytes_seen;
                self.selection.cursor = self.sel_mouse_down_bytes.?;
                self.selection.start = self.sel_mouse_down_bytes.?;
                self.selection.end = self.sel_mouse_down_bytes.?;
                self.sel_mouse_down_pt = null;
            } else if (p.y < (rs.y + rs.h) and p.x < (rs.x + rs.w)) {
                // point is in this text
                const how_far = p.x - rs.x;
                var pt_end: usize = undefined;
                _ = try options.fontGet().textSizeEx(txt, how_far, &pt_end, .nearest);
                self.sel_mouse_down_bytes = self.bytes_seen + pt_end;
                self.selection.cursor = self.sel_mouse_down_bytes.?;
                self.selection.start = self.sel_mouse_down_bytes.?;
                self.selection.end = self.sel_mouse_down_bytes.?;
                self.sel_mouse_down_pt = null;
            } else {
                if (newline and p.y < (rs.y + rs.h)) {
                    // point is after this text on this same horizontal line
                    self.sel_mouse_down_bytes = self.bytes_seen + end - 1;
                    self.sel_mouse_down_pt = null;
                } else {
                    // point is after this text, but we might not get anymore
                    self.sel_mouse_down_bytes = self.bytes_seen + end;
                }
                self.selection.cursor = self.sel_mouse_down_bytes.?;
                self.selection.start = self.sel_mouse_down_bytes.?;
                self.selection.end = self.sel_mouse_down_bytes.?;
            }
            self.scroll_to_cursor = true;
        }

        if (self.sel_mouse_drag_pt) |p| {
            const rs = Rect{ .x = self.insert_pt.x, .y = self.insert_pt.y, .w = s.w, .h = s.h };
            if (p.y < rs.y or (p.y < (rs.y + rs.h) and p.x < rs.x)) {
                // point is before this text
                self.selection.cursor = self.bytes_seen;
                self.selection.start = @min(self.sel_mouse_down_bytes.?, self.bytes_seen);
                self.selection.end = @max(self.sel_mouse_down_bytes.?, self.bytes_seen);
                self.sel_mouse_drag_pt = null;
            } else if (p.y < (rs.y + rs.h) and p.x < (rs.x + rs.w)) {
                // point is in this text
                const how_far = p.x - rs.x;
                var pt_end: usize = undefined;
                _ = try options.fontGet().textSizeEx(txt, how_far, &pt_end, .nearest);
                self.selection.cursor = self.bytes_seen + pt_end;
                self.selection.start = @min(self.sel_mouse_down_bytes.?, self.bytes_seen + pt_end);
                self.selection.end = @max(self.sel_mouse_down_bytes.?, self.bytes_seen + pt_end);
                self.sel_mouse_drag_pt = null;
            } else {
                // point is after this text, but we might not get anymore
                self.selection.cursor = self.bytes_seen + end;
                self.selection.start = @min(self.sel_mouse_down_bytes.?, self.bytes_seen + end);
                self.selection.end = @max(self.sel_mouse_down_bytes.?, self.bytes_seen + end);
            }

            // don't set scroll_to_cursor here because when we are dragging
            // we are already doing a scroll_drag in processEvent
        }

        if (self.cursor_updown_pt) |p| {
            const rs = Rect{ .x = self.insert_pt.x, .y = self.insert_pt.y, .w = s.w, .h = s.h };
            if (p.y < rs.y or (p.y < (rs.y + rs.h) and p.x < rs.x)) {
                // point is before this text
                self.selection.moveCursor(self.bytes_seen, self.cursor_updown_drag);
                self.cursor_updown_pt = null;
                self.scroll_to_cursor = true;
            } else if (p.y < (rs.y + rs.h) and p.x < (rs.x + rs.w)) {
                // point is in this text
                const how_far = p.x - rs.x;
                var pt_end: usize = undefined;
                _ = try options.fontGet().textSizeEx(txt, how_far, &pt_end, .nearest);
                self.selection.moveCursor(self.bytes_seen + pt_end, self.cursor_updown_drag);
                self.cursor_updown_pt = null;
                self.scroll_to_cursor = true;
            } else {
                if (newline and p.y < (rs.y + rs.h)) {
                    // point is after this text on this same horizontal line
                    self.selection.moveCursor(self.bytes_seen + end - 1, self.cursor_updown_drag);
                    self.cursor_updown_pt = null;
                } else {
                    // point is after this text, but we might not get anymore
                    self.selection.moveCursor(self.bytes_seen + end, self.cursor_updown_drag);
                }
                self.scroll_to_cursor = true;
            }
        }

        if (self.sel_pts[0] != null or self.sel_pts[1] != null) {
            var sel_bytes = [2]?usize{ null, null };
            for (self.sel_pts, 0..) |maybe_pt, i| {
                if (maybe_pt) |p| {
                    const rs = Rect{ .x = self.insert_pt.x, .y = self.insert_pt.y, .w = s.w, .h = s.h };
                    if (p.y < rs.y or (p.y < (rs.y + rs.h) and p.x < rs.x)) {
                        // point is before this text
                        sel_bytes[i] = self.bytes_seen;
                        self.sel_pts[i] = null;
                    } else if (p.y < (rs.y + rs.h) and p.x < (rs.x + rs.w)) {
                        // point is in this text
                        const how_far = p.x - rs.x;
                        var pt_end: usize = undefined;
                        _ = try options.fontGet().textSizeEx(txt, how_far, &pt_end, .nearest);
                        sel_bytes[i] = self.bytes_seen + pt_end;
                        self.sel_pts[i] = null;
                    } else {
                        if (newline and p.y < (rs.y + rs.h)) {
                            // point is after this text on this same horizontal line
                            sel_bytes[i] = self.bytes_seen + end - 1;
                            self.sel_pts[i] = null;
                        } else {
                            // point is after this text, but we might not get anymore
                            sel_bytes[i] = self.bytes_seen + end;
                        }
                    }
                }
            }

            //std.debug.print("sel_bytes {?d} {?d}\n", .{ sel_bytes[0], sel_bytes[1] });

            // start off getting both, then maybe getting one
            if (sel_bytes[0] != null and sel_bytes[1] != null) {
                self.selection.cursor = @min(sel_bytes[0].?, sel_bytes[1].?);
                self.selection.start = @min(sel_bytes[0].?, sel_bytes[1].?);
                self.selection.end = @max(sel_bytes[0].?, sel_bytes[1].?);

                // changing touch selection, need to refresh to move draggables
                dvui.refresh(null, @src(), self.wd.id);
            } else if (sel_bytes[0] != null or sel_bytes[1] != null) {
                self.selection.end = sel_bytes[0] orelse sel_bytes[1].?;
            }
        }

        // record screen position of selection for touch editing (use s for
        // height in case we are calling textSize with an empty slice)
        if (self.selection.start >= self.bytes_seen and self.selection.start <= self.bytes_seen + end) {
            const start_off = try options.fontGet().textSize(txt[0..self.selection.start -| self.bytes_seen]);
            self.sel_start_r_new = .{ .x = self.insert_pt.x + start_off.w, .y = self.insert_pt.y, .w = 1, .h = s.h };
        }

        if (self.selection.end >= self.bytes_seen and self.selection.end <= self.bytes_seen + end) {
            const end_off = try options.fontGet().textSize(txt[0..self.selection.end -| self.bytes_seen]);
            self.sel_end_r_new = .{ .x = self.insert_pt.x + end_off.w, .y = self.insert_pt.y, .w = 1, .h = s.h };
        }

        if (!self.cursor_seen and self.selection.cursor < self.bytes_seen + end) {
            self.cursor_seen = true;
            const size = try options.fontGet().textSize(txt[0 .. self.selection.cursor - self.bytes_seen]);
            const cr = Rect{ .x = self.insert_pt.x + size.w, .y = self.insert_pt.y, .w = 1, .h = try options.fontGet().lineHeight() };

            if (self.cursor_updown != 0 and self.cursor_updown_pt == null) {
                const cr_new = cr.plus(.{ .y = @as(f32, @floatFromInt(self.cursor_updown)) * try options.fontGet().lineHeight() });
                const updown_pt = cr_new.topLeft().plus(.{ .y = cr_new.h / 2 });
                self.cursor_updown = 0;

                // forward the pixel position we want the cursor to be in to
                // the next frame
                dvui.dataSet(null, self.wd.id, "_cursor_updown_pt", updown_pt);
                dvui.dataSet(null, self.wd.id, "_cursor_updown_drag", self.cursor_updown_drag);

                // might have already passed, so need to go again next frame
                dvui.refresh(null, @src(), self.wd.id);

                var scrollto = Event{ .evt = .{ .scroll_to = .{
                    .screen_rect = self.screenRectScale(cr_new).r,
                } } };
                self.processEvent(&scrollto, true);
            }

            if (self.scroll_to_cursor) {
                var scrollto = Event{ .evt = .{ .scroll_to = .{
                    .screen_rect = self.screenRectScale(cr.outset(self.wd.options.paddingGet())).r,
                } } };
                self.processEvent(&scrollto, true);
            }

            if (self.selection.start == self.selection.end) {
                self.cursor_rect = cr;
            }
        }

        loop: while (self.sel_word != .none) {
            switch (self.sel_word) {
                .precursor => {
                    // maintain index of last space/newline we saw
                    const sofar = txt[0..@min(self.selection.cursor -| self.bytes_seen, end)];
                    const space = std.mem.lastIndexOfScalar(u8, sofar, ' ');
                    const nline = std.mem.lastIndexOfScalar(u8, sofar, '\n');
                    if (space != null or nline != null) {
                        const last = @max(space orelse 0, nline orelse 0);
                        self.sel_word_last_space = last + self.bytes_seen + 1;
                    }

                    if (self.cursor_seen) {
                        self.selection.moveCursor(self.sel_word_last_space, true);
                        self.selection.cursor = self.selection.end; // put cursor at end for the aftcursor logic
                        self.sel_word = .aftcursor;
                    } else {
                        break :loop;
                    }
                },
                .aftcursor => {
                    // find next space/newline
                    const space = std.mem.indexOfScalarPos(u8, txt, self.selection.cursor -| self.bytes_seen, ' ');
                    const nline = std.mem.indexOfScalarPos(u8, txt, self.selection.cursor -| self.bytes_seen, '\n');
                    if (space != null or nline != null) {
                        const first = @min(space orelse std.math.maxInt(usize), nline orelse std.math.maxInt(usize));
                        self.selection.moveCursor(self.bytes_seen + first, true);
                        self.sel_word = .none;
                        dvui.refresh(null, @src(), self.wd.id);
                    }

                    break :loop;
                },
                .none => {},
            }
        }

        if (self.sel_left_right < 0) {
            // save a small lookback buffer

            const last_idx = @min(self.selection.cursor, self.bytes_seen + end) -| self.bytes_seen;
            for (self.sel_left_right_buf, 0..) |_, i| {
                if (i + last_idx >= self.sel_left_right_buf.len) {
                    self.sel_left_right_buf[i] = txt[last_idx + i - self.sel_left_right_buf.len];
                } else {
                    self.sel_left_right_buf[i] = self.sel_left_right_buf[i + last_idx];
                }
            }

            if (self.cursor_seen) {
                while (self.sel_left_right < 0) {
                    var cur = self.selection.cursor;

                    // move cursor one utf8 char left
                    cur -|= 1;
                    while (cur > self.bytes_seen and self.sel_left_right_buf[self.sel_left_right_buf.len + cur - self.selection.cursor] & 0xc0 == 0x80) {
                        // in the middle of a multibyte char
                        cur -|= 1;
                    }

                    self.selection.moveCursor(cur, true);
                    self.sel_left_right += 1;
                }

                self.sel_left_right = 0;

                dvui.refresh(null, @src(), self.wd.id);
            }
        }

        while (self.cursor_seen and self.sel_left_right > 0 and self.selection.cursor < (self.bytes_seen + end)) {
            var cur = self.selection.cursor;

            // move cursor one utf8 char right
            cur += std.unicode.utf8ByteSequenceLength(txt[cur - self.bytes_seen]) catch 1;

            self.selection.moveCursor(cur, true);
            self.sel_left_right -= 1;

            dvui.refresh(null, @src(), self.wd.id);
        }

        const rs = self.screenRectScale(Rect{ .x = self.insert_pt.x, .y = self.insert_pt.y, .w = width, .h = @max(0, rect.h - self.insert_pt.y) });
        //std.debug.print("renderText: {} {s}\n", .{ rs.r, txt[0..end] });
        const rtxt = if (newline) txt[0 .. end - 1] else txt[0..end];
        try dvui.renderText(.{
            .font = options.fontGet(),
            .text = rtxt,
            .rs = rs,
            .color = options.color(.text),
            .sel_start = self.selection.start -| self.bytes_seen,
            .sel_end = self.selection.end -| self.bytes_seen,
            .sel_color = options.color(.fill),
            .sel_color_bg = options.color(.accent),
        });

        // Even if we don't actually render (might be outside clipping region),
        // need to update insert_pt and minSize like we did because our parent
        // might size based on that (might be in a scroll area)
        self.insert_pt.x += s.w;
        const size = self.wd.padSize(.{ .w = self.insert_pt.x, .h = self.insert_pt.y + s.h });
        if (!self.break_lines) {
            self.wd.min_size.w = @max(self.wd.min_size.w, size.w + width_after);
        }
        self.wd.min_size.h = @max(self.wd.min_size.h, size.h);

        if (self.copy_sel) |sel| {
            // we are copying to clipboard
            if (sel.start < self.bytes_seen + end) {
                // need to copy some
                const cstart = if (sel.start < self.bytes_seen) 0 else (sel.start - self.bytes_seen);
                const cend = if (sel.end < self.bytes_seen + end) (sel.end - self.bytes_seen) else end;

                // initialize or realloc
                if (self.copy_slice) |slice| {
                    const old_len = slice.len;
                    self.copy_slice = try dvui.currentWindow().arena.realloc(slice, slice.len + (cend - cstart));
                    @memcpy(self.copy_slice.?[old_len..], txt[cstart..cend]);
                } else {
                    self.copy_slice = try dvui.currentWindow().arena.dupe(u8, txt[cstart..cend]);
                }

                // push to clipboard if done
                if (sel.end <= self.bytes_seen + end) {
                    try dvui.clipboardTextSet(self.copy_slice.?);

                    self.copy_sel = null;
                    dvui.currentWindow().arena.free(self.copy_slice.?);
                    self.copy_slice = null;
                }
            }
        }

        // discard bytes we've dealt with
        txt = txt[end..];
        self.bytes_seen += end;

        // move insert_pt to next line if we have more text
        if (txt.len > 0 or newline) {
            self.insert_pt.y += self.current_line_height;
            self.insert_pt.x = 0;
            if (txt.len > 0) {
                self.current_line_height = line_height;
            } else if (newline) {
                self.current_line_height = 0;
            }

            if (newline) {
                const newline_size = self.wd.padSize(.{ .w = self.insert_pt.x, .h = self.insert_pt.y + s.h });
                if (!self.break_lines) {
                    self.wd.min_size.w = @max(self.wd.min_size.w, newline_size.w);
                }
                self.wd.min_size.h = @max(self.wd.min_size.h, newline_size.h);
            }
        }

        if (newline and (self.selection.start == self.bytes_seen)) {
            self.sel_start_r_new = .{ .x = self.insert_pt.x, .y = self.insert_pt.y, .w = 1, .h = s.h };
        }

        if (newline and (self.selection.end == self.bytes_seen)) {
            self.sel_end_r_new = .{ .x = self.insert_pt.x, .y = self.insert_pt.y, .w = 1, .h = s.h };
        }

        if (self.wd.options.rect != null) {
            // we were given a rect, so don't need to calculate our min height,
            // so stop as soon as we run off the end of the clipping region
            // this helps for performance
            const nextrs = self.screenRectScale(Rect{ .x = self.insert_pt.x, .y = self.insert_pt.y });
            if (nextrs.r.y > (dvui.clipGet().y + dvui.clipGet().h)) {
                //std.debug.print("stopping after: {s}\n", .{rtxt});
                break;
            }
        }
    }

    if (clicked) {
        // we can only click when not in touch editing, so that click must have
        // transitioned us into touch editing, but we don't want to transition
        // if the click happened on clickable text
        self.touch_editing = false;
    }

    return clicked;
}

pub fn addTextDone(self: *TextLayoutWidget, opts: Options) !void {
    self.add_text_done = true;

    if (self.copy_sel) |_| {
        // we are copying to clipboard and never stopped
        try dvui.clipboardTextSet(self.copy_slice orelse "");

        self.copy_sel = null;
        if (self.copy_slice) |cs| {
            dvui.currentWindow().arena.free(cs);
        }
        self.copy_slice = null;
    }

    // if we had mouse/keyboard interaction, need to handle things if addText never gets called
    if (self.sel_mouse_down_pt) |_| {
        self.sel_mouse_down_bytes = self.bytes_seen;
    }

    if (self.sel_start_r_new) |start_r| {
        if (!self.sel_start_r.equals(start_r)) {
            dvui.refresh(null, @src(), self.wd.id);
        }
        self.sel_start_r = start_r;
    }

    if (self.selection.start > self.bytes_seen or self.bytes_seen == 0) {
        const options = self.wd.options.override(opts);
        self.sel_start_r = .{ .x = self.insert_pt.x, .y = self.insert_pt.y, .w = 1, .h = try options.fontGet().lineHeight() };
        if (self.selection.start > self.bytes_seen) {
            dvui.refresh(null, @src(), self.wd.id);
        }
    }

    if (self.sel_end_r_new) |end_r| {
        if (!self.sel_end_r.equals(end_r)) {
            dvui.refresh(null, @src(), self.wd.id);
        }
        self.sel_end_r = end_r;
    }

    if (self.selection.end > self.bytes_seen or self.bytes_seen == 0) {
        const options = self.wd.options.override(opts);
        self.sel_end_r = .{ .x = self.insert_pt.x, .y = self.insert_pt.y, .w = 1, .h = try options.fontGet().lineHeight() };
        if (self.selection.end > self.bytes_seen) {
            dvui.refresh(null, @src(), self.wd.id);
        }
    }

    self.selection.cursor = @min(self.selection.cursor, self.bytes_seen);
    self.selection.start = @min(self.selection.start, self.bytes_seen);
    self.selection.end = @min(self.selection.end, self.bytes_seen);

    if (self.sel_word == .aftcursor) {
        self.selection.moveCursor(self.bytes_seen, true);
        self.sel_word = .none;
        dvui.refresh(null, @src(), self.wd.id);
    }

    if (!self.cursor_seen) {
        self.cursor_seen = true;
        self.selection.cursor = self.bytes_seen;

        const options = self.wd.options.override(opts);
        const cr = Rect{ .x = self.insert_pt.x, .y = self.insert_pt.y, .w = 1, .h = try options.fontGet().lineHeight() };

        if (self.cursor_updown != 0 and self.cursor_updown_pt == null) {
            const cr_new = cr.plus(.{ .y = @as(f32, @floatFromInt(self.cursor_updown)) * try options.fontGet().lineHeight() });
            const updown_pt = cr_new.topLeft().plus(.{ .y = cr_new.h / 2 });
            self.cursor_updown = 0;

            // forward the pixel position we want the cursor to be in to
            // the next frame
            dvui.dataSet(null, self.wd.id, "_cursor_updown_pt", updown_pt);
            dvui.dataSet(null, self.wd.id, "_cursor_updown_drag", self.cursor_updown_drag);

            // might have already passed, so need to go again next frame
            dvui.refresh(null, @src(), self.wd.id);

            var scrollto = Event{ .evt = .{ .scroll_to = .{
                .screen_rect = self.screenRectScale(cr_new).r,
            } } };
            self.processEvent(&scrollto, true);
        }

        if (self.sel_left_right < 0) {
            while (self.sel_left_right < 0) {
                var cur = self.selection.cursor;

                // move cursor one utf8 char left
                cur -|= 1;
                while (cur > self.bytes_seen and self.sel_left_right_buf[self.sel_left_right_buf.len + cur - self.selection.cursor] & 0xc0 == 0x80) {
                    // in the middle of a multibyte char
                    cur -|= 1;
                }

                self.selection.moveCursor(cur, true);
                self.sel_left_right += 1;
            }

            self.sel_left_right = 0;

            dvui.refresh(null, @src(), self.wd.id);
        }

        if (self.scroll_to_cursor) {
            var scrollto = Event{ .evt = .{ .scroll_to = .{
                .screen_rect = self.screenRectScale(cr.outset(self.wd.options.paddingGet())).r,
            } } };
            self.processEvent(&scrollto, true);
        }

        if (self.selection.start == self.selection.end) {
            self.cursor_rect = cr;
        }
    }
}

pub fn touchEditing(self: *TextLayoutWidget) !?*FloatingWidget {
    if (self.touch_editing and self.te_show_context_menu and self.focus_at_start and self.wd.visible()) {
        self.te_floating = dvui.FloatingWidget.init(@src(), .{});

        const r = dvui.clipGet().offsetNeg(dvui.windowRectPixels()).scale(1.0 / dvui.windowNaturalScale());

        if (dvui.minSizeGet(self.te_floating.data().id)) |_| {
            const ms = dvui.minSize(self.te_floating.data().id, self.te_floating.data().options.min_sizeGet());
            self.te_floating.wd.rect.w = ms.w;
            self.te_floating.wd.rect.h = ms.h;

            self.te_floating.wd.rect.x = r.x + r.w - self.te_floating.wd.rect.w;
            self.te_floating.wd.rect.y = r.y - self.te_floating.wd.rect.h - self.wd.options.paddingGet().y;

            self.te_floating.wd.rect = dvui.placeOnScreen(dvui.windowRect(), .{ .x = self.te_floating.wd.rect.x, .y = self.te_floating.wd.rect.y }, self.te_floating.wd.rect);
        } else {
            // need another frame to get our min size
            dvui.refresh(null, @src(), self.te_floating.wd.id);
        }

        try self.te_floating.install();
        return &self.te_floating;
    }

    return null;
}

pub fn touchEditingMenu(self: *TextLayoutWidget) !void {
    var hbox = try dvui.box(@src(), .horizontal, .{
        .corner_radius = dvui.ButtonWidget.defaults.corner_radiusGet(),
        .background = true,
        .border = dvui.Rect.all(1),
    });
    defer hbox.deinit();

    if (try dvui.buttonIcon(@src(), "select all", dvui.entypo.swap, .{}, .{ .min_size_content = .{ .h = 20 }, .margin = Rect.all(2) })) {
        self.selection.selectAll();
    }

    if (try dvui.buttonIcon(@src(), "copy", dvui.entypo.copy, .{}, .{ .min_size_content = .{ .h = 20 }, .margin = Rect.all(2) })) {
        self.copy();
    }
}

pub fn widget(self: *TextLayoutWidget) Widget {
    return Widget.init(self, data, rectFor, screenRectScale, minSizeForChild, processEvent);
}

pub fn data(self: *TextLayoutWidget) *WidgetData {
    return &self.wd;
}

pub fn rectFor(self: *TextLayoutWidget, id: u32, min_size: Size, e: Options.Expand, g: Options.Gravity) Rect {
    const ret = dvui.placeIn(self.wd.contentRect().justSize(), dvui.minSize(id, min_size), e, g);
    var i: usize = undefined;
    if (g.y < 0.5) {
        if (g.x < 0.5) {
            i = 0; // upleft
        } else {
            i = 1; // upright
        }
    } else {
        if (g.x < 0.5) {
            i = 2; // downleft
        } else {
            i = 3; // downright
        }
    }

    self.corners[i] = ret;
    self.corners_last_seen = @intCast(i);
    return ret;
}

pub fn screenRectScale(self: *TextLayoutWidget, rect: Rect) RectScale {
    return self.wd.contentRectScale().rectToRectScale(rect);
}

pub fn minSizeForChild(self: *TextLayoutWidget, s: Size) void {
    if (self.corners_last_seen) |ls| {
        self.corners_min_size[ls] = s;
    }
    // we calculate our min size in deinit() after we have seen our text
}

// Using this function helps prevent accidentally using the selection when the
// end is way too large, because the way we do select all is to set end to
// maxInt(usize) and fix it up the next frame.
//
// Either the caller knows the max (like TextEntryWidget), or they can pass
// maxInt(usize) and be clued into what might happen.
pub fn selectionGet(self: *TextLayoutWidget, max: usize) *Selection {
    self.selection.start = @min(self.selection.start, max);
    self.selection.cursor = @min(self.selection.cursor, max);
    self.selection.end = @min(self.selection.end, max);
    return self.selection;
}

pub fn matchEvent(self: *TextLayoutWidget, e: *Event) bool {
    if (self.touch_editing and e.evt == .mouse and e.evt.mouse.action == .release and e.evt.mouse.button.touch()) {
        self.te_show_draggables = true;
        self.te_show_context_menu = true;
        dvui.refresh(null, @src(), self.wd.id);
    }

    return dvui.eventMatch(e, .{ .id = self.data().id, .r = self.data().borderRectScale().r });
}

pub fn processEvents(self: *TextLayoutWidget) void {
    const evts = dvui.events();
    for (evts) |*e| {
        if (!self.matchEvent(e))
            continue;

        self.processEvent(e, false);
    }

    // we could have gotten multiple conflicting keyboard/mouse movements, so
    // here we decide which to actually do
    if (self.sel_mouse_down_pt != null or self.sel_mouse_drag_pt != null) {
        // doing mouse click-drag selection, turn off other stuff
        self.cursor_updown = 0;
        self.cursor_updown_pt = null;
        self.sel_left_right = 0;
        self.scroll_to_cursor = false;
    } else if (self.cursor_updown != 0 or self.cursor_updown_pt != null) {
        // moving cursor vertically
        self.sel_left_right = 0;
    }
}

pub fn processEvent(self: *TextLayoutWidget, e: *Event, bubbling: bool) void {
    _ = bubbling;
    if (e.evt == .mouse) {
        if (e.evt.mouse.action == .focus) {
            e.handled = true;
            // focus so that we can receive keyboard input
            dvui.focusWidget(self.wd.id, null, e.num);
        } else if (e.evt.mouse.action == .press and e.evt.mouse.button.pointer()) {
            e.handled = true;
            // capture and start drag
            dvui.captureMouse(self.wd.id);
            dvui.dragPreStart(e.evt.mouse.p, .ibeam, Point{});

            if (e.evt.mouse.button.touch()) {
                self.te_focus_on_touchdown = self.focus_at_start;
                if (self.touch_editing) {
                    self.te_show_context_menu = false;

                    // need to refresh draggables
                    dvui.refresh(null, @src(), self.wd.id);
                }
            } else {
                self.sel_mouse_down_pt = self.wd.contentRectScale().pointFromScreen(e.evt.mouse.p);
                self.sel_mouse_drag_pt = null;

                self.sel_word = .none;
                if (self.click_num == 1) {
                    self.sel_word = .precursor;
                }
            }
        } else if (e.evt.mouse.action == .release and e.evt.mouse.button.pointer()) {
            e.handled = true;

            if (dvui.captured(self.wd.id)) {
                if (!self.touch_editing and dvui.dragging(e.evt.mouse.p) == null) {
                    // click without drag
                    self.click_pt = self.wd.contentRectScale().pointFromScreen(e.evt.mouse.p);

                    self.click_num += 1;
                    if (self.click_num == 4) {
                        self.click_num = 1;
                    }
                }

                if (e.evt.mouse.button.touch()) {
                    // this was a touch-release without drag, which transitions
                    // us between touch editing

                    if (self.te_focus_on_touchdown) {
                        self.touch_editing = !self.touch_editing;
                        self.sel_mouse_down_pt = self.wd.contentRectScale().pointFromScreen(e.evt.mouse.p);
                        if (self.touch_editing) {
                            self.sel_word = .precursor; // select the word we touched
                        }
                    } else {
                        if (self.touch_edit_just_focused) {
                            self.touch_editing = true;
                        }
                        if (self.te_first) {
                            // This is the very first time we are entering
                            // touch editing from not having focus, we want to
                            // position the cursor.
                            self.te_first = false;
                            self.sel_mouse_down_pt = self.wd.contentRectScale().pointFromScreen(e.evt.mouse.p);
                            self.sel_word = .precursor; // select the word we touched
                        }
                    }
                    dvui.refresh(null, @src(), self.wd.id);
                }

                dvui.captureMouse(null);
            }
        } else if (e.evt.mouse.action == .motion and dvui.captured(self.wd.id)) {
            if (dvui.dragging(e.evt.mouse.p)) |_| {
                self.click_num = 0;
                if (!e.evt.mouse.button.touch()) {
                    e.handled = true;
                    self.sel_mouse_drag_pt = self.wd.contentRectScale().pointFromScreen(e.evt.mouse.p);
                    var scrolldrag = Event{ .evt = .{ .scroll_drag = .{
                        .mouse_pt = e.evt.mouse.p,
                        .screen_rect = self.wd.rectScale().r,
                        .capture_id = self.wd.id,
                    } } };
                    self.processEvent(&scrolldrag, true);
                } else {
                    // user intended to scroll with a finger swipe
                    dvui.captureMouse(null); // stop possible drag and capture
                }
            }
        } else if (e.evt.mouse.action == .motion) {
            self.click_num = 0;
        } else if (e.evt.mouse.action == .position) {
            e.handled = true;
            self.cursor_pt = self.wd.contentRectScale().pointFromScreen(e.evt.mouse.p);
        }
    } else if (e.evt == .key and (e.evt.key.action == .down or e.evt.key.action == .repeat) and e.evt.key.mod.shift()) {
        switch (e.evt.key.code) {
            .left => {
                e.handled = true;
                self.sel_left_right -= 1;
                self.scroll_to_cursor = true;
            },
            .right => {
                e.handled = true;
                self.sel_left_right += 1;
                self.scroll_to_cursor = true;
            },
            .up, .down => |code| {
                e.handled = true;
                self.cursor_updown += if (code == .down) 1 else -1;
            },
            else => {},
        }
    } else if (e.evt == .key and e.evt.key.mod.controlCommand() and e.evt.key.code == .c and e.evt.key.action == .down) {
        e.handled = true;
        self.copy();
    }

    if (e.bubbleable()) {
        self.wd.parent.processEvent(e, true);
    }
}

// must be called before addText()
pub fn copy(self: *TextLayoutWidget) void {
    self.copy_sel = self.selection.*;
}

pub fn deinit(self: *TextLayoutWidget) void {
    if (!self.add_text_done) {
        self.addTextDone(.{}) catch |err| {
            dvui.log.err("TextLayoutWidget.deinit addTextDone got {!}\n", .{err});
        };
    }
    dvui.dataSet(null, self.wd.id, "_touch_editing", self.touch_editing);
    dvui.dataSet(null, self.wd.id, "_te_first", self.te_first);
    dvui.dataSet(null, self.wd.id, "_te_show_draggables", self.te_show_draggables);
    dvui.dataSet(null, self.wd.id, "_te_show_context_menu", self.te_show_context_menu);
    dvui.dataSet(null, self.wd.id, "_te_focus_on_touchdown", self.te_focus_on_touchdown);
    dvui.dataSet(null, self.wd.id, "_sel_start_r", self.sel_start_r);
    dvui.dataSet(null, self.wd.id, "_sel_end_r", self.sel_end_r);
    dvui.dataSet(null, self.wd.id, "_selection", self.selection.*);

    if (dvui.captured(self.wd.id) and self.sel_mouse_down_bytes != null) {
        // once we figure out where the mousedown was, we need to save it
        // as long as we are dragging
        dvui.dataSet(null, self.wd.id, "_sel_mouse_down_bytes", self.sel_mouse_down_bytes.?);
    }
    if (self.click_num == 0) {
        dvui.dataRemove(null, self.wd.id, "_click_num");
    } else {
        dvui.dataSet(null, self.wd.id, "_click_num", self.click_num);
    }
    dvui.clipSet(self.prevClip);

    // check if the widgets are taller than the text
    const left_height = (self.corners_min_size[0] orelse Size{}).h + (self.corners_min_size[2] orelse Size{}).h;
    const right_height = (self.corners_min_size[1] orelse Size{}).h + (self.corners_min_size[3] orelse Size{}).h;
    self.wd.min_size.h = @max(self.wd.min_size.h, self.wd.padSize(.{ .h = @max(left_height, right_height) }).h);

    self.wd.minSizeSetAndRefresh();
    self.wd.minSizeReportToParent();
    dvui.parentReset(self.wd.id, self.wd.parent);
}
