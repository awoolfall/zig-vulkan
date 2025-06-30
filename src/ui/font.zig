const std = @import("std");
const zstbi = @import("zstbi");
const eng = @import("self");
const _gfx = @import("../gfx/gfx.zig");
const zm = @import("zmath");
const ui = @import("ui.zig");
const path = @import("../engine/path.zig");
const RectPixels = @import("../root.zig").Rect;

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
    quad_bounds: Bounds = .{},
    atlas_bounds: Bounds = .{},
};

const TextRenderInfo = struct {
    text: []u8,
    fg_colour: zm.F32x4,
    bg_colour: zm.F32x4 = zm.f32x4s(0.0),
    position: zm.F32x4,
    size: f32,
};

const FontTextBufferData = struct {
    text_buffer: _gfx.Buffer.Ref,
    descriptor_set: _gfx.DescriptorSet.Ref,

    pub fn deinit(self: *FontTextBufferData) void {
        self.descriptor_set.deinit();
        self.text_buffer.deinit();
    }
};

const MSDF_FONT_SHADER_HLSL = @embedFile("font_shader.slang");

pub const Font = struct {
    const TEXT_PROPS_PER_BUFFER = 1024;
    const CHARACTERS_PER_VERTEX_BUFFER = 4096;

    atlas_details: AtlasDetails,
    font_metrics: FontMetrics,
    character_map: std.AutoHashMap(u21, CharacterInfo),

    msdf_image: _gfx.Image.Ref,
    msdf_image_view: _gfx.ImageView.Ref,
    sampler: _gfx.Sampler.Ref,

    // TODO move to common font renderer struct
    vertex_shader: _gfx.VertexShader,
    pixel_shader: _gfx.PixelShader,

    render_pass: _gfx.RenderPass.Ref,
    pipeline: _gfx.GraphicsPipeline.Ref,
    framebuffer: _gfx.FrameBuffer.Ref,

    image_descriptor_layout: _gfx.DescriptorLayout.Ref,
    image_descriptor_pool: _gfx.DescriptorPool.Ref,
    image_descriptor_set: _gfx.DescriptorSet.Ref,

    buffers_descriptor_layout: _gfx.DescriptorLayout.Ref,
    buffers_descriptor_pool: _gfx.DescriptorPool.Ref,

    character_vertex_buffers: std.ArrayList(_gfx.Buffer.Ref),
    text_props_buffers: std.ArrayList(FontTextBufferData),

    frame_texts: std.ArrayList(TextRenderInfo),

    pub fn deinit(self: *Font) void {
        self.frame_texts.deinit();

        for (self.text_props_buffers.items) |*b| { b.deinit(); }
        self.text_props_buffers.deinit();
        for (self.character_vertex_buffers.items) |b| { b.deinit(); }
        self.character_vertex_buffers.deinit();

        self.buffers_descriptor_pool.deinit();
        self.buffers_descriptor_layout.deinit();

        self.image_descriptor_set.deinit();
        self.image_descriptor_pool.deinit();
        self.image_descriptor_layout.deinit();

        self.framebuffer.deinit();
        self.pipeline.deinit();
        self.render_pass.deinit();

        self.vertex_shader.deinit();
        self.pixel_shader.deinit();

        self.msdf_image_view.deinit();
        self.msdf_image.deinit();
        self.sampler.deinit();

        self.character_map.deinit();
    }

    pub fn init(font_json: path.Path, font_msdf_png: path.Path) !Font {
        const alloc = eng.get().general_allocator;

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
                unicode: u21,
                advance: f32,
                planeBounds: Bounds = .{},
                atlasBounds: Bounds = .{},
            },
            // @TODO: figure out how to parse kerning data
            //kerning: []struct {},
        };

        // deserialize font json
        const font_data = try std.json.parseFromSlice(FontJson, alloc, font_json_data, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always
        });
        defer font_data.deinit();

        const atlas_details = AtlasDetails {
            .distance_range = font_data.value.atlas.distanceRange,
            .size = font_data.value.atlas.size,
            .width = font_data.value.atlas.width,
            .height = font_data.value.atlas.height,
        };
        const font_metrics = FontMetrics {
            .em_size = font_data.value.metrics.emSize,
            .line_height = font_data.value.metrics.lineHeight,
            .ascender = font_data.value.metrics.ascender,
            .descender = -font_data.value.metrics.descender,
            .underline_y = font_data.value.metrics.underlineY,
            .underline_thickness = font_data.value.metrics.underlineThickness,
        };

        // load msdf font png file
        const font_png_path = try font_msdf_png.resolve_path_c_str(alloc);
        defer alloc.free(font_png_path);

        var font_image = try zstbi.Image.loadFromFile(font_png_path, 4);
        defer font_image.deinit();

        // create a d3d11 texture from the font png file
        const msdf_image = try _gfx.Image.init(
            .{
                .width = @intCast(atlas_details.width),
                .height = @intCast(atlas_details.height),
                .format = .Rgba8_Unorm,

                .usage_flags = .{ .ShaderResource = true, },
                .access_flags = .{},
                .dst_layout = .ShaderReadOnlyOptimal,
            },
            font_image.data,
        );
        errdefer msdf_image.deinit();

        const msdf_image_view = try _gfx.ImageView.init(.{ .image = msdf_image, });
        errdefer msdf_image_view.deinit();

        // create sampler
        const sampler = try _gfx.Sampler.init(
            .{
                .filter_min_mag = .Linear,
                .filter_mip = .Point,
                .border_mode = .Wrap,
            },
        );
        errdefer sampler.deinit();

        // create the font shaders
        // @TODO move font shader to a common location, not in each font file
        const vertex_shader = try _gfx.VertexShader.init_buffer(
            MSDF_FONT_SHADER_HLSL,
            "vs_main",
            .{
                .bindings = &.{
                    .{ .binding = 0, .stride = 2 * @sizeOf([4]f32), .input_rate = .Instance, },
                },
                .attributes = &.{
                    .{ .name = "TEXCOORD0", .location = 0, .binding = 0, .offset = 0 * @sizeOf([4]f32), .format = .F32x4, },
                    .{ .name = "TEXCOORD1", .location = 1, .binding = 0, .offset = 1 * @sizeOf([4]f32), .format = .F32x4, },
                },
            },
            .{},
        );
        errdefer vertex_shader.deinit();

        const pixel_shader = try _gfx.PixelShader.init_buffer(
            MSDF_FONT_SHADER_HLSL,
            "ps_main",
            .{},
        );
        errdefer pixel_shader.deinit();

        const attachments = &[_]_gfx.AttachmentInfo {
            _gfx.AttachmentInfo {
                .name = "colour",
                .format = _gfx.GfxState.ldr_format,
                .initial_layout = .ColorAttachmentOptimal,
                .final_layout = .ColorAttachmentOptimal,
                .blend_type = .PremultipliedAlpha,
            },
            _gfx.AttachmentInfo {
                .name = "depth",
                .format = _gfx.GfxState.depth_format,
                .initial_layout = .DepthStencilAttachmentOptimal,
                .final_layout = .DepthStencilAttachmentOptimal,
            },
        };

        const render_pass = try _gfx.RenderPass.init(.{
            .attachments = attachments,
            .subpasses = &[_]_gfx.SubpassInfo {
                .{
                    .attachments = &.{ "colour" },
                    .depth_attachment = "depth",
                },
            },
            .dependencies = &.{
                _gfx.SubpassDependencyInfo {
                    .src_subpass = null,
                    .dst_subpass = 0,
                    .src_stage_mask = .{ .color_attachment_output = true, },
                    .src_access_mask = .{},
                    .dst_stage_mask = .{ .color_attachment_output = true, },
                    .dst_access_mask = .{ .color_attachment_write = true, },
                },
            },
        });
        errdefer render_pass.deinit();

        const buffers_descriptor_layout = try _gfx.DescriptorLayout.init(.{
            .bindings = &[_]_gfx.DescriptorBindingInfo {
                _gfx.DescriptorBindingInfo {
                    .binding = 0,
                    .binding_type = .UniformBuffer,
                    .shader_stages = .{ .Pixel = true, },
                },
            },
        });
        errdefer buffers_descriptor_layout.deinit();

        const buffers_descriptor_pool = try _gfx.DescriptorPool.init(.{
            .max_sets = 64,
            .strategy = .{ .Layout = buffers_descriptor_layout, },
        });
        errdefer buffers_descriptor_pool.deinit();

        const image_descriptor_layout = try _gfx.DescriptorLayout.init(.{
            .bindings = &.{
                _gfx.DescriptorBindingInfo {
                    .binding = 0,
                    .binding_type = .ImageView,
                    .shader_stages = .{ .Pixel = true, },
                },
                _gfx.DescriptorBindingInfo {
                    .binding = 1,
                    .binding_type = .Sampler,
                    .shader_stages = .{ .Pixel = true, },
                },
            },
        });
        errdefer image_descriptor_layout.deinit();

        const image_descriptor_pool = try _gfx.DescriptorPool.init(.{
            .max_sets = 1,
            .strategy = .{ .Layout = image_descriptor_layout, },
        });
        errdefer image_descriptor_pool.deinit();

        const image_descriptor_set = try (image_descriptor_pool.get() catch unreachable)
            .allocate_set(.{ .layout = image_descriptor_layout, });
        errdefer image_descriptor_set.deinit();

        try (image_descriptor_set.get() catch unreachable).update(_gfx.DescriptorSetUpdateInfo {
            .writes = &.{
                .{
                    .binding = 0,
                    .data = .{ .ImageView = msdf_image_view },
                },
                .{
                    .binding = 1,
                    .data = .{ .Sampler = sampler },
                },
            },
        });

        const graphics_pipeline = try _gfx.GraphicsPipeline.init(.{
            .vertex_shader = &vertex_shader,
            .pixel_shader = &pixel_shader,
            .attachments = attachments,
            .cull_mode = .CullNone, // TODO
            .descriptor_set_layouts = &.{
                buffers_descriptor_layout,
                image_descriptor_layout,
            },
            .push_constants = &.{
                _gfx.PushConstantLayoutInfo {
                    .shader_stages = .{ .Pixel = true, },
                    .size = 4,
                    .offset = 0,
                },
            },
            .depth_test = .{ .write = true, },
            .render_pass = render_pass,
            .subpass_index = 0,
        });
        errdefer graphics_pipeline.deinit();

        const framebuffer = try _gfx.FrameBuffer.init(.{
            .render_pass = render_pass,
            .attachments = &.{
                .SwapchainLDR,
                .SwapchainDepth,
            },
        });
        errdefer framebuffer.deinit();

        const msdf_width: f32 = @floatFromInt(atlas_details.width);
        const msdf_height: f32 = @floatFromInt(atlas_details.height);

        var character_map = std.AutoHashMap(u21, CharacterInfo).init(alloc);
        errdefer character_map.deinit();

        // fill font character info array with data from font json
        for (font_data.value.glyphs) |*glyph| {
            const character_info = CharacterInfo {
                .advance = glyph.advance,
                .plane_bounds = glyph.planeBounds,
                .atlas_bounds = Bounds {
                    .left = (glyph.atlasBounds.left / msdf_width),
                    .right = (glyph.atlasBounds.right / msdf_width),
                    .top = 1.0 - (glyph.atlasBounds.top / msdf_height),
                    .bottom = 1.0 - (glyph.atlasBounds.bottom / msdf_height),
                },
            };
            try character_map.put(glyph.unicode, character_info);
        }

        // create arrays
        const character_vertex_buffers = std.ArrayList(_gfx.Buffer.Ref).init(eng.get().general_allocator);
        errdefer character_vertex_buffers.deinit();

        const text_props_buffers = std.ArrayList(FontTextBufferData).init(eng.get().general_allocator);
        errdefer text_props_buffers.deinit();

        const frame_texts = std.ArrayList(TextRenderInfo).init(eng.get().general_allocator);
        errdefer frame_texts.deinit();

        return Font {
            .atlas_details = atlas_details,
            .font_metrics = font_metrics,
            .character_map = character_map,

            .msdf_image = msdf_image,
            .msdf_image_view = msdf_image_view,
            .sampler = sampler,

            .vertex_shader = vertex_shader,
            .pixel_shader = pixel_shader,

            .render_pass = render_pass,
            .pipeline = graphics_pipeline,
            .framebuffer = framebuffer,

            .image_descriptor_layout = image_descriptor_layout,
            .image_descriptor_pool = image_descriptor_pool,
            .image_descriptor_set = image_descriptor_set,

            .buffers_descriptor_layout = buffers_descriptor_layout,
            .buffers_descriptor_pool = buffers_descriptor_pool,

            .character_vertex_buffers = character_vertex_buffers,
            .text_props_buffers = text_props_buffers,

            .frame_texts = frame_texts,
        };
    }

    fn frame_allocator() std.mem.Allocator {
        return eng.get().frame_allocator;
    }

    fn create_new_text_props_buffer(self: *Font) !void {
        const new_buffer = try _gfx.Buffer.init(
            @sizeOf(FontConstantBuffer) * Font.TEXT_PROPS_PER_BUFFER,
            .{ .ConstantBuffer = true, },
            .{ .CpuWrite = true, },
        );
        errdefer new_buffer.deinit();

        const descriptor_set = try (self.buffers_descriptor_pool.get() catch unreachable)
            .allocate_set(.{ .layout = self.buffers_descriptor_layout, });
        errdefer descriptor_set.deinit();

        try (descriptor_set.get() catch unreachable).update(_gfx.DescriptorSetUpdateInfo {
            .writes = &[_]_gfx.DescriptorSetUpdateWriteInfo {
                .{
                    .binding = 0,
                    .data = .{ .UniformBuffer = .{
                        .buffer = new_buffer,
                    } },
                },
            },
        });

        try self.text_props_buffers.append(FontTextBufferData {
            .text_buffer = new_buffer,
            .descriptor_set = descriptor_set,
        });
    }

    fn create_new_character_vertex_buffer(self: *Font) !void {
        const new_buffer = try _gfx.Buffer.init(
            @sizeOf(CharacterInfoConstantBuffer) * Font.CHARACTERS_PER_VERTEX_BUFFER,
            .{ .VertexBuffer = true, },
            .{ .CpuWrite = true, },
        );
        errdefer new_buffer.deinit();

        try self.character_vertex_buffers.append(new_buffer);
    }

    pub const FontRenderProperties2D = struct {
        position: struct { x: f32, y: f32 },
        pixel_height: f32 = 20.0,
        colour: zm.F32x4 = zm.f32x4(1.0, 1.0, 1.0, 1.0),
    };

    pub fn submit_text_2d(
        self: *Font,
        text: []const u8,
        props: FontRenderProperties2D,
    ) !void {
        const alloc = frame_allocator();

        const owned_text = try alloc.dupe(u8, text);
        errdefer alloc.free(owned_text);

        try self.frame_texts.append(TextRenderInfo {
            .text = owned_text,
            .position = zm.f32x4(props.position.x, props.position.y, 0.0, 0.0),
            .fg_colour = props.colour,
            .bg_colour = props.colour * zm.f32x4(1.0, 1.0, 1.0, 0.0),
            .size = props.pixel_height,
        });
    }

    pub fn render_texts(
        self: *Font,
        cmd: *_gfx.CommandBuffer,
    ) !void {
        // return early if there are no text items
        if (self.frame_texts.items.len == 0) { return; }

        // defer clear text items set to render this frame
        // TODO there may be a memory issue if this isnt called every frame, fix?
        defer self.frame_texts.clearRetainingCapacity();
        defer for (self.frame_texts.items) |t| { frame_allocator().free(t.text); };

        // run common commands
        cmd.cmd_begin_render_pass(_gfx.CommandBuffer.BeginRenderPassInfo {
            .framebuffer = self.framebuffer,
            .render_pass = self.render_pass,
            .render_area = .full_screen_pixels(),
        });
        defer cmd.cmd_end_render_pass();

        cmd.cmd_bind_graphics_pipeline(self.pipeline);

        cmd.cmd_set_viewports(.{ .viewports = &.{ .full_screen_viewport() }, });
        cmd.cmd_set_scissors(.{ .scissors = &.{ .full_screen_pixels(), }, } );

        cmd.cmd_bind_descriptor_sets(_gfx.CommandBuffer.BindDescriptorSetInfo {
            .graphics_pipeline = self.pipeline,
            .first_binding = 1,
            .descriptor_sets = &.{
                self.image_descriptor_set,
            },
        });

        // set mapped buffers to null, these will be set dynamically in the following loop
        var mapped_vertex_buffer: ?_gfx.Buffer.MappedBuffer = null;
        defer if (mapped_vertex_buffer) |b| b.unmap();

        var mapped_text_props_buffer: ?_gfx.Buffer.MappedBuffer = null;
        defer if (mapped_text_props_buffer) |b| b.unmap();

        // keep track of buffer indexes
        var vertex_buffer_idx: isize = -1;
        var next_character_idx: usize = Font.CHARACTERS_PER_VERTEX_BUFFER;

        var text_props_buffer_idx: isize = -1;
        var next_text_props_idx: usize = Font.TEXT_PROPS_PER_BUFFER;

        // perform rendering for all text items using this font
        for (self.frame_texts.items) |t| for_frame_texts_blk: {
            // calculate text length in utf8 codepoints
            const utf8_length = std.unicode.utf8CountCodepoints(t.text) catch |err| {
                std.log.warn("Unable to count text codepoints: {}", .{err});
                continue;
            };

            // skip rendering if text is outside of supported lengths
            if (utf8_length > Font.CHARACTERS_PER_VERTEX_BUFFER) {
                std.log.warn("text is greater than {} characters, skipping", .{ Font.CHARACTERS_PER_VERTEX_BUFFER });
                continue;
            }
            if (utf8_length == 0) { continue; }

            // check we can fit text data into the current text props buffer, if not then create a new one
            if (next_text_props_idx >= Font.TEXT_PROPS_PER_BUFFER) {
                // increment buffer index and reset props index
                text_props_buffer_idx += 1;
                next_text_props_idx = 0;

                // create new text props buffer if necessary
                if (self.text_props_buffers.items.len == text_props_buffer_idx) {
                    self.create_new_text_props_buffer() catch |err| {
                        std.log.err("Unable to create new text props buffer: {}", .{err});
                        break :for_frame_texts_blk;
                    };
                }

                // update mapped buffer
                if (mapped_text_props_buffer) |b| { b.unmap(); }
                const text_props_buffer = self.text_props_buffers.items[@intCast(text_props_buffer_idx)].text_buffer.get() catch unreachable;
                mapped_text_props_buffer = text_props_buffer.map(.{ .write = true, }) catch |err| {
                    std.log.err("Unable to map text props buffer: {}", .{err});
                    break :for_frame_texts_blk;
                };

                cmd.cmd_bind_descriptor_sets(_gfx.CommandBuffer.BindDescriptorSetInfo {
                    .graphics_pipeline = self.pipeline,
                    .first_binding = 0,
                    .descriptor_sets = &.{ self.text_props_buffers.items[@intCast(text_props_buffer_idx)].descriptor_set },
                });
            }

            // check we can fit text character data into the current character vertex buffer, if not then create a new one
            if (next_character_idx + utf8_length > Font.CHARACTERS_PER_VERTEX_BUFFER) {
                // increment buffer index and reset characters index
                vertex_buffer_idx += 1;
                next_character_idx = 0;

                // create new character vertex buffer if necessary
                if (self.character_vertex_buffers.items.len == vertex_buffer_idx) {
                    self.create_new_character_vertex_buffer() catch |err| {
                        std.log.err("Unable to create new character vertex buffer: {}", .{err});
                        break :for_frame_texts_blk;
                    };
                }

                // update mapped buffer
                if (mapped_vertex_buffer) |b| { b.unmap(); }
                const vertex_buffer = self.character_vertex_buffers.items[@intCast(vertex_buffer_idx)].get() catch unreachable;
                mapped_vertex_buffer = vertex_buffer.map(.{ .write = true, }) catch |err| {
                    std.log.err("Unable to map character vertex buffer: {}", .{err});
                    break :for_frame_texts_blk;
                };

                cmd.cmd_bind_vertex_buffers(_gfx.CommandBuffer.BindVertexBuffersInfo {
                    .first_binding = 0,
                    .buffers = &.{ 
                        .{
                            .buffer = self.character_vertex_buffers.items[@intCast(vertex_buffer_idx)],
                        },
                    },
                });
            }

            var layout_info = CharacterLayoutInfo {};

            // get an iterator over the utf-8 codepoints
            const text_utf8 = std.unicode.Utf8View.init(t.text) catch |err| {
                std.log.warn("Unable to create utf-8 view for text '{s}': {}", .{t.text, err});
                continue;
            };
            var text_utf8_iter = text_utf8.iterator();

            const character_start_idx = next_character_idx;

            // iterate codepoints and fill character vertex buffer
            while (text_utf8_iter.nextCodepoint()) |c| {
                const character_quad_bounds = self.calculate_character_quad_bounds(&layout_info, c, t.position, t.size)
                    catch Bounds{};
                self.layout_another_character(&layout_info, c);

                const character_info = self.character_map.get(c) orelse {
                    continue;
                };

                const data_array = mapped_vertex_buffer.?.data_array(CharacterInfoConstantBuffer, Font.CHARACTERS_PER_VERTEX_BUFFER);
                data_array[next_character_idx] = CharacterInfoConstantBuffer {
                    .atlas_bounds = character_info.atlas_bounds,
                    .quad_bounds = character_quad_bounds,
                };

                // increment character index
                next_character_idx += 1;
            }

            // skip rendering if there are no characters to render
            if (next_character_idx == character_start_idx) { continue; }

            // fill text properties buffer at index
            const text_props_buffer = mapped_text_props_buffer.?.data_array(FontConstantBuffer, Font.TEXT_PROPS_PER_BUFFER);
            text_props_buffer[next_text_props_idx] = FontConstantBuffer {
                .bg_colour = t.bg_colour,
                .fg_colour = t.fg_colour,
                .msdf_unit_range = zm.f32x4s(self.atlas_details.distance_range) 
                    / zm.f32x4(@floatFromInt(self.atlas_details.width), @floatFromInt(self.atlas_details.height), 0.0, 0.0),
            };

            // set push constant to text props index
            cmd.cmd_push_constants(_gfx.CommandBuffer.PushConstantsInfo {
                .graphics_pipeline = self.pipeline,
                .shader_stages = .{ .Pixel = true, },
                .offset = 0,
                .size = 4,
                .data = std.mem.toBytes(next_text_props_idx)[0..],
            });

            // draw instanced all characters in this text item
            cmd.cmd_draw(_gfx.CommandBuffer.DrawInfo {
                .first_instance = @intCast(character_start_idx),
                .instance_count = @intCast(next_character_idx - character_start_idx),
                .vertex_count = 6,
            });
            
            // increment props index
            next_text_props_idx += 1;
        }
    }

    // pub fn render_text_2d(
    //     self: *const Font,
    //     text: []const u8,
    //     props: FontRenderProperties2D,
    //     rtv: _gfx.ImageView.Ref, 
    // ) void {
    //     const gfx = _gfx.GfxState.get();
    //
    //     if (text.len == 0) { return; }
    //     
    //     const view = rtv.get() catch unreachable;
    //     const aspect = (@as(f32, @floatFromInt(view.size.width)) / @as(f32, @floatFromInt(view.size.height)));
    //     const xy_screen_space = ui.position_pixels_to_screen_space(
    //         props.position.x,
    //         props.position.y,
    //         @floatFromInt(view.size.width),
    //         @floatFromInt(view.size.height)
    //     );
    //     var y_loc = xy_screen_space[1];
    //     var x_loc = xy_screen_space[0];
    //     const x_start_loc = x_loc;
    //
    //     const percpx = props.pixel_height / @as(f32, @floatFromInt(view.size.height));
    //     const screen_size = (percpx * 2.0);
    //
    //     const viewport = _gfx.Viewport {
    //         .width = @floatFromInt(view.size.width),
    //         .height = @floatFromInt(view.size.height),
    //         .min_depth = 0.0,
    //         .max_depth = 1.0,
    //         .top_left_x = 0,
    //         .top_left_y = 0,
    //     };
    //     gfx.cmd_set_viewport(viewport);
    //
    //     gfx.cmd_set_pixel_shader(&self.font_pso);
    //     gfx.cmd_set_shader_resources(.Pixel, 0, &.{self.msdf_texture_view});
    //
    //     gfx.cmd_set_render_target(&.{rtv}, null);
    //
    //     gfx.cmd_set_vertex_shader(&self.font_vso);
    //
    //     gfx.cmd_set_topology(.TriangleList);
    //     gfx.cmd_set_rasterizer_state(.{ .FillBack = false, .FrontCounterClockwise = true, });
    //
    //     gfx.cmd_set_constant_buffers(.Pixel, 0, &.{&self.font_text_buffer});
    //     gfx.cmd_set_samplers(.Pixel, 0, &.{self.sampler});
    //
    //     gfx.cmd_set_vertex_buffers(0, &.{
    //         .{ .buffer = &self.character_buffer, .stride = @sizeOf(CharacterInfoConstantBuffer), .offset = 0, },
    //     });
    //
    //     { // Setup font text info buffer
    //         const mapped_buffer = self.font_text_buffer.map(.{ .write = true, }) catch unreachable;
    //         defer mapped_buffer.unmap();
    //
    //         mapped_buffer.data(FontConstantBuffer).* = FontConstantBuffer {
    //             .msdf_unit_range = zm.f32x4s(self.atlas_details.distance_range) 
    //                 / zm.f32x4(@floatFromInt(self.atlas_details.width), @floatFromInt(self.atlas_details.height), 0.0, 0.0),
    //             .fg_colour = props.colour,
    //             .bg_colour = props.colour * zm.f32x4(1.0, 1.0, 1.0, 0.0),
    //         };
    //     }
    //
    //     const text_utf8 = std.unicode.Utf8View.init(text) catch unreachable; // TODO handle error
    //     var text_utf8_iter = text_utf8.iterator();
    //
    //     var instance_id: usize = 0;
    //     while (text_utf8_iter.nextCodepoint()) |c| {
    //         if (instance_id >= RENDER_INSTANCE_COUNT) {
    //             {
    //                 const mapped_buffer = self.character_buffer.map(.{ .write = true, }) catch unreachable;
    //                 defer mapped_buffer.unmap();
    //
    //                 @memcpy(mapped_buffer.data_array(CharacterInfoConstantBuffer, RENDER_INSTANCE_COUNT)[0..], self.constant_buffer_data[0..]);
    //             }
    //
    //             gfx.cmd_draw_instanced(6, RENDER_INSTANCE_COUNT, 0, 0);
    //
    //             instance_id = 0;
    //         }
    //
    //         // handle newline
    //         switch (c) {
    //             '\n' => {
    //                 x_loc = x_start_loc;
    //                 y_loc -= self.font_metrics.line_height * screen_size;
    //                 self.constant_buffer_data[instance_id] = .{};
    //             },
    //             else => {
    //                 const char_info = self.character_map.get(c) orelse continue; // TODO handle error
    //
    //                 const quad_bounds = Bounds {
    //                     .left = x_loc + (char_info.plane_bounds.left / aspect) * screen_size,
    //                     .right = x_loc + (char_info.plane_bounds.right / aspect) * screen_size,
    //                     .top = y_loc + char_info.plane_bounds.top * screen_size,
    //                     .bottom = y_loc + char_info.plane_bounds.bottom * screen_size,
    //                 };
    //
    //                 // Setup character info buffer
    //                 self.constant_buffer_data[instance_id] = .{
    //                     .quad_bounds = quad_bounds,
    //                     .atlas_bounds = char_info.atlas_bounds,
    //                 };
    //
    //                 x_loc += (char_info.advance / aspect) * screen_size;
    //             }
    //         }
    //
    //         instance_id += 1;
    //     }
    //     // render the remaining characters
    //     if (instance_id > 0) {
    //         {
    //             const mapped_buffer = self.character_buffer.map(.{ .write = true, }) catch unreachable;
    //             defer mapped_buffer.unmap();
    //
    //             @memcpy(mapped_buffer.data_array(CharacterInfoConstantBuffer, RENDER_INSTANCE_COUNT)[0..], self.constant_buffer_data[0..]);
    //         }
    //
    //         gfx.cmd_draw_instanced(6, @truncate(instance_id), 0, 0);
    //     }
    // }

    const CharacterLayoutInfo = struct {
        x_location: f32 = 0.0,
        y_location: f32 = 0.0,
        line_count: f32 = 0.0,
        max_x: f32 = 0.0,
    };

    fn layout_another_character(
        self: *const Font,
        info: *CharacterLayoutInfo,
        character_codepoint: u21,
    ) void {
        switch (character_codepoint) {
            '\n' => {
                info.x_location = 0.0;
                info.y_location += self.font_metrics.line_height;
                info.line_count += 1.0;
            },
            else => {
                const char_info = self.character_map.get(character_codepoint) orelse return;
                info.x_location += char_info.advance;
            },
        }

        info.max_x = @max(info.max_x, info.x_location);
    }

    fn calculate_character_quad_bounds(
        self: *const Font,
        layout_info: *const CharacterLayoutInfo,
        character_codepoint: u21,
        text_start_location: zm.F32x4,
        pixel_height: f32,
    ) !Bounds {
        const char_info = self.character_map.get(character_codepoint) orelse return error.CharacterInfoDoesNotExist;

        const screen_size = eng.get().gfx.swapchain_size();
        const size_f32 = [2]f32{ @floatFromInt(screen_size[0]), @floatFromInt(screen_size[1]) };
        const screen_aspect = eng.get().gfx.swapchain_aspect();

        const percpx = pixel_height / @as(f32, @floatFromInt(screen_size[1]));
        const font_screen_size = (percpx * 2.0);

        var location = [2]f32{
            (text_start_location[0] / size_f32[0]) + (layout_info.x_location * pixel_height) / size_f32[0],
            (text_start_location[1] / size_f32[1]) + (layout_info.y_location * pixel_height) / size_f32[1],
        };
        location[0] = (location[0] * 2.0) - 1.0;
        location[1] = (location[1] * 2.0) - 1.0;

        return Bounds {
            .left = location[0] + char_info.plane_bounds.left * font_screen_size / screen_aspect,
            .right = location[0] + char_info.plane_bounds.right * font_screen_size / screen_aspect,
            .top = location[1] - char_info.plane_bounds.top * font_screen_size,
            .bottom = location[1] - char_info.plane_bounds.bottom * font_screen_size,
        };
    }

    pub fn text_bounds_2d_pixels(
        self: *const Font,
        text: []const u8,
        pixel_height: f32,
    ) RectPixels {
        var line_count: f32 = 0.0;
        var x_loc: f32 = 0.0;

        const x_start_loc = x_loc;

        var max_x = x_loc;

        const text_utf8 = std.unicode.Utf8View.init(text) catch unreachable; // TODO handle error
        var text_utf8_iter = text_utf8.iterator();

        while (text_utf8_iter.nextCodepoint()) |c| {
            switch (c) {
                '\n' => {
                    x_loc = x_start_loc;
                    line_count += 1.0;
                },
                else => {
                    const char_info = self.character_map.get(c) orelse continue; // TODO handle error

                    x_loc += char_info.advance;
                    max_x = @max(max_x, x_loc);
                },
            }
        }

        const top = -self.font_metrics.ascender * pixel_height;
        return RectPixels {
            .left = 0,
            .top = -self.font_metrics.ascender * pixel_height,
            .right = max_x * pixel_height,
            .bottom = top + (self.font_metrics.ascender + self.font_metrics.descender + (line_count * self.font_metrics.line_height)) * pixel_height,
        };
    }
};

