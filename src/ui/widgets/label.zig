const std = @import("std");
const eng = @import("self");
const Imui = eng.ui;

pub fn create(self: *Imui, text: []const u8) Imui.WidgetSignal(Imui.WidgetId) {
    const widget = Imui.Widget {
        .key = Imui.LabelKey,
        .semantic_size = [2]Imui.SemanticSize{
            Imui.SemanticSize{ .kind = .TextContent, .value = 0.0, .shrinkable_percent = 0.0, },
            Imui.SemanticSize{ .kind = .TextContent, .value = 0.0, .shrinkable_percent = 0.0, },
        },
        .flags = .{
            .render_quad = false,
        },
        .text_content = .{
            .font = .Geist,
            .text = text,
        },
        .anchor = .{ 0.0, 0.5 },
        .pivot = .{ 0.0, 0.5 },
    };

    const widget_id = self.add_widget(widget, .{});
    return self.generate_widget_signals(widget_id);
}
