const std = @import("std");
const zwin32 = @import("zwin32");
const gf = @import("gfx.zig");

// Implements COD: Advanced warfare physically based bloom
// https://learnopengl.com/Guest-Articles/2022/Phys.-Based-Bloom
pub const BloomFilter = struct {
    const MIP_LEVELS: u32 = 5;

    const ConstantBufferData = extern struct {
        resolution_or_radius: [4]f32,
    };

    full_screen_quad_vertex_shader: gf.VertexShader,
    downsample_pixel_shader: gf.PixelShader,
    sampler: gf.Sampler,
    upsample_pixel_shader: gf.PixelShader,
    constant_buffer: gf.Buffer,

    bloom_mip_textures: [2]struct {
        texture: gf.Texture2D,
        view: gf.TextureView2D,
        rtv: [MIP_LEVELS]gf.RenderTargetView,
    },

    pub fn deinit(self: *BloomFilter) void {
        self.deinit_mip_texture();
        self.full_screen_quad_vertex_shader.deinit();
        self.downsample_pixel_shader.deinit();
        self.sampler.deinit();
        self.upsample_pixel_shader.deinit();
        self.constant_buffer.deinit();
    }

    pub fn init(gfx: *gf.GfxState) !BloomFilter {
        var full_screen_quad_vertex_shader = try gf.VertexShader.init_buffer(
            FULL_SCREEN_QUAD_VS,
            "vs_main",
            ([0]gf.VertexInputLayoutEntry {})[0..],
            gfx.device
        );
        errdefer full_screen_quad_vertex_shader.deinit();

        var downsample_pixel_shader = try gf.PixelShader.init_buffer(
            FULL_SCREEN_QUAD_VS ++ BLOOM_DOWNSAMPLE_HLSL,
            "ps_main",
            gfx.device
        );
        errdefer downsample_pixel_shader.deinit();

        var upsample_pixel_shader = try gf.PixelShader.init_buffer(
            FULL_SCREEN_QUAD_VS ++ BLOOM_UPSAMPLE_HLSL,
            "ps_main",
            gfx.device
        );
        errdefer upsample_pixel_shader.deinit();

        var sampler = try gf.Sampler.init(
            .{
                .filter_min_mag = .Linear,
                .max_lod = @floatFromInt(MIP_LEVELS - 1),
            },
            gfx.device
        );
        errdefer sampler.deinit();

        var constant_buffer = try gf.Buffer.init(
            @sizeOf(ConstantBufferData),
            .{ .ConstantBuffer = true, },
            .{ .CpuWrite = true, },
            gfx.device
        );
        errdefer constant_buffer.deinit();

        var bloom_filter = BloomFilter {
            .full_screen_quad_vertex_shader = full_screen_quad_vertex_shader,
            .downsample_pixel_shader = downsample_pixel_shader,
            .sampler = sampler,
            .upsample_pixel_shader = upsample_pixel_shader,
            .constant_buffer = constant_buffer,
            .bloom_mip_textures = undefined,
        };
        try bloom_filter.init_mip_texture(gfx);

        return bloom_filter;
    }

    fn deinit_mip_texture(self: *BloomFilter) void {
        for (self.bloom_mip_textures[0..]) |*t| {
            t.texture.deinit();
            t.view.deinit();
            for (t.rtv[0..]) |*r| {
                r.deinit();
            }
        }
    }

    fn init_mip_texture(self: *BloomFilter, gfx: *gf.GfxState) !void {
        // generate two sets of textures, views, and render target views.
        // we need to flipflop between two sets as a single texture cannot be
        // bound to both a shader resource and a render target at the same time.
        for (self.bloom_mip_textures[0..]) |*t| {
            // Use texture mips to store downsample and upscale images
            t.texture = try gf.Texture2D.init(
                .{
                    .width = @intCast(gfx.swapchain_size.width),
                    .height = @intCast(gfx.swapchain_size.height),
                    .format = gf.TextureFormat.Rg11b10_Float,
                    .mip_levels = MIP_LEVELS,
                },
                .{ .ShaderResource = true, .RenderTarget = true, },
                .{ .GpuWrite = true, },
                null,
                gfx.device
            );

            t.view = try gf.TextureView2D.init_from_texture2d(&t.texture, gfx.device);

            // create a render target view for each mip level
            for (t.rtv[0..], 0..) |*r, mip_level| {
                r.* = try gf.RenderTargetView.init_from_texture2d_mip(&t.texture, @intCast(mip_level), gfx.device);
            }
        }
    }

    pub fn framebuffer_resized(self: *BloomFilter, gfx: *gf.GfxState) !void {
        self.deinit_mip_texture();
        try self.init_mip_texture(gfx);
    }

    pub fn get_bloom_view(self: *const BloomFilter) *const gf.TextureView2D {
        return &self.bloom_mip_textures[0].view;
    }

    pub fn render_bloom_texture(
        self: *const BloomFilter,
        hdr_source_view: *gf.TextureView2D,
        filter_radius: f32,
        gfx: *gf.GfxState,
    ) void {
        var hdr_source: *const gf.TextureView2D = hdr_source_view;
        var rtv: *const [MIP_LEVELS]gf.RenderTargetView = &self.bloom_mip_textures[0].rtv;

        // Downsample
        gfx.context.OMSetBlendState(null, null, 0xffffffff);
        gfx.context.RSSetState(@ptrCast(gfx.rasterization_state(.{ .FillBack = false, .FrontCounterClockwise = true, }).state));
        gfx.context.VSSetShader(@ptrCast(self.full_screen_quad_vertex_shader.vso), null, 0);
        gfx.context.PSSetShader(@ptrCast(self.downsample_pixel_shader.pso), null, 0);
        gfx.context.PSSetSamplers(0, 1, @ptrCast(&self.sampler.sampler));
        gfx.context.PSSetConstantBuffers(0, 1, @ptrCast(&self.constant_buffer.buffer));
        gfx.context.IASetPrimitiveTopology(zwin32.d3d11.PRIMITIVE_TOPOLOGY.TRIANGLELIST);
        for (0..MIP_LEVELS) |mip_level| {
            const mip_level_minus_one = @max(@as(i32, @intCast(mip_level)) - 1, 0);
            {
                var mapped_buffer = self.constant_buffer.map(ConstantBufferData, gfx.context) catch unreachable;
                defer mapped_buffer.unmap();
                mapped_buffer.data.resolution_or_radius[0] = 1.0 / @as(f32, @floatFromInt(rtv[mip_level_minus_one].size.width));
                mapped_buffer.data.resolution_or_radius[1] = 1.0 / @as(f32, @floatFromInt(rtv[mip_level_minus_one].size.height));
                mapped_buffer.data.resolution_or_radius[2] = @floatFromInt(mip_level_minus_one);
            }

            const viewport = zwin32.d3d11.VIEWPORT {
                .Width = @floatFromInt(rtv[mip_level].size.width),
                .Height = @floatFromInt(rtv[mip_level].size.height),
                .TopLeftX = 0.0,
                .TopLeftY = 0.0,
                .MinDepth = 0.0,
                .MaxDepth = 0.0,
            };

            gfx.context.OMSetRenderTargets(1, @ptrCast(&rtv[mip_level].view), null);
            gfx.context.RSSetViewports(1, @ptrCast(&viewport));
            gfx.context.PSSetShaderResources(0, 1, @ptrCast(&hdr_source.view));

            gfx.context.Draw(6, 0);

            // unset hdr texture so it can be used as rtv again
            gfx.context.PSSetShaderResources(0, 1, @ptrCast(&([1]?*zwin32.d3d11.IShaderResourceView{null})));

            hdr_source = &self.bloom_mip_textures[mip_level % 2].view;
            rtv = &self.bloom_mip_textures[(mip_level + 1) % 2].rtv;
        }

        // Upsample
        gfx.context.OMSetBlendState(null, null, 0xffffffff);
        gfx.context.RSSetState(@ptrCast(gfx.rasterization_state(.{ .FillBack = false, .FrontCounterClockwise = true, }).state));
        gfx.context.VSSetShader(@ptrCast(self.full_screen_quad_vertex_shader.vso), null, 0);
        gfx.context.PSSetShader(@ptrCast(self.upsample_pixel_shader.pso), null, 0);
        gfx.context.PSSetSamplers(0, 1, @ptrCast(&self.sampler.sampler));
        gfx.context.PSSetConstantBuffers(0, 1, @ptrCast(&self.constant_buffer.buffer));
        gfx.context.IASetPrimitiveTopology(zwin32.d3d11.PRIMITIVE_TOPOLOGY.TRIANGLELIST);
        for (1..MIP_LEVELS) |inv_mip_level| {
            const mip_level = MIP_LEVELS - inv_mip_level - 1;

            hdr_source = &self.bloom_mip_textures[(mip_level + 1) % 2].view;
            rtv = &self.bloom_mip_textures[mip_level % 2].rtv;

            const viewport = zwin32.d3d11.VIEWPORT {
                .Width = @floatFromInt(rtv[mip_level].size.width),
                .Height = @floatFromInt(rtv[mip_level].size.height),
                .TopLeftX = 0.0,
                .TopLeftY = 0.0,
                .MinDepth = 0.0,
                .MaxDepth = 0.0,
            };
            
            {
                var mapped_buffer = self.constant_buffer.map(ConstantBufferData, gfx.context) catch unreachable;
                defer mapped_buffer.unmap();
                mapped_buffer.data.resolution_or_radius[0] = filter_radius;
                mapped_buffer.data.resolution_or_radius[1] = @floatFromInt(mip_level + 1);
                mapped_buffer.data.resolution_or_radius[2] = viewport.Width / viewport.Height;
            }

            gfx.context.OMSetRenderTargets(1, @ptrCast(&rtv[mip_level].view), null);
            gfx.context.RSSetViewports(1, @ptrCast(&viewport));
            gfx.context.PSSetShaderResources(0, 1, @ptrCast(&hdr_source.view));

            gfx.context.Draw(6, 0);

            // unset hdr texture so it can be used as rtv again
            gfx.context.PSSetShaderResources(0, 1, @ptrCast(&([1]?*zwin32.d3d11.IShaderResourceView{null})));
        }
    }
};

const FULL_SCREEN_QUAD_VS = @embedFile("full_screen_quad_vs.hlsl");

const BLOOM_DOWNSAMPLE_HLSL = \\
\\  cbuffer camera_data : register(b0)
\\  {
\\      float2 src_texel_size;
\\      float mip_level;
\\      float unused;
\\  }
\\
\\  Texture2D src_buffer;
\\  SamplerState src_sampler;
\\
\\  float4 ps_main(vs_out input) : SV_TARGET
\\  {
\\      float x = src_texel_size.x;
\\      float y = src_texel_size.y;
\\
//      // Take 13 samples around current texel:
//      // a - b - c
//      // - j - k -
//      // d -[e]- f
//      // - l - m -
//      // g - h - i
\\      float3 a = src_buffer.SampleLevel(src_sampler, float2(input.uv.x - 2*x, input.uv.y + 2*y), mip_level).rgb;
\\      float3 b = src_buffer.SampleLevel(src_sampler, float2(input.uv.x,       input.uv.y + 2*y), mip_level).rgb;
\\      float3 c = src_buffer.SampleLevel(src_sampler, float2(input.uv.x + 2*x, input.uv.y + 2*y), mip_level).rgb;
\\
\\      float3 d = src_buffer.SampleLevel(src_sampler, float2(input.uv.x - 2*x, input.uv.y), mip_level).rgb;
\\      float3 e = src_buffer.SampleLevel(src_sampler, float2(input.uv.x,       input.uv.y), mip_level).rgb;
\\      float3 f = src_buffer.SampleLevel(src_sampler, float2(input.uv.x + 2*x, input.uv.y), mip_level).rgb;
\\
\\      float3 g = src_buffer.SampleLevel(src_sampler, float2(input.uv.x - 2*x, input.uv.y - 2*y), mip_level).rgb;
\\      float3 h = src_buffer.SampleLevel(src_sampler, float2(input.uv.x,       input.uv.y - 2*y), mip_level).rgb;
\\      float3 i = src_buffer.SampleLevel(src_sampler, float2(input.uv.x + 2*x, input.uv.y - 2*y), mip_level).rgb;
\\
\\      float3 j = src_buffer.SampleLevel(src_sampler, float2(input.uv.x - x, input.uv.y + y), mip_level).rgb;
\\      float3 k = src_buffer.SampleLevel(src_sampler, float2(input.uv.x + x, input.uv.y + y), mip_level).rgb;
\\      float3 l = src_buffer.SampleLevel(src_sampler, float2(input.uv.x - x, input.uv.y - y), mip_level).rgb;
\\      float3 m = src_buffer.SampleLevel(src_sampler, float2(input.uv.x + x, input.uv.y - y), mip_level).rgb;
\\
//      // Apply weighted distribution
\\      float3 downsample    = e*0.125;
\\      downsample          += (a+c+g+i)*0.03125;
\\      downsample          += (b+d+f+h)*0.0625;
\\      downsample          += (j+k+l+m)*0.125;
\\
\\      return float4(downsample, 1.0);
\\  }
;

const BLOOM_UPSAMPLE_HLSL = \\
\\  cbuffer camera_data : register(b0)
\\  {
\\      float filter_radius;
\\      float mip_level;
\\      float aspect_ratio;
\\      float unused;
\\  }
\\
\\  Texture2D src_buffer;
\\  SamplerState src_sampler;
\\
\\  float4 ps_main(vs_out input) : SV_TARGET
\\  {
\\      float x = filter_radius;
\\      float y = filter_radius * aspect_ratio;
\\  
//      // a - b - c
//      // d -[e]- f
//      // g - h - i
\\      float3 a = src_buffer.SampleLevel(src_sampler, float2(input.uv.x - x, input.uv.y + y), mip_level).rgb;
\\      float3 b = src_buffer.SampleLevel(src_sampler, float2(input.uv.x,     input.uv.y + y), mip_level).rgb;
\\      float3 c = src_buffer.SampleLevel(src_sampler, float2(input.uv.x + x, input.uv.y + y), mip_level).rgb;
\\  
\\      float3 d = src_buffer.SampleLevel(src_sampler, float2(input.uv.x - x, input.uv.y), mip_level).rgb;
\\      float3 e = src_buffer.SampleLevel(src_sampler, float2(input.uv.x,     input.uv.y), mip_level).rgb;
\\      float3 f = src_buffer.SampleLevel(src_sampler, float2(input.uv.x + x, input.uv.y), mip_level).rgb;
\\  
\\      float3 g = src_buffer.SampleLevel(src_sampler, float2(input.uv.x - x, input.uv.y - y), mip_level).rgb;
\\      float3 h = src_buffer.SampleLevel(src_sampler, float2(input.uv.x,     input.uv.y - y), mip_level).rgb;
\\      float3 i = src_buffer.SampleLevel(src_sampler, float2(input.uv.x + x, input.uv.y - y), mip_level).rgb;
\\  
//      // Apply weighted distribution, by using a 3x3 tent filter
\\      float3 upsample = e*4.0;
\\      upsample += (b+d+f+h)*2.0;
\\      upsample += (a+c+g+i);
\\      upsample *= 1.0 / 16.0;
\\
\\      return float4(upsample, 1.0);
\\  }
;
