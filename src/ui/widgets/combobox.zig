const std = @import("std");
const eng = @import("self");
const Imui = eng.ui;
const KeyCode = eng.input.KeyCode;
const label = @import("label.zig");

pub const ComboBoxState = struct {
    default_text: []u8,
    can_be_default: bool = true,
    options: std.ArrayList([]u8),
    selected_index: ?usize = null,
    dropdown_is_open: bool = false,

    pub fn deinit(self: *ComboBoxState, alloc: std.mem.Allocator) void {
        if (self.default_text.len > 0) {
            alloc.free(self.default_text);
        }

        for (self.options.items) |o| {
            alloc.free(o);
        }
        self.options.deinit(alloc);
    }

    pub fn init(alloc: std.mem.Allocator) !ComboBoxState {
        _ = alloc;
        return ComboBoxState {
            .default_text = "",
            .options = std.ArrayList([]u8).empty,
        };
    }

    pub fn clone(self: *ComboBoxState, alloc: std.mem.Allocator) !ComboBoxState {
        var state = ComboBoxState {
            .default_text = undefined,
            .can_be_default = self.can_be_default,
            .options = undefined,
            .selected_index = self.selected_index,
            .dropdown_is_open = self.dropdown_is_open,
        };

        state.default_text = if (self.default_text.len > 0) try alloc.dupe(u8, self.default_text) else "";
        errdefer if (state.default_text.len > 0) { alloc.free(state.default_text); };

        state.options = try std.ArrayList([]u8).initCapacity(alloc, self.options.items.len);
        errdefer state.options.deinit(alloc);
        errdefer for (state.options.items) |opt| { alloc.free(opt); };

        for (self.options.items) |opt| {
            const new_option_text = try alloc.dupe(u8, opt);
            errdefer alloc.free(new_option_text);

            try state.options.append(alloc, new_option_text);
        }

        return state;
    }

    pub fn append_option(self: *ComboBoxState, alloc: std.mem.Allocator, option: []const u8) !void {
        const owned_option = try alloc.dupe(u8, option);
        errdefer alloc.free(owned_option);

        try self.options.append(alloc, owned_option);
    }
};

fn set_combobox_background_layout(widget: *Imui.Widget) void {
    widget.semantic_size[0] = .{
        .kind = .ParentPercentage, .value = 1.0, .shrinkable_percent = 0.0,
    };
    widget.flags.render = true;
    widget.border_width_px = .all(1);
    widget.padding_px = .all(4);
    widget.children_gap = 2;
    widget.corner_radii_px = .all(4);
}

pub fn create(imui: *Imui, key: anytype) Imui.WidgetSignal(Imui.WidgetId) {
    // push the container layout
    const container_layout = imui.push_layout(.Y, key ++ .{@src()});
    const container_signals = imui.generate_widget_signals(container_layout);
    if (imui.get_widget(container_layout)) |container_widget| {
        container_widget.semantic_size[0] = .{
            .kind = .ParentPercentage, .value = 1.0, .shrinkable_percent = 1.0,
        };
    }

    const data, _ = imui.get_widget_data(ComboBoxState, container_layout) catch |err| {
        std.log.err("Unable to get combobox state: {}", .{err});
        unreachable;
    };

    // ensure data elements are valid
    if (data.selected_index) |*si| { si.* = @min(si.*, data.options.items.len - 1); }
    if (!data.can_be_default and data.selected_index == null) { data.selected_index = 0; }
    
    // push the background layout of the primary combobox
    const background = imui.push_layout(.X, key ++ .{@src()});
    if (imui.get_widget(background)) |background_widget| {
        set_combobox_background_layout(background_widget);
        background_widget.flags.clickable = true;
    }

    // check wether the combo box was clicked on, record this
    // so we dont immediately close dropdown options
    var clicked_on_widget: bool = false;
    const background_s = imui.generate_widget_signals(background);
    if (background_s.clicked) {
        data.dropdown_is_open = !data.dropdown_is_open;
        clicked_on_widget = true;
    }

    // print the selected label
    {
        const label_layout = imui.push_layout(.X, key ++ .{@src()});
        defer imui.pop_layout();

        if (imui.get_widget(label_layout)) |label_widget| {
            label_widget.layout_axis = null;
            label_widget.semantic_size[0] = .{
                .kind = .ParentPercentage, .value = 1.0, .shrinkable_percent = 0.0,
            };
        }

        const selected_label = if (data.selected_index) |si| data.options.items[si] else data.default_text;
        _ = label.create(imui, selected_label);
        const arrow_label = label.create(imui, "▽");
        if (imui.get_widget(arrow_label.id)) |arrow_label_widget| {
            arrow_label_widget.anchor = .{1.0, 0.5};
            arrow_label_widget.pivot = .{1.0, 0.5};
        }
    }
    imui.pop_layout(); // background layout

    var new_option_selected = false;

    // if the dropdown should be shown then render it
    dropdown_is_open: { if (data.dropdown_is_open) {
        // determine the position of the dropdown options based on the primary combobox rect
        const dropdown_pos = if (imui.get_widget_from_last_frame(background)) |b| 
            .{ b.computed.rect().left, b.computed.rect().bottom + 4 }
            else break :dropdown_is_open;

        // push the options background layout
        const options_background = imui.push_priority_floating_layout(.Y, dropdown_pos[0], dropdown_pos[1], key ++ .{@src()});
        if (imui.get_widget(options_background)) |options_background_widget| {
            set_combobox_background_layout(options_background_widget);
            options_background_widget.semantic_size[0] = .{
                .kind = .ParentPercentage, .value = 1.0, .shrinkable_percent = 0.0,
            };
        }

        // push each of the options into the dropdown menu
        for (data.options.items, 0..) |option, i| {
            const option_background = imui.push_layout(.X, key ++ .{@src(), i});
            defer imui.pop_layout();

            // give the option a hover effect
            if (imui.get_widget(option_background)) |option_background_widget| {
                option_background_widget.semantic_size[0] = .{
                    .kind = .ParentPercentage, .value = 1.0, .shrinkable_percent = 0.0,
                };
                option_background_widget.flags.clickable = true;
                option_background_widget.flags.render = true;
                option_background_widget.padding_px = .all(4);
                option_background_widget.corner_radii_px = .all(4);
            }

            // if the option is clicked then set the data selected index
            if (imui.generate_widget_signals(option_background).clicked) {
                if (data.selected_index == i) {
                    if (data.can_be_default) {
                        data.selected_index = null;
                    }
                } else {
                    data.selected_index = i;
                }
                new_option_selected = true;
            }
            
            // print the option label with a selected indicator
            if (data.selected_index) |si| {
                if (i == si) {
                    _ = label.create(imui, "▶ ");
                }
            }
            _ = label.create(imui, option);
        }

        imui.pop_layout(); // options background layout
    } }

    imui.pop_layout(); // container layout

    // close the dropdown if the mouse is clicked anywhere
    // unless the primary combobox was clicked
    if (!clicked_on_widget and eng.get().input.get_key_down(KeyCode.MouseLeft)) {
        data.dropdown_is_open = false;
    }

    return Imui.WidgetSignal(Imui.WidgetId) {
        .id = container_layout,
        .init = container_signals.init,
        .data_changed = new_option_selected,
        .hover = false, // TODO
        .clicked = false, // TODO
        .dragged = false, // TODO
    };
}
