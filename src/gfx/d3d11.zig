const std = @import("std");
const builtin = @import("builtin");
const zwin32 = @import("zwin32");
const d3d11 = zwin32.d3d11;
const hrErr = zwin32.hrErrorOnFail;

const win32window = @import("../platform/windows.zig");

inline fn is_dbg() bool {
    return (builtin.mode == std.builtin.Mode.Debug);
}

pub const D3D11State = struct {
    const Self = @This();

    device: *d3d11.IDevice,
    swapchain: *zwin32.dxgi.ISwapChain,
    context: *d3d11.IDeviceContext,
    rtv: *d3d11.IRenderTargetView,

    swapchain_flags: zwin32.dxgi.SWAP_CHAIN_FLAG,
    swapchain_size: struct{width: i32, height: i32},

    const enable_debug_layers = true;
    const swapchain_buffer_count: u32 = 3;

    fn attempt_create_device_and_swapchain(
        accepted_feature_levels: []const zwin32.d3d.FEATURE_LEVEL,
        swapchain_desc: zwin32.dxgi.SWAP_CHAIN_DESC,
        swapchain: ?*?*zwin32.dxgi.ISwapChain,
        device: ?*?*d3d11.IDevice,
        feature_level: ?*zwin32.d3d.FEATURE_LEVEL,
        context: ?*?*d3d11.IDeviceContext,
    ) !void {
        try hrErr(d3d11.D3D11CreateDeviceAndSwapChain(
                null,
                zwin32.d3d.DRIVER_TYPE.HARDWARE, 
                null,
                zwin32.d3d11.CREATE_DEVICE_FLAG {
                    .DEBUG = (is_dbg() and enable_debug_layers),
                    .BGRA_SUPPORT = true,
                    .PREVENT_ALTERING_LAYER_SETTINGS_FROM_REGISTRY = !is_dbg(),
                }, 
                accepted_feature_levels.ptr,
                @intCast(accepted_feature_levels.len),
                d3d11.SDK_VERSION,
                &swapchain_desc, 
                swapchain,
                device,
                feature_level,
                context
        ));
    }

    pub fn init(window: *win32window.Win32Window) !Self {
        const accepted_feature_levels = [_]zwin32.d3d.FEATURE_LEVEL{
            .@"11_0", 
            .@"10_1" 
        };

        var window_size = try window.get_client_size();

        const swapchain_flags = zwin32.dxgi.SWAP_CHAIN_FLAG {
            .ALLOW_MODE_SWITCH = true,
            .ALLOW_TEARING = true,
        };

        const swapchain_desc = zwin32.dxgi.SWAP_CHAIN_DESC {
            .BufferDesc = zwin32.dxgi.MODE_DESC {
                .Width = @intCast(window_size.width),
                .Height = @intCast(window_size.height),
                .Format = zwin32.dxgi.FORMAT.B8G8R8A8_UNORM,
                .Scaling = zwin32.dxgi.MODE_SCALING.STRETCHED,
                .RefreshRate = zwin32.dxgi.RATIONAL{
                    .Numerator = 0,
                    .Denominator = 1,
                },
                .ScanlineOrdering = zwin32.dxgi.MODE_SCANLINE_ORDER.UNSPECIFIED,
            },
            .SampleDesc = zwin32.dxgi.SAMPLE_DESC {
                .Count = 1,
                .Quality = 0,
            },
            .BufferUsage = zwin32.dxgi.USAGE {
                .RENDER_TARGET_OUTPUT = true,
            },
            .BufferCount = swapchain_buffer_count,
            .OutputWindow = window.hwnd,
            .Windowed = zwin32.w32.TRUE,
            .SwapEffect = zwin32.dxgi.SWAP_EFFECT.FLIP_DISCARD,
            .Flags = swapchain_flags,
        };

        var device: *d3d11.IDevice = undefined;
        var swapchain: *zwin32.dxgi.ISwapChain = undefined;
        var feature_level = zwin32.d3d.FEATURE_LEVEL.@"1_0_CORE";
        var context: *d3d11.IDeviceContext = undefined;

        // Attempt to create the device and swapchain with feature level 11_1.
        attempt_create_device_and_swapchain(
            &[_]zwin32.d3d.FEATURE_LEVEL{ .@"11_1" },
            swapchain_desc,
            @ptrCast(&swapchain),
            @ptrCast(&device),
            @ptrCast(&feature_level),
            @ptrCast(&context)
        ) catch |err| {
            std.log.warn("Failed to create at feature level 11_1", .{});
            // If 11_1 is not available the above call will fail, then try creating at other levels
            if (err == zwin32.w32.Error.INVALIDARG) {
                std.log.warn("Recreating at a lower level", .{});
                try attempt_create_device_and_swapchain(
                    accepted_feature_levels[0..], 
                    swapchain_desc,
                    @ptrCast(&swapchain),
                    @ptrCast(&device),
                    @ptrCast(&feature_level),
                    @ptrCast(&context)); 
            } else {
                return err;
            }
        };

        std.log.info("Swapchain, device, context created! at level: {}", .{feature_level});

        var framebuffer: *d3d11.ITexture2D = undefined;
        try hrErr(swapchain.GetBuffer(0, &d3d11.IID_ITexture2D, @ptrCast(&framebuffer)));
        defer _ = framebuffer.Release();

        var rtv: *d3d11.IRenderTargetView = undefined;
        try hrErr(device.CreateRenderTargetView(
                @ptrCast(framebuffer), 
                &d3d11.RENDER_TARGET_VIEW_DESC{
                    .ViewDimension = d3d11.RTV_DIMENSION.TEXTURE2D,
                    .Format = .@"UNKNOWN",
                    .u = .{.Texture2D = d3d11.TEX2D_RTV {
                        .MipSlice = 0,
                    }},
                }, 
                @ptrCast(&rtv)
        ));

        return Self {
            .device = device,
            .swapchain = swapchain,
            .swapchain_flags = swapchain_flags,
            .swapchain_size = .{.width = window_size.width, .height = window_size.height},
            .context = context,
            .rtv = rtv,
        };
    }

    pub fn deinit(self: *Self) void {
        std.log.debug("D3D11 deinit", .{});
        self.context.Flush();
        _ = self.rtv.Release();
        _ = self.swapchain.Release();
        _ = self.context.Release();
        _ = self.device.Release();
    }

    pub fn begin_frame(self: *Self) !*d3d11.IRenderTargetView {
        return self.rtv;
    }

    pub fn end_frame(self: *Self, rtv: *d3d11.IRenderTargetView) !void {
        _ = rtv;
        try hrErr(self.swapchain.Present(1, zwin32.dxgi.PRESENT_FLAG {}));
    }

    pub fn window_resized(self: *Self, new_width: i32, new_height: i32) void {
        // Release help render target view before we update the swapchain.
        // If we dont do this swapchain resize buffers will fail.
        _ = self.rtv.Release();

        zwin32.hrPanicOnFail(self.swapchain.ResizeBuffers(
                0, 0, 0, zwin32.dxgi.FORMAT.UNKNOWN, // automatic
                self.swapchain_flags)); 

        // Reacquire render target view from new swapchain
        var framebuffer: *d3d11.ITexture2D = undefined;
        zwin32.hrPanicOnFail(self.swapchain.GetBuffer(0, &d3d11.IID_ITexture2D, @ptrCast(&framebuffer)));
        defer _ = framebuffer.Release();

        zwin32.hrPanicOnFail(self.device.CreateRenderTargetView(
                @ptrCast(framebuffer), 
                &d3d11.RENDER_TARGET_VIEW_DESC{
                    .ViewDimension = d3d11.RTV_DIMENSION.TEXTURE2D,
                    .Format = .@"UNKNOWN",
                    .u = .{.Texture2D = d3d11.TEX2D_RTV {
                        .MipSlice = 0,
                    }},
                }, 
                @ptrCast(&self.rtv)
        ));

        // Update swapchain size variables
        self.swapchain_size.width = new_width;
        self.swapchain_size.height = new_height;
    }

    pub fn swapchain_aspect(self: *Self) f32 {
        return @as(f32, @floatFromInt(self.swapchain_size.width)) / @as(f32, @floatFromInt(self.swapchain_size.height));
    }
};

