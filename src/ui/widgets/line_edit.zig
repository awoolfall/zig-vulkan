const std = @import("std");
const eng = @import("self");
const Imui = eng.ui;
const zm = eng.zmath;
const KeyCode = eng.input.KeyCode;

pub const TextInputState = struct {
    cursor: usize = 0,
    mark: usize = 0,
    text: std.ArrayList(u8),

    pub fn deinit(self: *TextInputState, alloc: std.mem.Allocator) void {
        self.text.deinit(alloc);
    }

    pub fn init(alloc: std.mem.Allocator) !TextInputState {
        _ = alloc;
        return TextInputState {
            .text = std.ArrayList(u8).empty,
        };
    }

    pub fn clone(self: *TextInputState, alloc: std.mem.Allocator) !TextInputState {
        var state = TextInputState {
            .cursor = self.cursor,
            .mark = self.mark,
            .text = try std.ArrayList(u8).initCapacity(alloc, self.text.items.len),
        };
        try state.text.appendSlice(alloc, self.text.items);
        return state;
    }
};

pub const TextInputId = struct {
    box: Imui.WidgetId,
    text: Imui.WidgetId,
};

fn character_advance_at_cursor(font: *const Imui.font.Font, text_input_widget: *const Imui.Widget, text_input_state: *const TextInputState) f32 {
    if (text_input_state.cursor == 0) { return 0; }
    return 
        font.character_map.get(text_input_state.text.items[text_input_state.cursor - @intFromBool(text_input_state.cursor > 0)]).?.advance *  // TODO handle error
        text_input_widget.text_content.?.size;
}

pub const LineEditCharacterSet = enum {
    AllowAll,
    RealNumber,
    IntegerNumber,
};

pub const LineEditOptions = struct {
    allowed_character_set: LineEditCharacterSet = .AllowAll,
};

pub fn create(imui: *Imui, options: LineEditOptions, key: anytype) Imui.WidgetSignal(TextInputId) {
    const input = &eng.get().input;

    const font_to_use = Imui.FontEnum.GeistMono;

    // Background box, stack children
    const l = imui.push_layout(.X, key ++ .{@src()});
    if (imui.get_widget(l)) |lw| {
        lw.flags.render = true;
        lw.flags.clickable = true;
        lw.flags.hover_effect = false;
        lw.semantic_size[0].kind = .ParentPercentage;
        lw.semantic_size[0].value = 1.0;
        lw.semantic_size[0].shrinkable = true;
        lw.semantic_size[1].kind = .Pixels;
        lw.semantic_size[1].value = 16.0;
        lw.background_colour = imui.palette().secondary;
        lw.border_colour = imui.palette().border;
        lw.border_width_px = .all(1);
        lw.padding_px = .all(4);
        lw.corner_radii_px = .all(4);
    }
    const state, _ = imui.get_widget_data(TextInputState, l) catch |err| {
        std.log.err("Unable to get widget data: {}", .{err});
        unreachable;
    };

    const content_box = imui.push_layout(.X, key ++ .{@src()});
    if (imui.get_widget(content_box)) |content_box_widget| {
        content_box_widget.layout_axis = null;

        content_box_widget.semantic_size[0].kind = .ParentPercentage;
        content_box_widget.semantic_size[0].value = 1.0;
        content_box_widget.semantic_size[1].kind = .ParentPercentage;
        content_box_widget.semantic_size[1].value = 1.0;
    }

    // Text to render
    const text_input_widget = Imui.Widget {
        .key = Imui.gen_key(key ++ .{@src()}),
        .semantic_size = [2]Imui.SemanticSize{
            Imui.SemanticSize{ .kind = .TextContent, .value = 1.0, .shrinkable = false, },
            Imui.SemanticSize{ .kind = .TextContent, .value = 1.0, .shrinkable = false, },
        },
        .text_content = .{
            .font = font_to_use,
            .text = state.text.items,
        },
        .flags = .{
            .clickable = true,
        },
    };
    const text_input_widget_id = imui.add_widget(text_input_widget, .{});

    // ensure data is in a valid state
    state.cursor = @min(state.cursor, state.text.items.len);
    state.mark = @min(state.mark, state.text.items.len);

    // Generate signals
    const box_signals = imui.generate_widget_signals(l);
    const text_signals = imui.generate_widget_signals(text_input_widget_id);

    const line_edit_is_focus_widget = imui.any_of_widgets_is_focus(&.{ 
        imui.get_widget(box_signals.id).?.key, 
        imui.get_widget(text_signals.id).?.key
    });

    var l_sel = @min(state.cursor, state.mark);
    const r_sel = @max(state.cursor, state.mark);
    const f = imui.get_font(text_input_widget.text_content.?.font);

    // Cursor (and selection box)
    // Push invisible spacer box to until start of selection
    _ = imui.push_layout(.X, key ++ .{@src()});
    var phantom_text = text_input_widget;
    phantom_text.key = Imui.gen_key(key ++ .{@src()});
    phantom_text.flags.render = false;
    phantom_text.text_content.?.text = state.text.items[0..l_sel];
    _ = imui.add_widget(phantom_text, .{});

    // render cursor and selection box
    const selection_bounds = f.text_bounds_2d_pixels(
        state.text.items[l_sel..r_sel],
        text_input_widget.text_content.?.size
    );
    const cursor_min_width = 1.5;
    const cursor = Imui.Widget {
        .key = Imui.gen_key(key ++ .{@src()}),
        .semantic_size = [2]Imui.SemanticSize{
            Imui.SemanticSize{ .kind = .Pixels, .value = selection_bounds.width() + cursor_min_width, .shrinkable = false, },
            Imui.SemanticSize{ .kind = .Pixels, .value = selection_bounds.height(), .shrinkable = false, },
        },
        .margin_px = .{ .left = -(cursor_min_width / 2.0), },
        .background_colour = imui.palette().primary * zm.f32x4(1.0, 1.0, 1.0, 0.4 + 0.4 * 
            (std.math.sin(2.0 * std.math.pi * @as(f32, @floatFromInt(@mod(std.time.milliTimestamp(), 1000))) / @as(f32, @floatFromInt(std.time.ms_per_s))) + 1.0) * 0.5),
        .flags = .{
            .render = (line_edit_is_focus_widget or state.cursor != state.mark),
        },
    };
    _ = imui.add_widget(cursor, .{});
    imui.pop_layout(); // phantom and cursor

    imui.pop_layout(); // content box
    imui.pop_layout(); // background box

    var data_has_changed = false;

    // Handle mouse input, click and drag
    if (box_signals.dragged or text_signals.dragged or box_signals.clicked or text_signals.clicked) {
        const cursor_pos = [2]f32{
            @floatFromInt(input.cursor_position[0]), 
            @floatFromInt(input.cursor_position[1])
        };
        const text_rel_pos = imui.get_widget_from_last_frame(text_input_widget_id).?.computed_relative_position;
        const cursor_in_box_pos = [2]f32 {
            cursor_pos[0] - text_rel_pos[0],
            cursor_pos[1] - text_rel_pos[1]
        };

        // Set cursor to closest character to mouse position
        // by shifting state cursor back and forth
        while (f.text_bounds_2d_pixels(
            state.text.items[0..state.cursor],
            text_input_widget.text_content.?.size
        ).width() - (character_advance_at_cursor(imui.get_font(Imui.FontEnum.Geist), &text_input_widget, state) / 2.0) < cursor_in_box_pos[0]) {
            if (state.cursor == state.text.items.len) {
                break;
            }
            state.cursor += 1;
        }
        while (imui.get_font(text_input_widget.text_content.?.font).text_bounds_2d_pixels(
            state.text.items[0..state.cursor],
            text_input_widget.text_content.?.size
        ).width() - @divTrunc(character_advance_at_cursor(imui.get_font(Imui.FontEnum.Geist), &text_input_widget, state), 2) > cursor_in_box_pos[0]) {
            if (state.cursor == 0) {
                break;
            }
            state.cursor -= 1;
        }
    }
    // if clicked then we set mark to equal cursor instead of manipulating selection
    if (box_signals.clicked or text_signals.clicked) {
        state.mark = state.cursor;
    }

    // Handle keyboard input if focused
    if (line_edit_is_focus_widget) {
        for (input.char_events) |c| {
            if (c != null) {
                switch (c.?[0]) {
                    // Backspace (word or character)
                    8, 127 => {
                        data_has_changed = true;
                        if (state.text.items.len > 0) {
                            if (l_sel == r_sel) {
                                if (c.?[0] == 127) {
                                    // word backspace
                                    l_sel = std.mem.lastIndexOfAny(u8, state.text.items[0..(r_sel-1)], "\n\t ") orelse 0;
                                    if (l_sel != 0) {
                                        l_sel = @min(l_sel + 1, state.text.items.len);
                                    }
                                } else {
                                    // single char backspace
                                    if (l_sel != 0) { l_sel -= 1; }
                                }
                            }
                            for (l_sel..r_sel) |_| {
                                _ = state.text.orderedRemove(l_sel);
                            }
                            state.cursor = l_sel;
                            state.mark = state.cursor;
                        }
                    },
                    // Enter
                    13 => {
                        // single line input so ignore newline
                        // state.text.append('\n') catch {};
                    },
                    // Characters
                    32...126 => {
                        switch (options.allowed_character_set) {
                            .AllowAll => {},
                            .IntegerNumber => {
                                if (!std.ascii.isDigit(c.?[0])) {
                                    continue;
                                }
                            },
                            .RealNumber => {
                                if (!std.ascii.isDigit(c.?[0]) and c.?[0] != '.') {
                                    continue;
                                }
                                if (c.?[0] == '.') {
                                    if (std.mem.indexOfScalar(u8, state.text.items, '.') != null) {
                                        continue;
                                    }
                                }
                            },
                        }
                        data_has_changed = true;
                        if (c.?[1] == 0) {
                            state.text.insert(imui.widget_allocator(), state.cursor, c.?[0]) catch {};
                            state.cursor += 1;
                            state.mark = state.cursor;
                        } else {
                            state.text.insertSlice(imui.widget_allocator(), state.cursor, c.?[0..2]) catch {};
                            state.cursor += 2;
                            state.mark = state.cursor;
                        }
                    },
                    else => {},
                }
            }
        }

        // Remove selection and clear focus if escape pressed
        if (input.get_key_down(KeyCode.Escape)) {
            state.mark = state.cursor;
            imui.clear_focus_item();
        }

        // Handle arrow keys
        if (input.get_key_down_repeat(KeyCode.ArrowLeft)) {
            if (state.cursor > 0) {
                state.cursor = state.cursor - 1;
            }
            if (!input.get_key(KeyCode.Shift)) {
                state.cursor = @min(state.cursor, state.mark);
                state.mark = state.cursor;
            }
        }
        if (input.get_key_down_repeat(KeyCode.ArrowRight)) {
            if (state.cursor < state.text.items.len) {
                state.cursor = state.cursor + 1;
            }
            if (!input.get_key(KeyCode.Shift)) {
                state.cursor = @max(state.cursor, state.mark);
                state.mark = state.cursor;
            }
        }

        // Handle copy
        if (input.get_key_down(KeyCode.C) and input.get_key(KeyCode.Control)) {
            if (state.cursor != state.mark) {
                eng.get().window.copy_string_to_clipboard(state.text.items[@min(state.mark, state.cursor)..@max(state.mark, state.cursor)])
                    catch |err| std.log.err("Failed to copy string to clipboard: {}", .{err});
            }
        }
        // Handle paste
        if (input.get_key_down(KeyCode.V) and input.get_key(KeyCode.Control)) {
            if (eng.get().window.get_string_from_clipboard(std.heap.page_allocator)) |clipboard_str| {
                defer std.heap.page_allocator.free(clipboard_str);

                // sanitize incoming clipboard string
                var sanitized = std.heap.page_allocator.dupe(u8, clipboard_str) catch unreachable;
                defer std.heap.page_allocator.free(sanitized);

                var sanitized_cursor: usize = 0;
                for (clipboard_str) |c| {
                    // only allow ascii printable characters
                    if (c >= 32 and c < 127) {
                        sanitized[sanitized_cursor] = c;
                        sanitized_cursor += 1;
                    }
                }

                std.log.info("clipboard string: {s}", .{clipboard_str});
                std.log.info("sanitized string: {s}", .{sanitized});

                // insert sanitized string into text input
                state.text.insertSlice(imui.alloc, state.cursor, sanitized[0..sanitized_cursor]) catch {};
                data_has_changed = true;
                state.cursor += sanitized_cursor;
                state.mark = state.cursor;
            } else |err| {
                std.log.err("Failed to get clipboard string {}", .{err});
            }
        }
    }

    // Handle text overflow
    // TODO: SPEED: only do this if data or cursor has changed in the line edit
    blk: {
        const background_widget = imui.get_widget_from_last_frame(l) orelse break :blk;
        const content_box_widget = imui.get_widget(content_box) orelse break :blk;
        const text_widget = imui.get_widget_from_last_frame(text_input_widget_id) orelse break :blk;

        // apply same pixel offset as last frame
        if (imui.get_widget_from_last_frame(content_box)) |lfw| {
            content_box_widget.margin_px = .{ .left = lfw.margin_px.left, };
        }

        // find the cursor position in pixels
        // TODO: SPEED: iterate throgh text a little less
        const cursor_pixel_position = f.text_bounds_2d_pixels(
                    state.text.items[0..state.cursor],
                    text_input_widget.text_content.?.size
        ).width() + text_widget.rect().left + cursor_min_width;

        const background_content = background_widget.content_rect();
        const background_left = background_content.left;
        const background_right = background_content.right;

        const cursor_right: f32 = cursor_pixel_position;
        // shift content box to the left if the cursor is to the left of the background
        if (cursor_right < background_left) {
            content_box_widget.margin_px.left -= cursor_right - background_left;
        }
        // shift content box to the right if the cursor is to the right of the background
        if (cursor_right > background_right) {
            content_box_widget.margin_px.left -= (cursor_right - background_right);
        }

        // clamp so that the last character is always at the right edge of the background 
        // if text is long enough to exceed the background
        const text_width = text_widget.rect().width() + cursor_min_width;
        const offset_min = @min(-(text_width - background_content.width()), 0.0);
        content_box_widget.margin_px.left = std.math.clamp(content_box_widget.margin_px.left, offset_min, 0.0);
    }

    var signals = Imui.combine_signals(
        .{
            box_signals,
            text_signals,
        },
        TextInputId{ .text = text_input_widget_id, .box = l, }
    );
    signals.data_changed = data_has_changed;
    return signals;
}
