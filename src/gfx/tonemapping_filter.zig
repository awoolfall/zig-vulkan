const Self = @This();

const std = @import("std");
const eng = @import("../root.zig");
const gf = eng.gfx;
const bloom = @import("bloom.zig");

const HLSL = //
\\  Texture2D hdr_buffer;
\\  Texture2D bloom_buffer;
\\  SamplerState hdr_sampler;
\\
\\  [shader("pixel")]
\\  float4 ps_main(vs_out input) : SV_TARGET
\\  {
\\      float3 hdr_colour = hdr_buffer.Sample(hdr_sampler, input.uv).rgb;
\\      float3 bloom_colour = bloom_buffer.Sample(hdr_sampler, input.uv).rgb;
\\      float3 mixed_colour = lerp(hdr_colour, bloom_colour, 0.04);
\\      
\\      // ACES tonemapping
\\      float3 c = mixed_colour;
\\      float3 mapped_aces = (c*(2.51*c+0.03))/(c*(2.43*c+0.59)+0.14);
\\      float4 toned_colour = float4(saturate(mapped_aces), 1.0);
\\
\\ #ifdef BLACK_AND_WHITE
\\      // gamma correct and convert to grayscale
\\      toned_colour = pow(toned_colour, float4(1.0 / 2.2, 1.0 / 2.2, 1.0 / 2.2, 1.0));
\\      float value = toned_colour.r * 0.299 + toned_colour.g * 0.587 + toned_colour.b * 0.114;
\\      value = saturate(value);
\\      toned_colour = float4(value, value, value, 1.0);
\\
\\      // return to linear space
\\      toned_colour = pow(toned_colour, float4(2.2, 2.2, 2.2, 1.0));
\\ #endif
\\
\\      return toned_colour;
\\  }
;

pub const ToneMappingOptions = packed struct(u32) {
    black_and_white: bool = false,
    __padding: u31 = 0,
};

vertex_shader: gf.VertexShader,
pixel_shader: gf.PixelShader,
black_and_white_pixel_shader: gf.PixelShader,
sampler: gf.Sampler.Ref,

    bloom_filter: bloom.BloomFilter,

    pub fn deinit(self: *Self) void {
        self.bloom_filter.deinit();
        self.vertex_shader.deinit();
        self.pixel_shader.deinit();
        self.black_and_white_pixel_shader.deinit();
        self.sampler.deinit();
    }

pub fn init() !Self {
    var vertex_shader = try gf.VertexShader.init_buffer(
        gf.GfxState.FULL_SCREEN_QUAD_VS,
        "vs_main",
        ([0]gf.VertexInputLayoutEntry {})[0..],
        .{},
    );
    errdefer vertex_shader.deinit();

    var pixel_shader = try gf.PixelShader.init_buffer(
        gf.GfxState.FULL_SCREEN_QUAD_VS ++ HLSL,
        "ps_main",
        .{},
    );
    errdefer pixel_shader.deinit();

    var black_and_white_pixel_shader = try gf.PixelShader.init_buffer(
        gf.GfxState.FULL_SCREEN_QUAD_VS ++ HLSL,
        "ps_main",
        .{
            .defines = &.{
                .{ "BLACK_AND_WHITE", "1" },
            },
        },
    );
    errdefer black_and_white_pixel_shader.deinit();

    var sampler = try gf.Sampler.init(.{});
    errdefer sampler.deinit();

    var bloom_filter = try bloom.BloomFilter.init();
    errdefer bloom_filter.deinit();

    return Self {
        .vertex_shader = vertex_shader,
        .pixel_shader = pixel_shader,
        .black_and_white_pixel_shader = black_and_white_pixel_shader,
        .sampler = sampler,
        .bloom_filter = bloom_filter,
    };
}

pub fn apply_filter(
    self: *Self,
    hdr_buffer: gf.ImageView.Ref,
    options: ToneMappingOptions,
    rtv: gf.ImageView.Ref,
) void {
    const gfx = gf.GfxState.get();

    self.bloom_filter.render_bloom_texture(hdr_buffer, 0.005);

    const view = rtv.get() catch unreachable;
    const viewport = gf.Viewport {
        .width = @floatFromInt(view.size.width),
        .height = @floatFromInt(view.size.height),
        .top_left_x = 0,
        .top_left_y = 0,
        .min_depth = 0,
        .max_depth = 0,
    };

    gfx.cmd_set_render_target(&.{rtv}, null);

    gfx.cmd_set_viewport(viewport);
    gfx.cmd_set_rasterizer_state(.{ .FillBack = false, .FrontCounterClockwise = true, });

    gfx.cmd_set_vertex_shader(&self.vertex_shader);

    if (options.black_and_white) {
        gfx.cmd_set_pixel_shader(&self.black_and_white_pixel_shader);
    } else {
        gfx.cmd_set_pixel_shader(&self.pixel_shader);
    }
    gfx.cmd_set_samplers(.Pixel, 0, &.{self.sampler});
    gfx.cmd_set_shader_resources(.Pixel, 0, &.{hdr_buffer, self.bloom_filter.get_bloom_view()});

    gfx.cmd_set_topology(.TriangleList);

    gfx.cmd_draw(6, 0);

    // unset hdr texture so it can be used as rtv again
    gfx.cmd_set_shader_resources(.Pixel, 0, &.{null, null});
}

pub fn framebuffer_resized(self: *Self) !void {
    try self.bloom_filter.framebuffer_resized();
}
