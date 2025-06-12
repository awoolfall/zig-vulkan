const vk = @import("vulkan_import.zig");
const c = vk.c;
const vkt = @import("vulkan_error.zig").vulkan_result_to_zig_error;
const std = @import("std");
const zm = @import("zmath");
const eng = @import("self");
const slang = @import("slang");
const gf = eng.gfx;
const pl = eng.platform;
const Rect = eng.Rect;


pub const GfxStateVulkan = struct {
    const Self = @This();

    pub const VertexShader = VertexShaderVulkan;
    pub const PixelShader = PixelShaderVulkan;
    pub const HullShader = HullShaderVulkan;
    pub const DomainShader = DomainShaderVulkan;
    pub const GeometryShader = GeometryShaderVulkan;
    pub const ComputeShader = ComputeShaderVulkan;
    pub const Buffer = BufferVulkan;
    pub const Texture2D = Texture2DVulkan;
    pub const TextureView2D = TextureView2DVulkan;
    pub const Texture3D = Texture3DVulkan;
    pub const TextureView3D = TextureView3DVulkan;
    pub const RenderTargetView = RenderTargetViewVulkan;
    pub const DepthStencilView = DepthStencilViewVulkan;
    pub const RasterizationState = RasterizationStateVulkan;
    pub const Sampler = SamplerVulkan;
    pub const BlendState = BlendStateVulkan;
    pub const GraphicsPipeline = GraphicsPipelineVulkan;
    pub const ShaderResourceView = u32;//d3d11.IShaderResourceView;
    pub const UnorderedAccessView = u32;//d3d11.IUnorderedAccessView;

    const VkQueues = struct {
        all: c.VkQueue,
        all_family_index: u32,
        present: c.VkQueue,
        present_family_index: u32,
        cpu_gpu_transfer: c.VkQueue,
        cpu_gpu_transfer_family_index: u32,

        pub inline fn has_distinct_transfer_queue(self: *const VkQueues) bool {
            return (self.all_family_index != self.cpu_gpu_transfer_family_index);
        }
    };

    const SwapchainInfo = struct {
        swapchain: c.VkSwapchainKHR,
        images: std.ArrayList(c.VkImage),
        image_views: std.ArrayList(c.VkImageView),

        extent: c.VkExtent2D,
        format: c.VkSurfaceFormatKHR,
        present_mode: c.VkPresentModeKHR,

        pub fn deinit(self: *@This(), vk_device: c.VkDevice) void {
            for (self.image_views.items) |iv| {
                c.vkDestroyImageView(vk_device, iv, null);
            }
            self.image_views.deinit();
            self.images.deinit();
            c.vkDestroySwapchainKHR(vk_device, self.swapchain, null);
        }
    };

    alloc: std.mem.Allocator,

    // @TODO move this to assets?
    slang_global: ?*slang.c.SlangGlobal,

    vk_version: u32,
    instance: c.VkInstance,
    surface: c.VkSurfaceKHR,
    physical_device: c.VkPhysicalDevice,
    device: c.VkDevice,
    queues: VkQueues,

    all_command_pool: c.VkCommandPool,
    transfer_command_pool: c.VkCommandPool,

    swapchain: SwapchainInfo,

    pub fn deinit(self: *Self) void {
        vkt(c.vkDeviceWaitIdle(self.device)) catch |err| {
            std.log.err("Unable to wait for device idle: {}", .{err});
        };
        //c.vkDestroyCommandPool(self.device, vk_command_pool, null);
        
        self.swapchain.deinit(self.device);

        c.vkDestroyCommandPool(self.device, self.all_command_pool, null);
        c.vkDestroyCommandPool(self.device, self.transfer_command_pool, null);
        c.vkDestroyDevice(self.device, null);
        c.vkDestroySurfaceKHR(self.instance, self.surface, null);
        c.vkDestroyInstance(self.instance, null);

        slang.c.deinitialise(self.slang_global);
    }

    pub fn init(alloc: std.mem.Allocator, window: *pl.Window) !Self {
        // @TODO move this to assets?
        const slang_global = slang.c.initialise();
        errdefer slang.c.deinitialise(slang_global);

        var vk_version: u32 = 0;
        try vkt(c.vkEnumerateInstanceVersion(&vk_version));
        std.log.info("vulkan version is {}.{}.{}", .{
            c.VK_API_VERSION_MAJOR(vk_version),
            c.VK_API_VERSION_MINOR(vk_version),
            c.VK_API_VERSION_VARIANT(vk_version),
        });

        var instance_extensions = std.ArrayList([*c]const u8).init(alloc);
        defer instance_extensions.deinit();

        try instance_extensions.append(c.VK_KHR_SURFACE_EXTENSION_NAME);
        if (@import("builtin").os.tag == .windows) {
            try instance_extensions.append(c.VK_KHR_WIN32_SURFACE_EXTENSION_NAME);
        }

        const create_instance_info = c.VkInstanceCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = @intCast(instance_extensions.items.len),
            .ppEnabledExtensionNames = @ptrCast(instance_extensions.items.ptr),
            .flags = 0,// | c.VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR,
            .pApplicationInfo = null,
            .pNext = null,
        };

        var vk_instance: c.VkInstance = undefined;
        try vkt(c.vkCreateInstance(&create_instance_info, null, &vk_instance));
        errdefer c.vkDestroyInstance(vk_instance, null);

        var vk_surface: c.VkSurfaceKHR = undefined;
        switch (@import("builtin").os.tag) {
            .windows => {
                const surface_create_info = vk.VkWin32SurfaceCreateInfoKHR {
                    .sType = c.VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR,
                    .hwnd = window.hwnd,
                    .hinstance = window.hInstance,
                };
                // const surface_create_info = c.VkWin32SurfaceCreateInfoKHR{
                //     .sType = c.VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR,
                //     // .hwnd = @ptrCast(@alignCast(window.hwnd)),
                //     // .hinstance = @ptrCast(@alignCast(window.hInstance)),
                //     .hwnd = @alignCast(@ptrCast(@as(*align(@alignOf(c.HWND)) *anyopaque, @alignCast(@ptrCast(window.hwnd))))),
                //     .hinstance = @alignCast(@ptrCast(@as(*align(@alignOf(c.HINSTANCE)) *anyopaque, @alignCast(@ptrCast(window.hInstance))))),
                // };
                try vkt(c.vkCreateWin32SurfaceKHR(vk_instance, @ptrCast(&surface_create_info), null, &vk_surface));
            },
            else => @compileError("Platform not implemented"),
        }
        errdefer c.vkDestroySurfaceKHR(vk_instance, vk_surface, null);

        var device_extensions = std.ArrayList([*c]const u8).init(alloc);
        defer device_extensions.deinit();

        try device_extensions.append(c.VK_KHR_SWAPCHAIN_EXTENSION_NAME);

        var physical_device_count: u32 = 0;
        try vkt(c.vkEnumeratePhysicalDevices(vk_instance, &physical_device_count, null));

        const physical_device_storage = try alloc.alloc(c.VkPhysicalDevice, physical_device_count);
        defer alloc.free(physical_device_storage);
        try vkt(c.vkEnumeratePhysicalDevices(vk_instance, &physical_device_count, physical_device_storage.ptr));

        var best_physical_device_idx: usize = std.math.maxInt(usize);
        std.log.info("Available physical devices:", .{});
        for (physical_device_storage, 0..) |physical_device, idx| {
            var props: c.VkPhysicalDeviceProperties = undefined;
            c.vkGetPhysicalDeviceProperties(physical_device, &props);
            std.log.info("- {s}", .{std.mem.sliceTo(&props.deviceName, 0)});

            var physical_device_extension_count: u32 = undefined;
            vkt(c.vkEnumerateDeviceExtensionProperties(physical_device, null, &physical_device_extension_count, null))
                catch continue;

            const physical_device_extension_storage = try alloc.alloc(c.VkExtensionProperties, physical_device_extension_count);
            defer alloc.free(physical_device_extension_storage);
            vkt(c.vkEnumerateDeviceExtensionProperties(physical_device, null, &physical_device_extension_count, physical_device_extension_storage.ptr))
                catch continue;

            const found_all_required_extensions = extension_check: {
                for (device_extensions.items) |required_extension| {
                    var found = false;
                    for (physical_device_extension_storage) |available_extension| {
                        if (std.mem.eql(u8, std.mem.sliceTo(required_extension, 0), std.mem.sliceTo(&available_extension.extensionName, 0))) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        break :extension_check false;
                    }
                }
                break :extension_check true;
            };

            if (!found_all_required_extensions) {
                std.log.info("  - doesn't satisfy all required extensions", .{});
                continue;
            }

            var surface_capabilities: c.VkSurfaceCapabilitiesKHR = undefined;
            vkt(c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, vk_surface, &surface_capabilities))
                catch continue;

            var surface_fomats_count: u32 = 0;
            vkt(c.vkGetPhysicalDeviceSurfaceFormatsKHR(physical_device, vk_surface, &surface_fomats_count, null))
                catch continue;

            const surface_formats = try alloc.alloc(c.VkSurfaceFormatKHR, surface_fomats_count);
            defer alloc.free(surface_formats);
            vkt(c.vkGetPhysicalDeviceSurfaceFormatsKHR(physical_device, vk_surface, &surface_fomats_count, surface_formats.ptr))
                catch continue;

            var surface_present_modes_count: u32 = 0;
            vkt(c.vkGetPhysicalDeviceSurfacePresentModesKHR(physical_device, vk_surface, &surface_present_modes_count, null))
                catch continue;

            const surface_present_modes = try alloc.alloc(c.VkPresentModeKHR, surface_present_modes_count);
            defer alloc.free(surface_present_modes);
            vkt(c.vkGetPhysicalDeviceSurfacePresentModesKHR(physical_device, vk_surface, &surface_present_modes_count, surface_present_modes.ptr))
                catch continue;

            if (surface_fomats_count == 0 or surface_present_modes_count == 0) {
                std.log.info("  - doesn't satisfy all surface requirements", .{});
                continue;
            }

            // @TODO: better physical device selection
            if (props.deviceType == c.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) {
                best_physical_device_idx = idx;
            }
        }

        if (best_physical_device_idx >= physical_device_count) {
            return error.UnableToFindASuitablePhysicalDevice;
        }
        const vk_physical_device = physical_device_storage[best_physical_device_idx];

        var physical_device_props: c.VkPhysicalDeviceProperties = undefined;
        c.vkGetPhysicalDeviceProperties(vk_physical_device, &physical_device_props);
        std.log.info("Selected {s} as the physical device.", .{std.mem.sliceTo(&physical_device_props.deviceName, 0)});

        var surface_capabilities: c.VkSurfaceCapabilitiesKHR = undefined;
        try vkt(c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(vk_physical_device, vk_surface, &surface_capabilities));

        var surface_format: c.VkSurfaceFormatKHR = .{
            .format = c.VK_FORMAT_R8G8B8A8_SRGB,
            .colorSpace = c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR,
        };
        var present_mode: c.VkPresentModeKHR = c.VK_PRESENT_MODE_MAILBOX_KHR;

        var surface_fomats_count: u32 = 0;
        try vkt(c.vkGetPhysicalDeviceSurfaceFormatsKHR(vk_physical_device, vk_surface, &surface_fomats_count, null));

        const surface_formats = try alloc.alloc(c.VkSurfaceFormatKHR, surface_fomats_count);
        defer alloc.free(surface_formats);
        try vkt(c.vkGetPhysicalDeviceSurfaceFormatsKHR(vk_physical_device, vk_surface, &surface_fomats_count, surface_formats.ptr));

        var found_format = false;
        for (surface_formats) |sf| {
            if (sf.format == surface_format.format and sf.colorSpace == surface_format.colorSpace) {
                found_format = true;
                break;
            }
        }
        if (!found_format) {
            if (surface_formats.len == 0) {
                return error.DeviceDoesNotHaveAnySupportedSurfaceFormats;
            }
            surface_format = surface_formats[0];
        }

        var surface_present_modes_count: u32 = 0;
        try vkt(c.vkGetPhysicalDeviceSurfacePresentModesKHR(vk_physical_device, vk_surface, &surface_present_modes_count, null));

        const surface_present_modes = try alloc.alloc(c.VkPresentModeKHR, surface_present_modes_count);
        defer alloc.free(surface_present_modes);
        try vkt(c.vkGetPhysicalDeviceSurfacePresentModesKHR(vk_physical_device, vk_surface, &surface_present_modes_count, surface_present_modes.ptr));

        var found_present_mode = false;
        for (surface_present_modes) |sp| {
            if (sp == present_mode) {
                found_present_mode = true;
                break;
            }
        }
        if (!found_present_mode) {
            present_mode = c.VK_PRESENT_MODE_FIFO_KHR;
            if (std.mem.count(c.VkPresentModeKHR, surface_present_modes, &.{present_mode}) == 0) {
                return error.DeviceDoesNotSupportRequestedPresentMode;
            }
        }

        var queue_family_properties_count: u32 = 0;
        c.vkGetPhysicalDeviceQueueFamilyProperties(vk_physical_device, &queue_family_properties_count, null);

        const queue_family_properties_storage = try alloc.alloc(c.VkQueueFamilyProperties, queue_family_properties_count);
        defer alloc.free(queue_family_properties_storage);
        c.vkGetPhysicalDeviceQueueFamilyProperties(
            vk_physical_device, 
            &queue_family_properties_count, 
            queue_family_properties_storage.ptr
        );

        var all_queue_idx: u32 = std.math.maxInt(u32);
        var present_queue_idx: u32 = std.math.maxInt(u32);
        var transfer_queue_idx: u32 = std.math.maxInt(u32);
        for (queue_family_properties_storage, 0..) |queue_family_props, idx| {
            const is_graphics = queue_family_props.queueFlags & c.VK_QUEUE_GRAPHICS_BIT != 0;
            const is_compute = queue_family_props.queueFlags & c.VK_QUEUE_COMPUTE_BIT != 0;
            const is_transfer = queue_family_props.queueFlags & c.VK_QUEUE_TRANSFER_BIT != 0;

            var supports_present: c.VkBool32 = 0;
            vkt(c.vkGetPhysicalDeviceSurfaceSupportKHR(vk_physical_device, @intCast(idx), vk_surface, &supports_present)) catch {
                std.log.info("unable to check queue family for present support, thats unfortunate", .{});
            };

            std.log.info("queue {}: present {}, graphics {}, compute {}, transfer {}", .{
                idx, (supports_present == c.VK_TRUE), is_graphics, is_compute, is_transfer
            });

            if (supports_present == c.VK_TRUE) {
                present_queue_idx = @intCast(idx);
            }
            if (is_graphics and is_compute) {
                all_queue_idx = @intCast(idx);
            }
            if (is_transfer and !(is_graphics or is_compute)) {
                transfer_queue_idx = @intCast(idx);
            }
        }
        if (all_queue_idx >= queue_family_properties_count or present_queue_idx >= queue_family_properties_count) {
            return error.UnableToFindAllRequiredQueuesOnPhysicalDevice;
        }

        const queue_priority = [3]f32{1.0, 1.0, 1.0};
        var queue_create_infos = std.ArrayList(c.VkDeviceQueueCreateInfo).init(alloc);
        defer queue_create_infos.deinit();

        try queue_create_infos.append(.{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueCount = 1,
            .queueFamilyIndex = all_queue_idx,
            .pQueuePriorities = queue_priority[0..].ptr,
        });

        if (present_queue_idx != all_queue_idx) {
            try queue_create_infos.append(.{
                .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .queueCount = 1,
                .queueFamilyIndex = present_queue_idx,
                .pQueuePriorities = queue_priority[0..].ptr,
            });
        }

        if (transfer_queue_idx < queue_family_properties_count) {
            try queue_create_infos.append(.{
                .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .queueCount = 1,
                .queueFamilyIndex = transfer_queue_idx,
                .pQueuePriorities = queue_priority[0..].ptr,
            });
        }

        const create_device_info = c.VkDeviceCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .pNext = null,
            .queueCreateInfoCount = @intCast(queue_create_infos.items.len),
            .pQueueCreateInfos = queue_create_infos.items.ptr,
            .enabledExtensionCount = @intCast(device_extensions.items.len),
            .ppEnabledExtensionNames = device_extensions.items.ptr,
            .flags = 0,
        };

        var vk_device: c.VkDevice = undefined;
        try vkt(c.vkCreateDevice(
                vk_physical_device, 
                &create_device_info,
                null,
                &vk_device
        ));
        errdefer c.vkDestroyDevice(vk_device, null);
        errdefer vkt(c.vkDeviceWaitIdle(vk_device)) catch unreachable;

        var vk_all_queue: c.VkQueue = undefined;
        c.vkGetDeviceQueue(vk_device, all_queue_idx, 0, &vk_all_queue);

        var vk_present_queue: c.VkQueue = vk_all_queue;
        if (present_queue_idx != all_queue_idx) {
            std.log.info("has dedicated present queue", .{});
            var vk_queue_temp: c.VkQueue = undefined;
            c.vkGetDeviceQueue(vk_device, present_queue_idx, 0, &vk_queue_temp);
            vk_present_queue = vk_queue_temp;
        }

        var vk_cpu_gpu_transfer_queue: ?c.VkQueue = null;
        if (transfer_queue_idx < queue_family_properties_count) {
            std.log.info("has dedicated transfer queue", .{});
            var vk_transfer_queue_temp: c.VkQueue = undefined;
            c.vkGetDeviceQueue(vk_device, transfer_queue_idx, 0, &vk_transfer_queue_temp);
            vk_cpu_gpu_transfer_queue = vk_transfer_queue_temp;
        }

        const queues = VkQueues {
            .all = vk_all_queue,
            .all_family_index = all_queue_idx,
            .present = vk_present_queue,
            .present_family_index = present_queue_idx,
            // if dedicated cpu-gpu queue exists use that otherwise set to all_queue
            .cpu_gpu_transfer = vk_cpu_gpu_transfer_queue orelse vk_all_queue,
            .cpu_gpu_transfer_family_index = if (vk_cpu_gpu_transfer_queue) |_| transfer_queue_idx else all_queue_idx,
        };

        const transfer_command_pool_create_info = c.VkCommandPoolCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .queueFamilyIndex = queues.cpu_gpu_transfer_family_index,
        };

        var vk_transfer_command_pool: c.VkCommandPool = undefined;
        try vkt(c.vkCreateCommandPool(vk_device, &transfer_command_pool_create_info, null, &vk_transfer_command_pool));
        errdefer c.vkDestroyCommandPool(vk_device, vk_transfer_command_pool, null);
        errdefer vkt(c.vkDeviceWaitIdle(vk_device)) catch unreachable;

        const all_command_pool_create_info = c.VkCommandPoolCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .queueFamilyIndex = queues.all_family_index,
        };

        var vk_all_command_pool: c.VkCommandPool = undefined;
        try vkt(c.vkCreateCommandPool(vk_device, &all_command_pool_create_info, null, &vk_all_command_pool));
        errdefer c.vkDestroyCommandPool(vk_device, vk_all_command_pool, null);
        errdefer vkt(c.vkDeviceWaitIdle(vk_device)) catch unreachable;

        var self = Self {
            .alloc = alloc,
            .slang_global = slang_global,
            .vk_version = vk_version,
            .instance = vk_instance,
            .physical_device = vk_physical_device,
            .device = vk_device,
            .surface = vk_surface,
            .queues = queues,
            .transfer_command_pool = vk_transfer_command_pool,
            .all_command_pool = vk_all_command_pool,
            .swapchain = undefined,
        };

        self.swapchain = try self.create_swapchain(window, .{
            .format = surface_format,
            .present_mode = present_mode,
        });
        errdefer self.swapchain.deinit(self.device);

        std.log.info("success!", .{});
        //return error.Unimplemented;
        return self;
    }

    const SwapchainCreateOptions = struct {
        format: c.VkSurfaceFormatKHR,
        present_mode: c.VkPresentModeKHR,
    };

    fn create_swapchain(self: *Self, window: *pl.Window, opt: SwapchainCreateOptions) !SwapchainInfo {
        var surface_capabilities: c.VkSurfaceCapabilitiesKHR = undefined;
        try vkt(c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(self.physical_device, self.surface, &surface_capabilities));

        var swapchain_extent = surface_capabilities.currentExtent;
        if (swapchain_extent.width == std.math.maxInt(u32)) {
            const window_size = try window.get_client_size();
            swapchain_extent = c.VkExtent2D {
                .width = std.math.clamp(@as(u32, @intCast(window_size.width)),
                    surface_capabilities.minImageExtent.width, surface_capabilities.maxImageExtent.width),
                .height = std.math.clamp(@as(u32, @intCast(window_size.height)),
                    surface_capabilities.minImageExtent.height, surface_capabilities.maxImageExtent.height),
            };
        }

        var swapchain_image_count = std.math.clamp(
            surface_capabilities.minImageCount + 1,
            surface_capabilities.minImageCount,
            if (surface_capabilities.maxImageCount != 0) surface_capabilities.maxImageCount else std.math.maxInt(u32),
        );

        var swapchain_create_info = c.VkSwapchainCreateInfoKHR {
            .sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .surface = self.surface,
            .minImageCount = swapchain_image_count,
            .imageFormat = opt.format.format,
            .imageColorSpace = opt.format.colorSpace,
            .imageExtent = swapchain_extent,
            .imageArrayLayers = 1,
            .imageUsage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
            .imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .preTransform = surface_capabilities.currentTransform,
            .compositeAlpha = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
            .presentMode = opt.present_mode,
            .clipped = c.VK_TRUE,
            .oldSwapchain = @ptrCast(c.VK_NULL_HANDLE),
        };
        const swapchain_create_queue_indices = [2]u32 { self.queues.all_family_index, self.queues.present_family_index };
        if (self.queues.all_family_index == self.queues.present_family_index) {
            swapchain_create_info.imageSharingMode = c.VK_SHARING_MODE_CONCURRENT;
            swapchain_create_info.queueFamilyIndexCount = @intCast(swapchain_create_queue_indices.len);
            swapchain_create_info.pQueueFamilyIndices = &swapchain_create_queue_indices;
        }

        var vk_swapchain: c.VkSwapchainKHR = undefined;
        try vkt(c.vkCreateSwapchainKHR(self.device, &swapchain_create_info, null, &vk_swapchain));
        errdefer c.vkDestroySwapchainKHR(self.device, vk_swapchain, null);

        try vkt(c.vkGetSwapchainImagesKHR(self.device, vk_swapchain, &swapchain_image_count, null));

        var swapchain_images = try std.ArrayList(c.VkImage).initCapacity(self.alloc, swapchain_image_count);
        try swapchain_images.resize(swapchain_image_count);
        errdefer swapchain_images.deinit();
        try vkt(c.vkGetSwapchainImagesKHR(self.device, vk_swapchain, &swapchain_image_count, swapchain_images.items.ptr));

        var swapchain_image_views = try std.ArrayList(c.VkImageView).initCapacity(self.alloc, swapchain_image_count);
        errdefer swapchain_image_views.deinit();

        for (swapchain_images.items) |img| {
            const view_create_info = c.VkImageViewCreateInfo {
                .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                .image = img,
                .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
                .format = opt.format.format,
                .components = .{
                    .r = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                    .g = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                    .b = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                    .a = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                },
                .subresourceRange = .{
                    .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                    .baseMipLevel = 0,
                    .levelCount = 1,
                    .baseArrayLayer = 0,
                    .layerCount = 1,
                },
            };
            var swapchain_image_view: c.VkImageView = null;
            try vkt(c.vkCreateImageView(self.device, &view_create_info, null, &swapchain_image_view));
            try swapchain_image_views.append(swapchain_image_view);
        }
        errdefer {
            for (swapchain_image_views.items) |iv| {
                c.vkDestroyImageView(self.device, iv, null);
            }
            swapchain_image_views.clearRetainingCapacity();
        }
        
        return .{
            .swapchain = vk_swapchain,
            .images = swapchain_images,
            .image_views = swapchain_image_views,
            .extent = swapchain_extent,
            .format = opt.format,
            .present_mode = opt.present_mode,
        };
    }

    pub fn create_texture2d_from_framebuffer(self: *Self, gfx: *gf.GfxState) !gf.Texture2D {
        _ = self;
        return gf.Texture2D.init(
            .{
                .format = .R32_Float,
                .width = 1,
                .height = 1,
            },
            .{},
            .{},
            &[_]u8{0, 0, 0, 0},
            gfx
        );
    }

    pub inline fn begin_frame(self: *Self) !gf.RenderTargetView {
        _ = self;
        return gf.RenderTargetView {};
    }

    // pub inline fn get_framebuffer(self: *Self) *gf.RenderTargetView {
    //     _ = self;
    //     return undefined;
    // }

    pub inline fn present(self: *Self) !void {
        _ = self;
    }

    pub inline fn flush(self: *Self) void {
        _ = self;
    }

    pub inline fn clear_state(self: *Self) void {
        _ = self;
    }

    pub inline fn resize_swapchain(self: *Self, new_width: i32, new_height: i32) void {
        _ = self;
        _ = new_width;
        _ = new_height;
    }

    pub inline fn cmd_clear_render_target(self: *Self, rt: *const gf.RenderTargetView, color: zm.F32x4) void {
        _ = self;
        _ = rt;
        _ = color;
    }

    pub inline fn cmd_clear_depth_stencil_view(self: *Self, dsv: *const gf.DepthStencilView, depth: ?f32, stencil: ?u8) void {
        _ = self;
        _ = dsv;
        _ = depth;
        _ = stencil;
    }

    pub inline fn cmd_set_viewport(self: *Self, viewport: gf.Viewport) void {
        _ = self;
        _ = viewport;
    }

    pub inline fn cmd_set_scissor_rect(self: *Self, scissor: ?Rect) void {
        _ = self;
        _ = scissor;
    }
    
    pub inline fn cmd_set_render_target(self: *Self, rtvs: []const ?*const gf.RenderTargetView, depth_stencil_view: ?*const gf.DepthStencilView) void {
        _ = self;
        _ = rtvs;
        _ = depth_stencil_view;
    }

    pub inline fn cmd_set_vertex_shader(self: *Self, vs: *const gf.VertexShader) void {
        _ = self;
        _ = vs;
    }

    pub inline fn cmd_set_pixel_shader(self: *Self, ps: *const gf.PixelShader) void {
        _ = self;
        _ = ps;
    }

    pub inline fn cmd_set_hull_shader(self: *Self, hs: ?*const gf.HullShader) void {
        _ = self;
        _ = hs;
    }

    pub inline fn cmd_set_domain_shader(self: *Self, ds: ?*const gf.DomainShader) void {
        _ = self;
        _ = ds;
    }
    
    pub inline fn cmd_set_geometry_shader(self: *Self, gs: ?*const gf.GeometryShader) void {
        _ = self;
        _ = gs;
    }

    pub inline fn cmd_set_compute_shader(self: *Self, cs: ?*const gf.ComputeShader) void {
        _ = self;
        _ = cs;
    }

    pub inline fn cmd_set_vertex_buffers(self: *Self, start_slot: u32, buffers: []const gf.VertexBufferInput) void {
        _ = self;
        _ = start_slot;
        _ = buffers;
    }

    pub inline fn cmd_set_index_buffer(self: *Self, buffer: *const gf.Buffer, format: gf.IndexFormat, offset: u32) void {
        _ = self;
        _ = buffer;
        _ = format;
        _ = offset;
    }

    pub inline fn cmd_set_constant_buffers(self: *Self, shader_stage: gf.ShaderStage, start_slot: u32, buffers: []const *const gf.Buffer) void {
        _ = self;
        _ = shader_stage;
        _ = start_slot;
        _ = buffers;
    }

    pub inline fn cmd_set_rasterizer_state(self: *Self, rs: gf.RasterizationStateDesc) void {
        _ = self;
        _ = rs;
    }

    pub inline fn cmd_set_blend_state(self: *Self, blend_state: ?*const gf.BlendState) void {
        _ = self;
        _ = blend_state;
    }

    pub inline fn cmd_set_shader_resources(self: *Self, shader_stage: gf.ShaderStage, start_slot: u32, views: []const ?*const ShaderResourceView) void {
        _ = self;
        _ = shader_stage;
        _ = start_slot;
        _ = views;
    }

    pub inline fn cmd_set_samplers(self: *Self, shader_stage: gf.ShaderStage, start_slot: u32, sampler: []const *const gf.Sampler) void {
        _ = self;
        _ = shader_stage;
        _ = start_slot;
        _ = sampler;
    }

    pub inline fn cmd_draw(self: *Self, vertex_count: u32, start_vertex: u32) void {
        _ = self;
        _ = vertex_count;
        _ = start_vertex;
    }

    pub inline fn cmd_draw_indexed(self: *Self, index_count: u32, start_index: u32, base_vertex: i32) void {
        _ = self;
        _ = index_count;
        _ = start_index;
        _ = base_vertex;
    }

    pub inline fn cmd_draw_instanced(self: *Self, vertex_count: u32, instance_count: u32, start_vertex: u32, start_instance: u32) void {
        _ = self;
        _ = vertex_count;
        _ = instance_count;
        _ = start_vertex;
        _ = start_instance;
    }

    pub inline fn cmd_set_topology(self: *Self, topology: gf.Topology) void {
        _ = self;
        _ = topology;
    }

    pub inline fn cmd_set_topology_patch_list_count(self: *Self, patch_list_count: u32) void {
        _ = self;
        _ = patch_list_count;
    }

    pub inline fn cmd_set_unordered_access_views(self: *Self, shader_stage: gf.ShaderStage, start_slot: u32, views: []const ?*const UnorderedAccessView) void {
        _ = self;
        _ = shader_stage;
        _ = start_slot;
        _ = views;
    }

    pub inline fn cmd_dispatch_compute(self: *Self, num_groups_x: u32, num_groups_y: u32, num_groups_z: u32) void {
        _ = self;
        _ = num_groups_x;
        _ = num_groups_y;
        _ = num_groups_z;
    }

    pub inline fn cmd_copy_texture_to_texture(self: *Self, dst_texture: *const gf.Texture2D, src_texture: *const gf.Texture2D) void {
        _ = self;
        _ = dst_texture;
        _ = src_texture;
    }
};

const ShaderModule = struct {
    const Self = @This();

    vk_shader_module: c.VkShaderModule,
    vk_shader_stage_create_info: c.VkPipelineShaderStageCreateInfo,
    entry_point: [:0]const u8,

    pub fn deinit(self: *const Self) void {
        const alloc = eng.get().gfx.platform.alloc;

        c.vkDestroyShaderModule(eng.get().gfx.platform.device, self.vk_shader_module, null);
        alloc.free(self.entry_point);
    }

    pub fn init(
        shader_data: []const u8, 
        shader_entry_point: []const u8, 
        shader_stage: gf.ShaderStage,
        gfx: *gf.GfxState,
    ) !Self {
        const alloc = gfx.platform.alloc;

        const session_create_info = slang.SessionCreateInfo {
            .compile_target = slang.c.TARGET_SPIRV,
            .profile = "spirv_1_3",
            .preprocessor_macros = &.{
            },
        };

        const slang_session = try slang.check(slang.c.create_session(gfx.platform.slang_global, session_create_info.to_slang()));
        defer slang.c.destroy_session(slang_session);

        const diagnostics_blob = try slang.check(slang.c.create_blob());
        defer slang.c.destroy_blob(diagnostics_blob);

        const shader_data_z = try gfx.platform.alloc.dupeZ(u8, shader_data);
        defer gfx.platform.alloc.free(shader_data_z);

        const module_create_info = slang.c.ModuleCreateInfo {
            .module_name = "shader",
            .module_path = "",
            .shader_source = @ptrCast(shader_data_z.ptr),
            .diagnostics_blob = diagnostics_blob,
        };

        const slang_module = slang.check(slang.c.create_and_load_module(slang_session, module_create_info)) catch {
            std.log.info("slang error creating module: {s}", .{slang.blob_str(diagnostics_blob)});
            return error.UnableToCreateSlangModule;
        };
        defer slang.c.destroy_module(slang_module);

        const entry_point_z = try gfx.platform.alloc.dupeZ(u8, shader_entry_point);
        defer gfx.platform.alloc.free(entry_point_z);

        const entry_point_create_info = slang.c.EntryPointCreateInfo {
            .entry_point_name = @ptrCast(entry_point_z.ptr),
            .diagnostics_blob = diagnostics_blob,
        };

        const slang_entry_point = slang.check(slang.c.find_and_create_entry_point(slang_module, entry_point_create_info)) catch {
            std.log.info("slang error creating entrypoint: {s}", .{slang.blob_str(diagnostics_blob)});
            return error.UnableToCreateSlangEntryPoint;
        };
        defer slang.c.destroy_entry_point(slang_entry_point);

        const composed_create_info = slang.ComposedProgramCreateInfo {
            .diagnostics_blob = diagnostics_blob,
            .modules = &.{
                slang_module,
            },
            .entry_points = &.{
                slang_entry_point,
            },
        };

        const composed_program = try slang.check(slang.c.create_composed_program(slang_session, composed_create_info.to_slang()));
        defer slang.c.destroy_composed_program(composed_program);

        const link_program_create_info = slang.c.LinkedProgramCreateInfo {
            .diagnostics_blob = diagnostics_blob,
        };

        const linked_program = slang.check(slang.c.create_linked_program(composed_program, link_program_create_info)) catch {
            std.log.info("slang error linking program: {s}", .{slang.blob_str(diagnostics_blob)});
            return error.UnableToLinkSlangProgram;
        };
        defer slang.c.destroy_linked_program(linked_program);

        const output_blob = slang.c.create_blob();
        defer slang.c.destroy_blob(output_blob);

        const get_target_create_info = slang.c.GetTargetCodeCreateInfo {
            .output_blob = output_blob,
            .diagnostics_blob = diagnostics_blob,
        };

        if (!slang.c.get_target_code(linked_program, get_target_create_info)) {
            std.log.info("slang error target code: {s}", .{slang.blob_str(diagnostics_blob)});
            return error.UnableToGetSlangTargetCode;
        }

        const spirv_shader_code = slang.blob_slice(output_blob);

        const entry_point = try alloc.dupeZ(u8, shader_entry_point);
        errdefer alloc.free(entry_point);

        const aligned_data = try alloc.alignedAlloc(u8, 4, spirv_shader_code.len);
        defer alloc.free(aligned_data);
        @memcpy(aligned_data, spirv_shader_code);

        const shader_create_info = c.VkShaderModuleCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .codeSize = @intCast(aligned_data.len),
            .pCode = @ptrCast(aligned_data.ptr),// @ptrCast(@alignCast(shader_data.ptr)),
        };

        var shader_module: c.VkShaderModule = undefined;
        try vkt(c.vkCreateShaderModule(gfx.platform.device, &shader_create_info, null, &shader_module));
        errdefer c.vkDestroyShaderModule(gfx.platform.device, shader_module, null);

        const shader_stage_create_info = c.VkPipelineShaderStageCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = switch (shader_stage) {
                .Vertex => c.VK_SHADER_STAGE_VERTEX_BIT,
                .Pixel => c.VK_SHADER_STAGE_FRAGMENT_BIT,
                .Compute => c.VK_SHADER_STAGE_COMPUTE_BIT,
                .Geometry => c.VK_SHADER_STAGE_GEOMETRY_BIT,
                else => unreachable,
            },
            .module = shader_module,
            .pName = entry_point.ptr,
        };

        return .{
            .vk_shader_module = shader_module,
            .vk_shader_stage_create_info = shader_stage_create_info,
            .entry_point = entry_point,
        };
    }
};

pub const VertexShaderVulkan = struct {
    const Self = @This();

    shader_module: ShaderModule,
    vk_vertex_input_binding_description: []c.VkVertexInputBindingDescription,
    vk_vertex_input_attrib_description: []c.VkVertexInputAttributeDescription,
    
    pub inline fn deinit(self: *const Self) void {
        const alloc = eng.get().gfx.platform.alloc;
        
        self.shader_module.deinit();
        alloc.free(self.vk_vertex_input_attrib_description);
        alloc.free(self.vk_vertex_input_binding_description);
    }

    pub inline fn init_buffer(
        vs_data: []const u8,
        vs_func: []const u8,
        vs_layout: []const gf.VertexInputLayoutEntry,
        options: gf.VertexShaderOptions,
        gfx: *gf.GfxState,
    ) !Self {
        _ = options;
        const alloc = gfx.platform.alloc;

        const shader_module = try ShaderModule.init(vs_data, vs_func, gf.ShaderStage.Vertex, gfx);
        errdefer shader_module.deinit();

        const vertex_input_bindings = try alloc.alloc(c.VkVertexInputBindingDescription, vs_layout.len);
        errdefer alloc.free(vertex_input_bindings);

        const vertex_input_attrib_descriptions = try alloc.alloc(c.VkVertexInputAttributeDescription, vs_layout.len);
        errdefer alloc.free(vertex_input_attrib_descriptions);

        for (vs_layout, 0..) |entry, idx| {
            vertex_input_bindings[idx] = c.VkVertexInputBindingDescription {
                .binding = @intCast(idx),
                .stride = switch (entry.format) {
                    .F32x1 => @sizeOf(f32) * 1,
                    .F32x2 => @sizeOf(f32) * 2,
                    .F32x3 => @sizeOf(f32) * 3,
                    .F32x4 => @sizeOf(f32) * 4,
                    .I32x4 => @sizeOf(i32) * 4,
                    .U8x4 => @sizeOf(u8) * 4,
                },
                .inputRate = switch (entry.per) {
                    .Vertex => c.VK_VERTEX_INPUT_RATE_VERTEX,
                    .Instance => c.VK_VERTEX_INPUT_RATE_INSTANCE,
                },
            };

            vertex_input_attrib_descriptions[idx] = c.VkVertexInputAttributeDescription {
                .binding = @intCast(idx),
                .location = 0,
                .offset = 0,
                .format = switch (entry.format) {
                    .F32x1 => c.VK_FORMAT_R32_SFLOAT,
                    .F32x2 => c.VK_FORMAT_R32G32_SFLOAT,
                    .F32x3 => c.VK_FORMAT_R32G32B32_SFLOAT,
                    .F32x4 => c.VK_FORMAT_R32G32B32A32_SFLOAT,
                    .I32x4 => c.VK_FORMAT_R32G32B32A32_SINT,
                    .U8x4 => c.VK_FORMAT_R8G8B8A8_UINT,
                },
            };
        }

        return .{
            .shader_module = shader_module,
            .vk_vertex_input_binding_description = vertex_input_bindings,
            .vk_vertex_input_attrib_description = vertex_input_attrib_descriptions,
        };
    }
};

pub const PixelShaderVulkan = struct {
    const Self = @This();

    shader_module: ShaderModule,
    
    pub inline fn deinit(self: *const Self) void {
        self.shader_module.deinit();
    }
    
    pub inline fn init_buffer(
        ps_data: []const u8, 
        ps_func: []const u8, 
        options: gf.PixelShaderOptions,
        gfx: *gf.GfxState,
    ) !Self {
        _ = options;

        const shader_module = try ShaderModule.init(ps_data, ps_func, gf.ShaderStage.Pixel, gfx);
        errdefer shader_module.deinit();

        return .{
            .shader_module = shader_module,
        };
    }
};

pub const HullShaderVulkan = struct {
    const Self = @This();
    
    pub inline fn deinit(self: *const Self) void {
        _ = self;
    }
    
    pub inline fn init_buffer(
        hs_data: []const u8, 
        hs_func: []const u8, 
        options: gf.HullShaderOptions,
        gfx: *gf.GfxState,
    ) !Self {
        _ = hs_data;
        _ = hs_func;
        _ = options;
        _ = gfx;
        return .{};
    }
};

pub const DomainShaderVulkan = struct {
    const Self = @This();
    
    pub inline fn deinit(self: *const Self) void {
        _ = self;
    }
    
    pub inline fn init_buffer(
        ds_data: []const u8, 
        ds_func: []const u8, 
        options: gf.DomainShaderOptions,
        gfx: *gf.GfxState,
    ) !Self {
        _ = ds_data;
        _ = ds_func;
        _ = options;
        _ = gfx;
        return .{};
    }
};

pub const GeometryShaderVulkan = struct {
    const Self = @This();
    
    pub inline fn deinit(self: *const Self) void {
        _ = self;
    }
    
    pub inline fn init_buffer(
        gs_data: []const u8, 
        gs_func: []const u8, 
        options: gf.GeometryShaderOptions,
        gfx: *gf.GfxState,
    ) !Self {
        _ = gs_data;
        _ = gs_func;
        _ = options;
        _ = gfx;
        return .{};
    }
};

pub const ComputeShaderVulkan = struct {
    const Self = @This();
    
    pub inline fn deinit(self: *const Self) void {
        _ = self;
    }
    
    pub inline fn init_buffer(
        cs_data: []const u8, 
        cs_func: []const u8,
        options: gf.ComputeShaderOptions,
        gfx: *gf.GfxState,
    ) !Self {
        _ = cs_data;
        _ = cs_func;
        _ = options;
        _ = gfx;
        return .{};
    }
};

fn convert_buffer_usage_flags_to_vulkan(usage: gf.BufferUsageFlags) u32 {
    var flags: u32 = 0;

    if (usage.VertexBuffer) {
        flags |= c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT;
    }
    if (usage.IndexBuffer) {
        flags |= c.VK_BUFFER_USAGE_INDEX_BUFFER_BIT;
    }
    if (usage.ConstantBuffer) {
        flags |= c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT;
    }
    if (usage.TransferSrc) {
        flags |= c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
    }
    if (usage.TransferDst) {
        flags |= c.VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    }
    if (usage.ShaderResource) {
        unreachable;
    }

    return flags;
}

fn find_vulkan_memory_type(type_filter: u32, property_flags: c.VkMemoryPropertyFlags, gfx: *GfxStateVulkan) !u32 {
    var vk_mem_properties: c.VkPhysicalDeviceMemoryProperties = undefined;
    c.vkGetPhysicalDeviceMemoryProperties(gfx.physical_device, &vk_mem_properties);

    for (vk_mem_properties.memoryTypes[0..(vk_mem_properties.memoryTypeCount)], 0..) |mem_type, idx| {
        const contains_all_properties = ((mem_type.propertyFlags & property_flags) == property_flags);
        if ((type_filter & (@as(u32, 1) << @intCast(idx)) != 0) and contains_all_properties) {
            return @intCast(idx);
        }
    }

    return error.CouldNotFindSuitableVulkanMemory;
}

pub const BufferVulkan = struct {
    const Self = @This();

    vk_buffer_info: c.VkBufferCreateInfo,
    vk_buffer: c.VkBuffer,
    vk_device_memory: c.VkDeviceMemory,

    pub inline fn deinit(self: *const Self) void {
        c.vkFreeMemory(eng.get().gfx.platform.device, self.vk_device_memory, null);
        c.vkDestroyBuffer(eng.get().gfx.platform.device, self.vk_buffer, null);
    }

    pub inline fn init(
        byte_size: u32,
        usage_flags: gf.BufferUsageFlags,
        access_flags: gf.AccessFlags,
        gfx: *gf.GfxState,
    ) !Self {
        // @TODO: use the dedicated transfer queue
        const use_shared = false; // gfx.platform.queues.has_distinct_transfer_queue() and
            // (access_flags.CpuRead or access_flags.CpuWrite);
        const family_indices: []const u32 = &.{ gfx.platform.queues.all_family_index, gfx.platform.queues.cpu_gpu_transfer_family_index };

        const buffer_create_info = c.VkBufferCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .sharingMode = if (use_shared) c.VK_SHARING_MODE_CONCURRENT else c.VK_SHARING_MODE_EXCLUSIVE,
            .pQueueFamilyIndices = @ptrCast(family_indices.ptr),
            .queueFamilyIndexCount = if (use_shared) @intCast(family_indices.len) else 1,
            .size = @intCast(byte_size),
            .usage = convert_buffer_usage_flags_to_vulkan(usage_flags),
        };
        std.debug.assert(buffer_create_info.usage != 0);

        var vk_buffer: c.VkBuffer = undefined;
        try vkt(c.vkCreateBuffer(gfx.platform.device, &buffer_create_info, null, &vk_buffer));
        errdefer c.vkDestroyBuffer(gfx.platform.device, vk_buffer, null);

        var vk_memory_requirements: c.VkMemoryRequirements = undefined;
        c.vkGetBufferMemoryRequirements(gfx.platform.device, vk_buffer, &vk_memory_requirements);

        const memory_properties: c.VkMemoryPropertyFlags = if (access_flags.CpuRead or access_flags.CpuWrite)
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT
            else c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;

        const memory_allocate_info = c.VkMemoryAllocateInfo {
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = vk_memory_requirements.size,
            .memoryTypeIndex = try find_vulkan_memory_type(
                vk_memory_requirements.memoryTypeBits,
                memory_properties,
                &gfx.platform
            ),
        };

        var vk_device_memory: c.VkDeviceMemory = undefined;
        try vkt(c.vkAllocateMemory(gfx.platform.device, &memory_allocate_info, null, &vk_device_memory));
        errdefer c.vkFreeMemory(gfx.platform.device, vk_device_memory, null);

        try vkt(c.vkBindBufferMemory(gfx.platform.device, vk_buffer, vk_device_memory, 0));

        return .{
            .vk_buffer_info = buffer_create_info,
            .vk_buffer = vk_buffer,
            .vk_device_memory = vk_device_memory,
        };
    }
    
    pub inline fn init_with_data(
        data: []const u8,
        usage_flags: gf.BufferUsageFlags,
        access_flags: gf.AccessFlags,
        gfx: *gf.GfxState,
    ) !Self {
        var usage_flags_plus = usage_flags;
        usage_flags_plus.TransferDst = true;

        const self = try Self.init(@intCast(data.len), usage_flags_plus, access_flags, gfx);
        errdefer self.deinit();

        const staging = try Self.init(
            @intCast(data.len), 
            .{ .TransferSrc = true, },
            .{ .CpuWrite = true, },
            gfx
        );
        defer staging.deinit();

        {
            var data_ptr: ?*anyopaque = undefined;
            try vkt(c.vkMapMemory(gfx.platform.device, staging.vk_device_memory, 0, staging.vk_buffer_info.size, 0, &data_ptr));
            defer c.vkUnmapMemory(gfx.platform.device, staging.vk_device_memory);

            @memcpy(@as([*]u8, @ptrCast(data_ptr))[0..(staging.vk_buffer_info.size)], data[0..]);
        }

        const command_buffer_allocate_info = c.VkCommandBufferAllocateInfo {
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandBufferCount = 1,
            .commandPool = gfx.platform.all_command_pool,
            .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        };

        var command_buffer: c.VkCommandBuffer = undefined;
        try vkt(c.vkAllocateCommandBuffers(gfx.platform.device, &command_buffer_allocate_info, &command_buffer));
        defer c.vkFreeCommandBuffers(gfx.platform.device, gfx.platform.all_command_pool, 1, &command_buffer);

        const begin_info = c.VkCommandBufferBeginInfo {
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        };

        try vkt(c.vkBeginCommandBuffer(command_buffer, &begin_info));
        const buffer_copy_region = c.VkBufferCopy {
            .size = staging.vk_buffer_info.size,
            .dstOffset = 0,
            .srcOffset = 0,
        };
        c.vkCmdCopyBuffer(command_buffer, staging.vk_buffer, self.vk_buffer, 1, &buffer_copy_region);
        try vkt(c.vkEndCommandBuffer(command_buffer));

        const submit_info = c.VkSubmitInfo {
            .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .commandBufferCount = 1,
            .pCommandBuffers = &command_buffer,
        };

        try vkt(c.vkQueueSubmit(gfx.platform.queues.all, 1, &submit_info, @ptrCast(c.VK_NULL_HANDLE)));
        try vkt(c.vkQueueWaitIdle(gfx.platform.queues.all));

        return self;
    }

    pub inline fn map(self: *const Self, gfx: *gf.GfxState) !MappedBuffer {
        var data_ptr: ?*anyopaque = undefined;
        try vkt(c.vkMapMemory(gfx.platform.device, self.vk_device_memory, 0, self.vk_buffer_info.size, 0, &data_ptr));

        return MappedBuffer {
            .data_ptr = data_ptr,
            .device_memory = self.vk_device_memory,
            .gfx = &gfx.platform,
        };
    }

    pub const MappedBuffer = struct {
        data_ptr: ?*anyopaque,
        device_memory: c.VkDeviceMemory,
        gfx: *GfxStateVulkan,

        pub inline fn unmap(self: *const MappedBuffer) void {
            c.vkUnmapMemory(self.gfx.device, self.device_memory);
        }

        pub inline fn data(self: *const MappedBuffer, comptime Type: type) *Type {
            return @alignCast(@ptrCast(self.data_ptr));
        }

        pub inline fn data_array(self: *const MappedBuffer, comptime Type: type, length: usize) []Type {
            return @as([*]Type, @alignCast(@ptrCast(self.data_ptr)))[0..(length)];
        }
    };

};

pub const Texture2DVulkan = struct {
    const Self = @This();

    alloc: std.mem.Allocator,
    false_data: []u8,

    pub inline fn deinit(self: *const Self) void {
        self.alloc.free(self.false_data);
    }

    pub inline fn init(
        desc: gf.Texture2D.Descriptor,
        usage_flags: gf.TextureUsageFlags,
        access_flags: gf.AccessFlags,
        data: ?[]const u8,
        gfx: *gf.GfxState
    ) !Self {
        _ = usage_flags;
        _ = access_flags;
        const alloc = gfx.platform.alloc;
        const false_data = if (data) |d| try alloc.dupe(u8, d) 
            else try alloc.alloc(u8, desc.height * desc.width * desc.array_length * desc.format.byte_width());
        return .{
            .alloc = alloc,
            .false_data = false_data,
        };
    }

    pub inline fn map_read(self: *const Self, comptime OutType: type, gfx: *gf.GfxState) !MappedTexture(OutType) {
        _ = gfx;
        return MappedTexture(OutType) {
            .data_ptr = @alignCast(@ptrCast(self.false_data.ptr)),
        };
    }

    pub inline fn map_write_discard(self: *const Self, comptime OutType: type, gfx: *gf.GfxState) !MappedTexture(OutType) {
        _ = gfx;
        return MappedTexture(OutType) {
            .data_ptr = @alignCast(@ptrCast(self.false_data.ptr)),
        };
    }

    pub fn MappedTexture(comptime T: type) type {
        return struct {
            data_ptr: *align(16)T,

            pub inline fn unmap(self: *const MappedTexture(T)) void {
                _ = self;
            }
            
            pub inline fn data(self: *const MappedTexture(T)) [*]align(16)T {
                return @as([*]align(16)T, @ptrCast(self.data_ptr));
            }
        };
    }
};

pub const TextureView2DVulkan = struct {
    const Self = @This();
    value: u32 = 0,

    pub inline fn deinit(self: *const Self) void {
        _ = self;
    }

    pub inline fn init_from_texture2d(texture: *const gf.Texture2D, gfx: *gf.GfxState) !Self {
        _ = texture;
        _ = gfx;
        return .{};
    }

    pub fn shader_resource_view(self: *const Self) *const GfxStateVulkan.ShaderResourceView {
        return &self.value;
    }

    pub fn unordered_access_view(self: *const Self) *const GfxStateVulkan.UnorderedAccessView {
        return &self.value;
    }
};

pub const TextureView3DVulkan = struct {
    const Self = @This();
    value: u32 = 0,

    pub inline fn deinit(self: *const Self) void {
        _ = self;
    }

    pub inline fn init_from_texture3d(texture: *const gf.Texture3D, gfx: *gf.GfxState) !Self {
        _ = texture;
        _ = gfx;
        return .{};
    }

    pub fn shader_resource_view(self: *const Self) *const GfxStateVulkan.ShaderResourceView {
        return &self.value;
    }

    pub fn unordered_access_view(self: *const Self) *const GfxStateVulkan.UnorderedAccessView {
        return &self.value;
    }
};

pub const Texture3DVulkan = struct {
    const Self = @This();

    alloc: std.mem.Allocator,
    false_data: []u8,

    pub inline fn deinit(self: *const Self) void {
        self.alloc.free(self.false_data);
    }

    pub inline fn init(
        desc: gf.Texture3D.Descriptor,
        usage_flags: gf.TextureUsageFlags,
        access_flags: gf.AccessFlags,
        data: ?[]const u8,
        gfx: *gf.GfxState
    ) !Self {
        _ = usage_flags;
        _ = access_flags;
        const alloc = gfx.platform.alloc;
        const false_data = if (data) |d| try alloc.dupe(u8, d) 
            else try alloc.alloc(u8, desc.height * desc.width * desc.depth * desc.format.byte_width());
        return .{
            .alloc = alloc,
            .false_data = false_data,
        };
    }

    pub inline fn map(self: *const Self, comptime OutType: type, gfx: *gf.GfxState) !MappedTexture(OutType) {
        _ = gfx;
        return MappedTexture(OutType) {
            .data_ptr = @alignCast(@ptrCast(self.false_data)),
        };
    }

    pub fn MappedTexture(comptime T: type) type {
        return struct {
            data_ptr: *T,

            pub inline fn unmap(self: *const MappedTexture(T)) void {
                _ = self;
            }
            
            pub inline fn data(self: *const MappedTexture(T)) [*]align(1)T {
                return @as([*]align(1)T, @ptrCast(self.data_ptr));
            }
        };
    }
};

pub const RenderTargetViewVulkan = struct {
    const Self = @This();

    pub inline fn deinit(self: *const Self) void {
        _ = self;
    }

    pub inline fn init_from_texture2d(texture: *const gf.Texture2D, gfx: *gf.GfxState) !Self {
        return init_from_texture2d_mip(texture, 0, gfx);
    }

    pub inline fn init_from_texture2d_mip(texture: *const gf.Texture2D, mip_level: u32, gfx: *gf.GfxState) !Self {
        _ = texture;
        _ = mip_level;
        _ = gfx;
        return .{};
    }

    pub fn init_from_texture3d(texture: *const gf.Texture3D, gfx: *gf.GfxState) !Self {
        _ = texture;
        _ = gfx;
        return .{};
    }
};

pub const DepthStencilViewVulkan = struct {
    const Self = @This();

    pub inline fn deinit(self: *const Self) void {
        _ = self;
    }

    pub inline fn init_from_texture2d(
        texture: *const gf.Texture2D, 
        flags: gf.DepthStencilView.Flags,
        gfx: *gf.GfxState
    ) !Self {
        _ = texture;
        _ = flags;
        _ = gfx;
        return .{};
    }
};

pub const RasterizationStateVulkan = struct {
    const Self = @This();

    pub inline fn deinit(self: *const Self) void {
        _ = self.state.Release();
    }

    pub inline fn init(desc: gf.RasterizationStateDesc, gfx: *gf.GfxState) !Self {
        _ = desc;
        _ = gfx;
        return .{};
    }
};

pub const SamplerVulkan = struct {
    const Self = @This();

    pub inline fn deinit(self: *const Self) void {
        _ = self;
    }

    pub inline fn init(desc: gf.SamplerDescriptor, gfx: *gf.GfxState) !Self {
        _ = desc;
        _ = gfx;
        return .{};
    }
};

pub const BlendStateVulkan = struct {
    const Self = @This();

    pub inline fn deinit(self: *const Self) void {
        _ = self;
    }

    pub inline fn init(render_target_blend_types: []const gf.BlendType, gfx: *const gf.GfxState) !Self {
        _ = render_target_blend_types;
        _ = gfx;
        return .{};
    }
};

inline fn topology_to_vulkan(topology: gf.Topology) c.VkPrimitiveTopology {
    return switch (topology) {
        .LineList => c.VK_PRIMITIVE_TOPOLOGY_LINE_LIST,
        .LineStrip => c.VK_PRIMITIVE_TOPOLOGY_LINE_STRIP,
        .PointList => c.VK_PRIMITIVE_TOPOLOGY_POINT_LIST,
        .TriangleList => c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        .TriangleStrip => c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP,
    };
}

inline fn cullmode_to_vulkan(cullmode: gf.CullMode) c.VkCullModeFlags {
    return switch (cullmode) {
        .CullBack => c.VK_CULL_MODE_BACK_BIT,
        .CullFront => c.VK_CULL_MODE_FRONT_BIT,
        .CullFrontAndBack => c.VK_CULL_MODE_FRONT_AND_BACK,
        .CullNone => c.VK_CULL_MODE_NONE,
    };
}

inline fn frontface_to_vulkan(frontface: gf.FrontFace) c.VkFrontFace {
    return switch (frontface) {
        .Clockwise => c.VK_FRONT_FACE_CLOCKWISE,
        .CounterClockwise => c.VK_FRONT_FACE_COUNTER_CLOCKWISE,
    };
}

inline fn fillmode_to_vulkan(fillmode: gf.FillMode) c.VkPolygonMode {
    return switch (fillmode) {
        .Fill => c.VK_POLYGON_MODE_FILL,
        .Line => c.VK_POLYGON_MODE_LINE,
        .Point => c.VK_POLYGON_MODE_POINT,
    };
}

inline fn bool_to_vulkan(b: bool) u32 {
    return switch (b) {
        .true => c.VK_TRUE,
        .false => c.VK_FALSE,
    };
}

inline fn compareop_to_vulkan(compareop: gf.CompareOp) c.VkCompareOp {
    return switch (compareop) {
        .Always => c.VK_COMPARE_OP_ALWAYS,
        .Equal => c.VK_COMPARE_OP_EQUAL,
        .Greater => c.VK_COMPARE_OP_GREATER,
        .GreaterOrEqual => c.VK_COMPARE_OP_GREATER_OR_EQUAL,
        .Less => c.VK_COMPARE_OP_LESS,
        .LessOrEqual => c.VK_COMPARE_OP_LESS_OR_EQUAL,
        .Never => c.VK_COMPARE_OP_NEVER,
        .NotEqual => c.VK_COMPARE_OP_NOT_EQUAL,
    };
}

pub const GraphicsPipelineVulkan = struct {
    const Self = @This();

    vk_pipeline_layout: c.VkPipelineLayout,
    vk_render_pass: c.VkRenderPass,
    vk_graphics_pipeline: c.VkPipeline,

    pub fn deinit(self: *const Self) void {
        const device = eng.get().gfx.platform.device;
        c.vkDestroyPipeline(device, self.vk_graphics_pipeline, null);
        c.vkDestroyRenderPass(device, self.vk_render_pass, null);
        c.vkDestroyPipelineLayout(device, self.vk_pipeline_layout, null);
    }
    
    pub fn init(info: gf.GraphicsPipelineInfo) !Self {
        const alloc = eng.get().frame_allocator;
        var arena_struct = std.heap.ArenaAllocator.init(alloc);
        defer arena_struct.deinit();
        const arena = arena_struct.allocator();
        
        const dynamic_states = []c.VkDynamicState {
            c.VK_DYNAMIC_STATE_VIEWPORT,
            c.VK_DYNAMIC_STATE_SCISSOR,
        };

        const dynamic_state_info = c.VkPipelineDynamicStateCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            .pDynamicStates = @ptrCast(dynamic_states.ptr),
            .dynamicStateCount = @intCast(dynamic_states.len),
        };

        const vertex_shader: *const VertexShaderVulkan = &info.vertex_shader.platform;
        const vertex_input_info = c.VkPipelineVertexInputStateCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,

            .pVertexBindingDescriptions = @ptrCast(vertex_shader.vk_vertex_input_binding_description.ptr),
            .vertexBindingDescriptionCount = @intCast(vertex_shader.vk_vertex_input_binding_description.len),

            .pVertexAttributeDescriptions = @ptrCast(vertex_shader.vk_vertex_input_attrib_description.ptr),
            .vertexAttributeDescriptionCount = @intCast(vertex_shader.vk_vertex_input_attrib_description.len),
        };

        const input_assembly_info = c.VkPipelineInputAssemblyStateCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            .primitiveRestartEnable = c.VK_FALSE,
            .topology = topology_to_vulkan(info.topology),
        };

        const viewport_info = c.VkPipelineViewportStateCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            .viewportCount = 1, // @TODO: attachment count?
            .scissorCount = 1,
        };

        const rasterizer_info = c.VkPipelineRasterizationStateCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            .rasterizerDiscardEnable = c.VK_FALSE,
            .cullMode = cullmode_to_vulkan(info.cull_mode),
            .depthBiasEnable = bool_to_vulkan(info.depth_bias != null),
            .depthBiasClamp = if (info.depth_bias) |b| b.clamp else 0.0,
            .depthBiasConstantFactor = if (info.depth_bias) |b| b.constant_factor else 0.0,
            .depthBiasSlopeFactor = if (info.depth_bias) |b| b.slope_factor else 0.0,
            .depthClampEnable = bool_to_vulkan(info.depth_clamp),
            .frontFace = frontface_to_vulkan(info.front_face),
            .lineWidth = info.rasterization_line_width,
            .polygonMode = fillmode_to_vulkan(info.rasterization_fill_mode),
        };

        const multisample_info = c.VkPipelineMultisampleStateCreateInfo {
            // @TODO: add multisample support?
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            .alphaToCoverageEnable = c.VK_FALSE,
            .alphaToOneEnable = c.VK_FALSE,
            .minSampleShading = 1.0,
            .pSampleMask = null,
            .rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT,
            .sampleShadingEnable = c.VK_FALSE,
        };

        const depth_info = c.VkPipelineDepthStencilStateCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
            .depthTestEnable = bool_to_vulkan(info.depth_test != null),
            .depthCompareOp = if (info.depth_test) |d| d.compare_op else c.VK_COMPARE_OP_ALWAYS,
            .depthWriteEnable = if (info.depth_test) |d| bool_to_vulkan(d.write) else c.VK_FALSE,
            .stencilTestEnable = c.VK_FALSE, // @TODO
            .depthBoundsTestEnable = c.VK_FALSE,
        };

        var attachments = try std.ArrayList(gf.AttachmentInfo).initCapacity(arena, 32);
        defer attachments.deinit();

        const SubpassRefInfo = struct {
            attachment_refs: []usize,
        };
        var subpass_refs = try arena.alloc(SubpassRefInfo, info.subpasses.len);
        arena.free(subpass_refs);

        for (info.subpasses, 0..) |subpass, sidx| {
            subpass_refs[sidx].attachment_refs = try arena.alloc(usize, subpass.attachments.len);

            for (subpass.attachments, 0..) |a, aidx| {
                var attachment_found = false;
                for (attachments.slice(), 0..) |*stored, stored_aidx| {
                    if (!std.mem.eql(u8, stored.name, a.name)) { continue; }
                    if (a.format != stored.format) { continue; }
                    if (a.load_op != stored.load_op) { continue; }
                    if (a.store_op != stored.store_op) { continue; }
                    if (a.stencil_load_op != stored.stencil_load_op) { continue; }
                    if (a.stencil_store_op != stored.stencil_store_op) { continue; }

                    // subpass attachment matches this one!
                    subpass_refs[sidx].attachment_refs[aidx] = stored_aidx;
                    attachment_found = true;
                    break;
                }
                if (!attachment_found) {
                    try attachments.append(a);
                    subpass_refs[sidx].attachment_refs[aidx] = (attachments.items.len - 1);
                }
            }
        }

        var color_blend_attachments = try arena.alloc(c.VkPipelineColorBlendAttachmentState, attachments.items.len);
        defer arena.free(color_blend_attachments);

        for (attachments.items, 0..) |*a, idx| {
            color_blend_attachments[idx] = switch (a.blend_type) {
                // @TODO
                .None => c.VkPipelineColorBlendAttachmentState {
                },
                else => unreachable,
            };
        }

        const color_blend_info = c.VkPipelineColorBlendStateCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .pAttachments = @ptrCast(color_blend_attachments.ptr),
            .attachmentCount = @intCast(color_blend_attachments.len),
            .logicOpEnable = c.VK_FALSE,
            .logicOp = c.VK_LOGIC_OP_COPY,
            .blendConstants = .{ 0.0, 0.0, 0.0, 0.0 },
        };

        const pipeline_layout_info = c.VkPipelineLayoutCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .pSetLayouts = null, // @TODO
            .setLayoutCount = 0,
            .pPushConstantRanges = null,
            .pushConstantRangeCount = 0,
        };

        var vk_pipeline_layout: c.VkPipelineLayout = undefined;
        try vkt(c.vkCreatePipelineLayout(eng.get().gfx.platform.device, &pipeline_layout_info, null, &vk_pipeline_layout));
        errdefer c.vkDestroyPipelineLayout(eng.get().gfx.platform.device, vk_pipeline_layout, null);

        var attachment_descriptions = try arena.alloc(c.VkAttachmentDescription, attachments.items.len);
        defer arena.free(attachment_descriptions);

        for (attachments.items, 0..) |*a, idx| {
            _ = a;
            attachment_descriptions[idx] = c.VkAttachmentDescription {
                // @TODO
            };
        }

        var subpass_descriptions = try arena.alloc(c.VkSubpassDescription, subpass_refs.len);
        defer arena.free(subpass_descriptions);

        for (subpass_refs, 0..) |ref, idx| {
            var attachment_refs = try arena.alloc(c.VkAttachmentReference, ref.attachment_refs.len);
            // freed by arena allocator
            
            for (ref.attachment_refs, 0..) |aidx, ridx| {
                attachment_refs[aidx] = .{
                    .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, // @TODO: depth? other layouts?
                    .attachment = @intCast(ridx),
                };
            }

            subpass_descriptions[idx] = c.VkSubpassDescription{
                .pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS, // @TODO: compute? other?
                .pColorAttachments = @ptrCast(attachment_refs.ptr),
                .colorAttachmentCount = @intCast(attachment_refs.len),
                // @TODO: depth attachment, resolve attachments
            };
        }

        const render_pass_info = c.VkRenderPassCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,

            .pAttachments = @ptrCast(attachment_descriptions.ptr),
            .attachmentCount = @intCast(attachment_descriptions.len),

            .pSubpasses = @ptrCast(subpass_descriptions.ptr),
            .subpassCount = @intCast(subpass_descriptions.len),

            // @TODO: dependencies
        };

        var vk_render_pass: c.VkRenderPass = undefined;
        try vkt(c.vkCreateRenderPass(eng.get().gfx.platform.device, &render_pass_info, null, &vk_render_pass));
        errdefer c.vkDestroyRenderPass(eng.get().gfx.platform.device, vk_render_pass, null);

        const graphics_pipeline_info = c.VkGraphicsPipelineCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,

            .pStages = null, // @TODO
            .stageCount = 0, //

            .pVertexInputState = &vertex_input_info,
            .pInputAssemblyState = &input_assembly_info,
            .pViewportState = &viewport_info,
            .pRasterizationState = &rasterizer_info,
            .pTessellationState = null, // @TODO
            .pMultisampleState = &multisample_info,
            .pDepthStencilState = &depth_info,
            .pColorBlendState = &color_blend_info,
            .pDynamicState = &dynamic_state_info,

            .layout = vk_pipeline_layout,
            .renderPass = vk_render_pass,
            .subpass = 0,

            .basePipelineIndex = -1,
            .basePipelineHandle = c.VK_NULL_HANDLE,
        };

        var vk_graphics_pipeline: c.VkPipeline = undefined;
        try vkt(c.vkCreateGraphicsPipelines(eng.get().gfx.platform.device, c.VK_NULL_HANDLE, 1, &graphics_pipeline_info, null, &vk_graphics_pipeline));
        errdefer c.vkDestroyPipeline(eng.get().gfx.platform.device, vk_graphics_pipeline, null);

        return Self {
            .vk_pipeline_layout = vk_pipeline_layout,
            .vk_render_pass = vk_render_pass,
            .vk_graphics_pipeline = vk_graphics_pipeline,
        };
    }
};
