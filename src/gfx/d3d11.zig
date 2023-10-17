const std = @import("std");
const builtin = @import("builtin");
const zwin32 = @import("zwin32");
const d3d11 = zwin32.d3d11;
const hrErr = zwin32.hrErrorOnFail;

inline fn is_dbg() bool {
    return (builtin.mode == std.builtin.Mode.Debug);
}

pub const D3D11State = struct {
    const Self = @This();

    device: *d3d11.IDevice,
    swapchain: *zwin32.dxgi.ISwapChain,
    context: *d3d11.IDeviceContext,

    const enable_debug_layers = true;

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

    pub fn init(window: zwin32.w32.HWND) !Self {
        const accepted_feature_levels = [_]zwin32.d3d.FEATURE_LEVEL{
            .@"11_0", 
            .@"10_1" 
        };

        const swapchain_desc = zwin32.dxgi.SWAP_CHAIN_DESC {
            .BufferDesc = zwin32.dxgi.MODE_DESC {
                .Width = 1280,
                .Height = 720,
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
            .BufferCount = 3,
            .OutputWindow = window,
            .Windowed = zwin32.w32.TRUE,
            .SwapEffect = zwin32.dxgi.SWAP_EFFECT.FLIP_DISCARD,
            .Flags = zwin32.dxgi.SWAP_CHAIN_FLAG {
                .ALLOW_MODE_SWITCH = true,
                .ALLOW_TEARING = true, // This is not a UWP app
            }
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

        return Self {
            .device = device,
            .swapchain = swapchain,
            .context = context,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self.context.Release();
        _ = self.swapchain.Release();
        _ = self.device.Release();

    }

    pub fn window_resized(self: *Self) !void {
        _ = self;
        std.log.info("GFX resize", .{});
        // try hrErr(self.swapchain.ResizeBuffers(
        //         0, 0, 0, zwin32.dxgi.FORMAT.UNKNOWN, // automatic
        //         zwin32.dxgi.SWAP_CHAIN_FLAG {
        //             .ALLOW_MODE_SWITCH = true,
        //             .ALLOW_TEARING = true,
        //         })); 
    }
};

