const std = @import("std");
const zstbi = @import("zstbi");
const _gfx = @import("../gfx/gfx.zig");
const zm = @import("zmath");
const ui = @import("ui.zig");
const path = @import("../engine/path.zig");

pub const AtlasDetails = struct {
    distance_range: f32,
    size: f32,
    width: i32,
    height: i32,
};

pub const FontMetrics = struct {
    em_size: f32,
    line_height: f32,
    ascender: f32,
    descender: f32,
    underline_y: f32,
    underline_thickness: f32,
};

pub const Bounds = extern struct {
    left: f32 = 0.0,
    bottom: f32 = 0.0,
    right: f32 = 0.0,
    top: f32 = 0.0,
};

pub const CharacterInfo = struct {
    advance: f32,
    plane_bounds: Bounds,
    atlas_bounds: Bounds,
};

const FontConstantBuffer = extern struct {
    msdf_unit_range: zm.F32x4,
    fg_colour: zm.F32x4,
    bg_colour: zm.F32x4,
};

const CharacterInfoConstantBuffer = extern struct {
    quad_bounds: Bounds,
    atlas_bounds: Bounds,
};

const MSDF_FONT_SHADER_HLSL = @embedFile("font_shader.hlsl");

pub const Font = struct {
    const RENDER_INSTANCE_COUNT: u32 = 1024;

    _allocator: std.mem.Allocator,
    atlas_details: AtlasDetails,
    font_metrics: FontMetrics,
    ascii_character_map: [256]CharacterInfo,

    msdf_texture_view: _gfx.TextureView2D,
    font_vso: _gfx.VertexShader,
    font_pso: _gfx.PixelShader,
    sampler: _gfx.Sampler,
    blend_state: _gfx.BlendState,
    character_buffer: _gfx.Buffer,
    font_text_buffer: _gfx.Buffer,

    pub fn deinit(self: *const Font) void {
        self.msdf_texture_view.deinit();
        self.font_vso.deinit();
        self.font_pso.deinit();
        self.sampler.deinit();
        self.blend_state.deinit();
        self.character_buffer.deinit();
        self.font_text_buffer.deinit();
    }

    pub fn init(alloc: std.mem.Allocator, font_json: path.Path, font_msdf_png: path.Path, gfx: *_gfx.GfxState) !Font {
        const font_json_path = try font_json.resolve_path(alloc);
        defer alloc.free(font_json_path);

        // find font json file size
        var font_json_file_size: u64 = undefined;
        {
            const font_json_file = try std.fs.cwd().openFile(font_json_path, .{});
            defer font_json_file.close();

            font_json_file_size = try font_json_file.getEndPos();
        }

        // read json file into memory
        const font_json_data = try std.fs.cwd().readFileAlloc(alloc, font_json_path, @intCast(font_json_file_size));
        defer alloc.free(font_json_data);

        const FontJson = struct {
            atlas: struct {
                distanceRange: f32,
                size: f32,
                width: i32,
                height: i32,
            },
            metrics: struct {
                emSize: f32,
                lineHeight: f32,
                ascender: f32,
                descender: f32,
                underlineY: f32,
                underlineThickness: f32,
            },
            glyphs: []struct {
                unicode: i32,
                advance: f32,
                planeBounds: Bounds = .{},
                atlasBounds: Bounds = .{},
            },
            kerning: []struct {},
        };

        // deserialize font json
        const font_data = try std.json.parseFromSlice(FontJson, alloc, font_json_data, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always
        });
        defer font_data.deinit();

        // construct font object
        var font = Font {
            ._allocator = alloc,
            .msdf_texture_view = undefined,
            .font_vso = undefined,
            .font_pso = undefined,
            .sampler = undefined,
            .blend_state = undefined,
            .font_text_buffer = undefined,
            .character_buffer = undefined,
            .atlas_details = AtlasDetails {
                .distance_range = font_data.value.atlas.distanceRange,
                .size = font_data.value.atlas.size,
                .width = font_data.value.atlas.width,
                .height = font_data.value.atlas.height,
            },
            .font_metrics = FontMetrics {
                .em_size = font_data.value.metrics.emSize,
                .line_height = font_data.value.metrics.lineHeight,
                .ascender = font_data.value.metrics.ascender,
                .descender = -font_data.value.metrics.descender,
                .underline_y = font_data.value.metrics.underlineY,
                .underline_thickness = font_data.value.metrics.underlineThickness,
            },
            .ascii_character_map = [_]CharacterInfo{.{
                .advance=0.0, 
                .plane_bounds=.{}, 
                .atlas_bounds=.{}
            }} ** 256,
        };

        const msdf_width: f32 = @floatFromInt(font.atlas_details.width);
        const msdf_height: f32 = @floatFromInt(font.atlas_details.height);

        // fill font character info array with data from font json
        var glyph_idx: usize = 0;
        for (0..256) |i| {
            const glyph = &font_data.value.glyphs[glyph_idx];
            if (glyph.unicode > i) {continue;}
            if (glyph.unicode < i) {return error.FailedToReadGlyphsInOrder;}

            font.ascii_character_map[i] = CharacterInfo {
                .advance = glyph.advance,
                .plane_bounds = glyph.planeBounds,
                .atlas_bounds = Bounds {
                    .left = (glyph.atlasBounds.left / msdf_width),
                    .right = (glyph.atlasBounds.right / msdf_width),
                    .top = 1.0 - (glyph.atlasBounds.top / msdf_height),
                    .bottom = 1.0 - (glyph.atlasBounds.bottom / msdf_height),
                },
            };

            glyph_idx += 1;
            if (glyph_idx >= font_data.value.glyphs.len) {break;}
        }

        // load msdf font png file
        const font_png_path = try font_msdf_png.resolve_path_c_str(alloc);
        defer alloc.free(font_png_path);

        var font_image = try zstbi.Image.loadFromFile(font_png_path, 4);
        defer font_image.deinit();

        // create a d3d11 texture from the font png file
        var msdf_texture = try _gfx.Texture2D.init(
            .{
                .width = @intCast(font.atlas_details.width),
                .height = @intCast(font.atlas_details.height),
                .format = .Rgba8_Unorm,
            },
            .{ .ShaderResource = true, },
            .{},
            font_image.data,
            gfx
        );
        defer msdf_texture.deinit();

        font.msdf_texture_view = try _gfx.TextureView2D.init_from_texture2d(&msdf_texture, gfx);
        errdefer font.msdf_texture_view.deinit();

        // create the font shaders
        // @TODO move font shader to a common location, not in each font file
        font.font_vso = try _gfx.VertexShader.init_buffer(
            MSDF_FONT_SHADER_HLSL,
            "vs_main",
            ([_]_gfx.VertexInputLayoutEntry {
                .{ .name = "TEXCOORD", .index = 0, .format = .F32x4, .per = .Instance, },
                .{ .name = "TEXCOORD", .index = 1, .format = .F32x4, .per = .Instance, },
            })[0..],
            gfx
        );
        errdefer font.font_vso.deinit();

        font.font_pso = try _gfx.PixelShader.init_buffer(
            MSDF_FONT_SHADER_HLSL,
            "ps_main",
            gfx
        );
        errdefer font.font_pso.deinit();

        // create sampler
        font.sampler = try _gfx.Sampler.init(
            .{
                .filter_min_mag = .Linear,
                .filter_mip = .Point,
                .border_mode = .Wrap,
            },
            gfx
        );
        errdefer font.sampler.deinit();

        // create blend state
        font.blend_state = try _gfx.BlendState.init(
            ([_]_gfx.BlendType { .Simple })[0..],
            gfx
        );
        errdefer font.blend_state.deinit();

        // create constant buffers
        font.font_text_buffer = try _gfx.Buffer.init(
            @sizeOf(FontConstantBuffer),
            .{ .ConstantBuffer = true, },
            .{ .CpuWrite = true, },
            gfx
        );
        errdefer font.font_text_buffer.deinit();

        font.character_buffer = try _gfx.Buffer.init(
            @sizeOf([RENDER_INSTANCE_COUNT]CharacterInfoConstantBuffer),
            .{ .VertexBuffer = true, },
            .{ .CpuWrite = true, },
            gfx
        );
        errdefer font.character_buffer.deinit();

        // finally return the font structure
        return font;
    }

    pub const FontRenderProperties2D = struct {
        position: struct { x: i32, y: i32 },
        pixel_height: u32 = 20,
        colour: zm.F32x4 = zm.f32x4(1.0, 1.0, 1.0, 1.0),
    };

    pub fn render_text_2d(
        self: *Font,
        text: []const u8,
        props: FontRenderProperties2D,
        rtv: _gfx.RenderTargetView, 
        gfx: *_gfx.GfxState,
    ) void {
        if (text.len == 0) { return; }
        
        const aspect = (@as(f32, @floatFromInt(rtv.size.width)) / @as(f32, @floatFromInt(rtv.size.height)));
        const xy_screen_space = ui.position_pixels_to_screen_space(props.position.x, props.position.y, rtv.size.width, rtv.size.height);
        var y_loc = xy_screen_space[1];
        var x_loc = xy_screen_space[0];
        const x_start_loc = x_loc;

        const percpx = @as(f32, @floatFromInt(props.pixel_height)) / @as(f32, @floatFromInt(rtv.size.height));
        const screen_size = (percpx * 2.0);

        const viewport = _gfx.Viewport {
            .width = @floatFromInt(rtv.size.width),
            .height = @floatFromInt(rtv.size.height),
            .min_depth = 0.0,
            .max_depth = 1.0,
            .top_left_x = 0,
            .top_left_y = 0,
        };
        gfx.cmd_set_viewport(viewport);

        gfx.cmd_set_pixel_shader(&self.font_pso);
        gfx.cmd_set_shader_resources(.Pixel, 0, &.{&self.msdf_texture_view});

        gfx.cmd_set_render_target(&rtv, null);
        gfx.cmd_set_blend_state(&self.blend_state);

        gfx.cmd_set_vertex_shader(&self.font_vso);

        gfx.cmd_set_topology(.TriangleList);
        gfx.cmd_set_rasterizer_state(.{ .FillBack = false, .FrontCounterClockwise = true, });

        gfx.cmd_set_constant_buffers(.Pixel, 0, &.{&self.font_text_buffer});
        gfx.cmd_set_samplers(.Pixel, 0, &.{&self.sampler});

        gfx.cmd_set_vertex_buffers(0, &.{
            .{ .buffer = &self.character_buffer, .stride = @sizeOf(CharacterInfoConstantBuffer), .offset = 0, },
        });

        { // Setup font text info buffer
            const mapped_buffer = self.font_text_buffer.map(FontConstantBuffer, gfx) catch unreachable;
            defer mapped_buffer.unmap();

            mapped_buffer.data().* = FontConstantBuffer {
                .msdf_unit_range = zm.f32x4s(self.atlas_details.distance_range) 
                    / zm.f32x4(@floatFromInt(self.atlas_details.width), @floatFromInt(self.atlas_details.height), 0.0, 0.0),
                .fg_colour = props.colour,
                .bg_colour = props.colour * zm.f32x4(1.0, 1.0, 1.0, 0.0),
            };
        }

        var text_offset: usize = 0;
        while (text_offset < text.len) {
            var instance_count: u32 = 0;
            {
                const mapped_buffer = self.character_buffer.map(([RENDER_INSTANCE_COUNT]CharacterInfoConstantBuffer), gfx) catch unreachable;
                defer mapped_buffer.unmap();

                while (instance_count < RENDER_INSTANCE_COUNT and (text_offset + instance_count) < text.len) {
                    const c = text[text_offset + instance_count];

                    // reset data in this instance
                    mapped_buffer.data()[instance_count].quad_bounds = .{};
                    mapped_buffer.data()[instance_count].atlas_bounds = .{};

                    // handle newline character
                    switch (c) {
                        '\n' => {
                            x_loc = x_start_loc;
                            y_loc -= self.font_metrics.line_height * screen_size;
                        },
                        else => {
                            const char_info = &self.ascii_character_map[@intCast(c)];

                            const quad_bounds = Bounds {
                                .left = x_loc + (char_info.plane_bounds.left / aspect) * screen_size,
                                .right = x_loc + (char_info.plane_bounds.right / aspect) * screen_size,
                                .top = y_loc + char_info.plane_bounds.top * screen_size,
                                .bottom = y_loc + char_info.plane_bounds.bottom * screen_size,
                            };

                            // Setup character info buffer
                            mapped_buffer.data()[instance_count].quad_bounds = quad_bounds;
                            mapped_buffer.data()[instance_count].atlas_bounds = char_info.atlas_bounds;

                            x_loc += (char_info.advance / aspect) * screen_size;
                        },
                    }

                    instance_count += 1;
                }
            }

            gfx.cmd_draw_instanced(6, instance_count, 0, 0);
            text_offset += instance_count;
        }
    }

    pub fn text_bounds_2d_pixels(
        self: *Font,
        text: []const u8,
        pixel_height: u32,
    ) ui.RectPixels {
        const pixel_height_f32: f32 = @floatFromInt(pixel_height);
        
        var line_count: f32 = 0.0;
        var x_loc: f32 = 0.0;

        const x_start_loc = x_loc;

        var max_x = x_loc;
        for (text) |c| {
            switch (c) {
                '\n' => {
                    x_loc = x_start_loc;
                    line_count += 1.0;
                },
                else => {
                    const char_info = &self.ascii_character_map[@intCast(c)];

                    x_loc += char_info.advance;
                    max_x = @max(max_x, x_loc);
                },
            }
        }

        return ui.RectPixels {
            .left = 0,
            .top = @intFromFloat(-self.font_metrics.ascender * pixel_height_f32),
            .width = @intFromFloat(max_x * pixel_height_f32),
            .height = @intFromFloat((self.font_metrics.ascender + self.font_metrics.descender + (line_count * self.font_metrics.line_height)) * pixel_height_f32),
        };
    }
};

