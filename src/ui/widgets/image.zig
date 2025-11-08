const std = @import("std");
const eng = @import("self");
const Imui = eng.ui;
const gfx = eng.gfx;

pub fn create(imui: *Imui, texture_view: gfx.TextureView2D, sampler: gfx.Sampler, key: anytype) Imui.WidgetSignal(Imui.WidgetId) {
    var image_widget = Imui.Widget {
        .key = Imui.gen_key(key ++ .{@src()}),
        .semantic_size = [2]Imui.SemanticSize{
            Imui.SemanticSize{ .kind = .Pixels, .value = 100.0, .shrinkable_percent = 0.0, },
            Imui.SemanticSize{ .kind = .Pixels, .value = 100.0, .shrinkable_percent = 0.0, },
        },
        .texture =  .{
            .texture_view = texture_view,
            .sampler = sampler,
        },
        .flags = .{
            .render = true,
        },
    };

    // set size based on parent layout. Fill parent layout axis and keep image aspect ratio.
    if (imui.get_widget_from_last_frame(imui.parent_stack.getLast())) |parent| {
        if (texture_view.desc.width != 0 and texture_view.desc.height != 0) {
            const aspect_ratio = @as(f32, @floatFromInt(texture_view.desc.width)) / @as(f32, @floatFromInt(texture_view.desc.height));
            if (parent.layout_axis) |layout_axis| {
                switch (layout_axis) {
                    .X => {
                        image_widget.semantic_size[0].kind = .Pixels;
                        image_widget.semantic_size[0].value = @as(f32, @floatFromInt(parent.content_rect().height)) * aspect_ratio;
                        image_widget.semantic_size[1].kind = .ParentPercentage;
                        image_widget.semantic_size[1].value = 1.0;
                    },
                    .Y => {
                        image_widget.semantic_size[0].kind = .ParentPercentage;
                        image_widget.semantic_size[0].value = 1.0;
                        image_widget.semantic_size[1].kind = .Pixels;
                        image_widget.semantic_size[1].value = @as(f32, @floatFromInt(parent.content_rect().width)) / aspect_ratio;
                    },
                }
            }
        }
    }

    const image_widget_id = imui.add_widget(image_widget, .{});
    return imui.generate_widget_signals(image_widget_id);
}
