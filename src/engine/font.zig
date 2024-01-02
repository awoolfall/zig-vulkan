const std = @import("std");
const win32 = @import("zwin32");
const d3d11 = win32.d3d11;
const zstbi = @import("zstbi");
const gfx_d3d11 = @import("../gfx/d3d11.zig");
const zm = @import("zmath");

pub const Rect = struct {
    left: f32,
    bottom: f32,
    right: f32,
    top: f32,
};

pub const Size = union(enum) {
    Pixels: i32,
    Screen: f32,
};

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

    atlas_details: AtlasDetails,
    font_metrics: FontMetrics,
    ascii_character_map: [256]CharacterInfo,
    msdf_texture_view: *d3d11.IShaderResourceView,
    font_vso: *d3d11.IVertexShader,
    vso_input_layout: *d3d11.IInputLayout,
    font_pso: *d3d11.IPixelShader,
    sampler: *d3d11.ISamplerState,
    rasterizer_state: *d3d11.IRasterizerState,
    blend_state: *d3d11.IBlendState,
    character_buffer: *d3d11.IBuffer,
    font_text_buffer: *d3d11.IBuffer,
    _allocator: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, font_json: [:0]const u8, font_msdf_png: [:0]const u8, gfx: *gfx_d3d11.D3D11State) !Font {
        // find font json file size
        var font_json_file_size: u64 = undefined;
        {
            const font_json_file = try std.fs.cwd().openFile(font_json, .{});
            defer font_json_file.close();

            font_json_file_size = try font_json_file.getEndPos();
        }

        // read json file into memory
        const font_json_data = try std.fs.cwd().readFileAlloc(alloc, font_json, font_json_file_size);
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
            .vso_input_layout = undefined,
            .sampler = undefined,
            .rasterizer_state = undefined,
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
                .descender = font_data.value.metrics.descender,
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

        // @TODO move generic stbi init to engine?
        zstbi.init(alloc);
        defer zstbi.deinit();

        // load msdf font png file
        var font_image = try zstbi.Image.loadFromFile(font_msdf_png, 4);
        defer font_image.deinit();

        // create a d3d11 texture from the font png file
        const image_sub_data = d3d11.SUBRESOURCE_DATA {
            .pSysMem = @ptrCast(font_image.data),
            .SysMemPitch = @intCast(font_image.bytes_per_row),
        };
        
        const texture_desc = d3d11.TEXTURE2D_DESC {
            .Width = @intCast(font.atlas_details.width),
            .Height = @intCast(font.atlas_details.height),
            .MipLevels = 1,
            .ArraySize = 1,
            .Format = win32.dxgi.FORMAT.R8G8B8A8_UNORM,
            .SampleDesc = .{.Count = 1, .Quality = 0,},
            .Usage = d3d11.USAGE.IMMUTABLE,
            .BindFlags = d3d11.BIND_FLAG {.SHADER_RESOURCE = true,},
            .CPUAccessFlags = d3d11.CPU_ACCCESS_FLAG {},
            .MiscFlags = d3d11.RESOURCE_MISC_FLAG {},
        };
        var msdf_texture: *d3d11.ITexture2D = undefined;
        try win32.hrErrorOnFail(gfx.device.CreateTexture2D(&texture_desc, @ptrCast(&image_sub_data), @ptrCast(&msdf_texture)));
        defer _ = msdf_texture.Release();

        const msdf_resource_view_desc = d3d11.SHADER_RESOURCE_VIEW_DESC {
            .Format = win32.dxgi.FORMAT.R8G8B8A8_UNORM,
            .ViewDimension = d3d11.SRV_DIMENSION.TEXTURE2D,
            .u = .{
                .Texture2D = d3d11.TEX2D_SRV {
                    .MostDetailedMip = 0,
                    .MipLevels = 1,
                },
            },
        };
        try win32.hrErrorOnFail(gfx.device.CreateShaderResourceView(@ptrCast(msdf_texture), &msdf_resource_view_desc, @ptrCast(&font.msdf_texture_view)));
        errdefer _ = font.msdf_texture_view.Release();

        // create the font shaders
        // @TODO move font shader to a common location, not in each font file
        var vs_blob: *win32.d3d.IBlob = undefined;
        try win32.hrErrorOnFail(win32.d3dcompiler.D3DCompile(&MSDF_FONT_SHADER_HLSL[0], MSDF_FONT_SHADER_HLSL.len, null, null, null, "vs_main", "vs_5_0", 0, 0, @ptrCast(&vs_blob), null));
        defer _ = vs_blob.Release();

        try win32.hrErrorOnFail(gfx.device.CreateVertexShader(vs_blob.GetBufferPointer(), vs_blob.GetBufferSize(), null, @ptrCast(&font.font_vso)));
        errdefer _ = font.font_vso.Release();

        var ps_blob: *win32.d3d.IBlob = undefined;
        try win32.hrErrorOnFail(win32.d3dcompiler.D3DCompile(&MSDF_FONT_SHADER_HLSL[0], MSDF_FONT_SHADER_HLSL.len, null, null, null, "ps_main", "ps_5_0", 0, 0, @ptrCast(&ps_blob), null));
        defer _ = ps_blob.Release();

        try win32.hrErrorOnFail(gfx.device.CreatePixelShader(ps_blob.GetBufferPointer(), ps_blob.GetBufferSize(), null, @ptrCast(&font.font_pso)));
        errdefer _ = font.font_pso.Release();

        // create vertex input layout
        const vso_input_layout_desc = [_]d3d11.INPUT_ELEMENT_DESC {
            d3d11.INPUT_ELEMENT_DESC {
                .SemanticName = "TEXCOORD",
                .SemanticIndex = 0,
                .Format = win32.dxgi.FORMAT.R32G32B32A32_FLOAT,
                .InputSlot = 0,
                .AlignedByteOffset = d3d11.APPEND_ALIGNED_ELEMENT,
                .InputSlotClass = d3d11.INPUT_CLASSIFICATION.INPUT_PER_INSTANCE_DATA,
                .InstanceDataStepRate = 1,
            },
            d3d11.INPUT_ELEMENT_DESC {
                .SemanticName = "TEXCOORD",
                .SemanticIndex = 1,
                .Format = win32.dxgi.FORMAT.R32G32B32A32_FLOAT,
                .InputSlot = 0,
                .AlignedByteOffset = d3d11.APPEND_ALIGNED_ELEMENT,
                .InputSlotClass = d3d11.INPUT_CLASSIFICATION.INPUT_PER_INSTANCE_DATA,
                .InstanceDataStepRate = 1,
            },
        };
        try win32.hrErrorOnFail(gfx.device.CreateInputLayout(vso_input_layout_desc[0..], vso_input_layout_desc.len, vs_blob.GetBufferPointer(), vs_blob.GetBufferSize(), @ptrCast(&font.vso_input_layout)));
        errdefer _ = font.vso_input_layout.Release();

        // create sampler
        const sampler_desc = d3d11.SAMPLER_DESC {
            .Filter = d3d11.FILTER.MIN_MAG_LINEAR_MIP_POINT,
            .AddressU = d3d11.TEXTURE_ADDRESS_MODE.WRAP,
            .AddressV = d3d11.TEXTURE_ADDRESS_MODE.WRAP,
            .AddressW = d3d11.TEXTURE_ADDRESS_MODE.WRAP,
            .MipLODBias = 0.0,
            .MaxAnisotropy = 1,
            .ComparisonFunc = d3d11.COMPARISON_FUNC.NEVER,
            .BorderColor = [4]win32.w32.FLOAT{0.0, 0.0, 0.0, 1.0},
            .MinLOD = 0.0,
            .MaxLOD = 0.0,
        };
        try win32.hrErrorOnFail(gfx.device.CreateSamplerState(&sampler_desc, @ptrCast(&font.sampler)));
        errdefer _ = font.sampler.Release();

        // create rasterizer state
        var rasterizer_state_desc = d3d11.RASTERIZER_DESC {
            .FillMode = d3d11.FILL_MODE.SOLID,
            .CullMode = d3d11.CULL_MODE.BACK,
            .FrontCounterClockwise = 1,
        };
        try win32.hrErrorOnFail(gfx.device.CreateRasterizerState(&rasterizer_state_desc, @ptrCast(&font.rasterizer_state)));
        errdefer _ = font.rasterizer_state.Release();

        // create blend state
        var blend_state_desc = d3d11.BLEND_DESC {
            .AlphaToCoverageEnable = 0,
            .IndependentBlendEnable = 0,
            .RenderTarget = [_]d3d11.RENDER_TARGET_BLEND_DESC {undefined} ** 8,
        };
        blend_state_desc.RenderTarget[0] = .{
            .BlendEnable = 1,
            .RenderTargetWriteMask = d3d11.COLOR_WRITE_ENABLE.ALL,
            .SrcBlend = d3d11.BLEND.SRC_ALPHA,
            .DestBlend = d3d11.BLEND.INV_SRC_ALPHA,
            .BlendOp = d3d11.BLEND_OP.ADD,
            .SrcBlendAlpha = d3d11.BLEND.ONE,
            .DestBlendAlpha = d3d11.BLEND.ZERO,
            .BlendOpAlpha = d3d11.BLEND_OP.ADD,
        };
        try win32.hrErrorOnFail(gfx.device.CreateBlendState(&blend_state_desc, @ptrCast(&font.blend_state)));
        errdefer _ = font.blend_state.Release();

        // create constant buffers
        const font_constant_buffer_desc = d3d11.BUFFER_DESC {
            .ByteWidth = @sizeOf(FontConstantBuffer),
            .Usage = d3d11.USAGE.DYNAMIC,
            .BindFlags = d3d11.BIND_FLAG { .CONSTANT_BUFFER = true, },
            .CPUAccessFlags = d3d11.CPU_ACCCESS_FLAG { .WRITE = true, },
        };
        try win32.hrErrorOnFail(gfx.device.CreateBuffer(&font_constant_buffer_desc, null, @ptrCast(&font.font_text_buffer)));
        errdefer _ = font.font_text_buffer.Release();

        const character_info_buffer_desc = d3d11.BUFFER_DESC {
            .ByteWidth = @sizeOf(CharacterInfoConstantBuffer) * RENDER_INSTANCE_COUNT,
            .Usage = d3d11.USAGE.DYNAMIC,
            .BindFlags = d3d11.BIND_FLAG { .VERTEX_BUFFER = true, },
            .CPUAccessFlags = d3d11.CPU_ACCCESS_FLAG { .WRITE = true, },
        };
        try win32.hrErrorOnFail(gfx.device.CreateBuffer(&character_info_buffer_desc, null, @ptrCast(&font.character_buffer)));
        errdefer _ = font.character_buffer.Release();

        // finally return the font structure
        return font;
    }

    pub fn deinit(self: *const Font) void {
        _ = self.msdf_texture_view.Release();
        _ = self.blend_state.Release();
        _ = self.rasterizer_state.Release();
        _ = self.font_text_buffer.Release();
        _ = self.character_buffer.Release();
        _ = self.sampler.Release();
        _ = self.vso_input_layout.Release();
        _ = self.font_vso.Release();
        _ = self.font_pso.Release();
    }

    pub const FontRenderProperties2D = struct {
        size: Size = Size {.Pixels = 20},
        colour: zm.F32x4 = zm.f32x4(1.0, 1.0, 1.0, 1.0),
    };

    pub fn render_text_2d(
        self: *Font,
        text: []const u8,
        x_pos: i32,
        y_pos: i32,
        props: FontRenderProperties2D,
        rtv: *d3d11.IRenderTargetView, 
        rtv_width: i32,
        rtv_height: i32,
        gfx: *gfx_d3d11.D3D11State,
    ) void {
        if (text.len == 0) { return; }
        
        const aspect = (@as(f32, @floatFromInt(rtv_width)) / @as(f32, @floatFromInt(rtv_height)));
        var y_loc = ((@as(f32, @floatFromInt(y_pos)) / @as(f32, @floatFromInt(rtv_height))) * 2.0) - 1.0;
        var x_loc = ((@as(f32, @floatFromInt(x_pos)) / @as(f32, @floatFromInt(rtv_width))) * 2.0) - 1.0;
        const x_start_loc = x_loc;

        const screen_size = switch (props.size) {
            .Screen => |v| blk: { break :blk (v * 2.0); },
            .Pixels => |px| blk: {
                const percpx = @as(f32, @floatFromInt(px)) / @as(f32, @floatFromInt(rtv_height));
                break :blk (percpx * 2.0);
            },
        };

        const viewport = d3d11.VIEWPORT {
            .Width = @floatFromInt(rtv_width),
            .Height = @floatFromInt(rtv_height),
            .TopLeftX = 0,
            .TopLeftY = 0,
            .MinDepth = 0.0,
            .MaxDepth = 1.0,
        };
        gfx.context.RSSetViewports(1, @ptrCast(&viewport));

        gfx.context.PSSetShader(self.font_pso, null, 0);
        gfx.context.PSSetShaderResources(0, 1, @ptrCast(&self.msdf_texture_view));

        gfx.context.OMSetRenderTargets(1, @ptrCast(&rtv), null);
        gfx.context.OMSetBlendState(@ptrCast(self.blend_state), null, 0xffffffff);

        gfx.context.VSSetShader(self.font_vso, null, 0);
        gfx.context.IASetInputLayout(null);

        gfx.context.IASetPrimitiveTopology(d3d11.PRIMITIVE_TOPOLOGY.TRIANGLELIST);
        gfx.context.RSSetState(self.rasterizer_state);

        gfx.context.PSSetConstantBuffers(0, 1, @ptrCast(&self.font_text_buffer));
        gfx.context.PSSetSamplers(0, 1, @ptrCast(&self.sampler));

        gfx.context.IASetInputLayout(self.vso_input_layout);
        const stride: c_uint = @sizeOf(CharacterInfoConstantBuffer);
        var offset: c_uint = 0;
        gfx.context.IASetVertexBuffers(0, 1, @ptrCast(&self.character_buffer), @ptrCast(&stride), @ptrCast(&offset));

        { // Setup font text info buffer
            var mapped_subresource: d3d11.MAPPED_SUBRESOURCE = undefined;
            win32.hrPanicOnFail(gfx.context.Map(@ptrCast(self.font_text_buffer), 0, d3d11.MAP.WRITE_DISCARD, d3d11.MAP_FLAG{}, @ptrCast(&mapped_subresource)));
            defer gfx.context.Unmap(@ptrCast(self.font_text_buffer), 0);

            const buffer_data: *FontConstantBuffer = @ptrCast(@alignCast(mapped_subresource.pData));
            buffer_data.* = FontConstantBuffer {
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
                var mapped_subresource: d3d11.MAPPED_SUBRESOURCE = undefined;
                win32.hrPanicOnFail(gfx.context.Map(@ptrCast(self.character_buffer), 0, d3d11.MAP.WRITE_DISCARD, d3d11.MAP_FLAG{}, @ptrCast(&mapped_subresource)));
                defer gfx.context.Unmap(@ptrCast(self.character_buffer), 0);

                var buffer_data: *([RENDER_INSTANCE_COUNT]CharacterInfoConstantBuffer) = @ptrCast(@alignCast(mapped_subresource.pData));
                while (instance_count < RENDER_INSTANCE_COUNT and (text_offset + instance_count) < text.len) {
                    const c = text[text_offset + instance_count];

                    // reset data in this instance
                    buffer_data[instance_count].quad_bounds = .{};
                    buffer_data[instance_count].atlas_bounds = .{};

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
                            buffer_data[instance_count].quad_bounds = quad_bounds;
                            buffer_data[instance_count].atlas_bounds = char_info.atlas_bounds;

                            x_loc += (char_info.advance / aspect) * screen_size;
                        },
                    }

                    instance_count += 1;
                }
            }

            gfx.context.DrawInstanced(6, instance_count, 0, 0);
            text_offset += instance_count;
        }
    }

    pub fn text_bounds_2d(
        self: *Font,
        text: []const u8,
        x_pos: i32,
        y_pos: i32,
        props: FontRenderProperties2D,
        rtv_width: i32,
        rtv_height: i32,
    ) ?Rect {
        if (text.len == 0) { return null; }

        _ = rtv_width;
        const screen_size = switch (props.size) {
            .Screen => |v| blk: { break :blk (v * 2.0); },
            .Pixels => |px| blk: {
                const percpx = @as(f32, @floatFromInt(px)) / @as(f32, @floatFromInt(rtv_height));
                break :blk (percpx * 2.0);
            },
        };
        const pixel_height = (screen_size / 2.0) * @as(f32, @floatFromInt(rtv_height));
        
        var y_loc = @as(f32, @floatFromInt(y_pos));
        var x_loc = @as(f32, @floatFromInt(x_pos));
        const x_start_loc = x_loc;

        var max_x = x_loc;
        for (text) |c| {
            switch (c) {
                '\n' => {
                    x_loc = x_start_loc;
                    y_loc -= self.font_metrics.line_height * pixel_height;
                },
                else => {
                    const char_info = &self.ascii_character_map[@intCast(c)];

                    x_loc += char_info.advance * pixel_height;
                    max_x = @max(max_x, x_loc);
                },
            }
        }

        return Rect {
            .left = @as(f32, @floatFromInt(x_pos)),
            .right = max_x,
            .top = @as(f32, @floatFromInt(y_pos)) + self.font_metrics.ascender * pixel_height,
            .bottom = y_loc + self.font_metrics.descender * pixel_height,
        };
    }
};

