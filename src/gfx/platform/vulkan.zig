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
    pub const Image = ImageVulkan;
    pub const ImageView = ImageViewVulkan;
    pub const Sampler = SamplerVulkan;

    pub const RenderPass = RenderPassVulkan;
    pub const GraphicsPipeline = GraphicsPipelineVulkan;
    pub const FrameBuffer = FrameBufferVulkan;

    pub const DescriptorLayout = DescriptorLayoutVulkan;
    pub const DescriptorPool = DescriptorPoolVulkan;
    pub const DescriptorSet = DescriptorSetVulkan;

    pub const CommandPool = CommandPoolVulkan;
    pub const CommandBuffer = CommandPoolVulkan;

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
        width: u32,
        height: u32,
        format: c.VkSurfaceFormatKHR,
        present_mode: c.VkPresentModeKHR,
    };

    fn create_swapchain(self: *Self, opt: SwapchainCreateOptions) !SwapchainInfo {
        var surface_capabilities: c.VkSurfaceCapabilitiesKHR = undefined;
        try vkt(c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(self.physical_device, self.surface, &surface_capabilities));

        var swapchain_extent = surface_capabilities.currentExtent;
        if (swapchain_extent.width == std.math.maxInt(u32)) {
            swapchain_extent = c.VkExtent2D {
                .width = std.math.clamp(@as(u32, @intCast(opt.width)),
                    surface_capabilities.minImageExtent.width, surface_capabilities.maxImageExtent.width),
                .height = std.math.clamp(@as(u32, @intCast(opt.height)),
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

    pub inline fn get() *Self {
        return &eng.get().gfx.platform;
    }

    pub inline fn swapchain_size(self: *const Self) [2]u32 {
        return .{ self.swapchain.extent.width, self.swapchain.extent.height };
    }

    pub inline fn begin_frame(self: *Self) !gf.RenderTargetView {
        _ = self;
        return gf.RenderTargetView {};
    }

    pub inline fn present(self: *Self) !void {
        _ = self;
    }

    pub inline fn flush(self: *Self) void {
        vkt(c.vkDeviceWaitIdle(self.device)) catch |err| {
            std.log.err("Unable to wait for vulkan device idle: {}", .{err});
            // probably device lost
            unreachable;
        };
    }

    pub inline fn resize_swapchain(self: *Self, new_width: u32, new_height: u32) void {
        const new_swapchain = try self.create_swapchain(.{
            .width = @intCast(new_width),
            .height = @intCast(new_height),
            .format = self.swapchain.format,
            .present_mode = self.swapchain.present_mode,
        });
        errdefer self.swapchain.deinit(self.device);

        self.swapchain.deinit(self.device);
        self.swapchain = new_swapchain;

        // TODO recreate all dependant vulkan objects
        unreachable;
    }

    pub fn get_queue_family_index(self: *const Self, queue_family: gf.QueueFamily) u32 {
        return switch (queue_family) {
            .Graphics, .Compute => self.queues.all_family_index,
            .Transfer => self.queues.cpu_gpu_transfer_family_index,
        };
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
    ) !Self {
        const gfx = gf.GfxState.get();
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
    
    pub fn deinit(self: *const Self) void {
        const alloc = eng.get().gfx.platform.alloc;
        
        self.shader_module.deinit();
        alloc.free(self.vk_vertex_input_attrib_description);
        alloc.free(self.vk_vertex_input_binding_description);
    }

    pub fn init_buffer(
        vs_data: []const u8,
        vs_func: []const u8,
        vs_layout: []const gf.VertexInputLayoutEntry,
        options: gf.VertexShaderOptions,
    ) !Self {
        _ = options;
        const gfx = gf.GfxState.get();
        const alloc = gfx.platform.alloc;

        const shader_module = try ShaderModule.init(vs_data, vs_func, gf.ShaderStage.Vertex);
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
    
    pub fn deinit(self: *const Self) void {
        self.shader_module.deinit();
    }
    
    pub fn init_buffer(
        ps_data: []const u8, 
        ps_func: []const u8, 
        options: gf.PixelShaderOptions,
    ) !Self {
        _ = options;

        const shader_module = try ShaderModule.init(ps_data, ps_func, gf.ShaderStage.Pixel);
        errdefer shader_module.deinit();

        return .{
            .shader_module = shader_module,
        };
    }
};

pub const HullShaderVulkan = struct {
    const Self = @This();
    
    pub fn deinit(self: *const Self) void {
        _ = self;
    }
    
    pub fn init_buffer(
        hs_data: []const u8, 
        hs_func: []const u8, 
        options: gf.HullShaderOptions,
    ) !Self {
        _ = hs_data;
        _ = hs_func;
        _ = options;
        return .{};
    }
};

pub const DomainShaderVulkan = struct {
    const Self = @This();
    
    pub fn deinit(self: *const Self) void {
        _ = self;
    }
    
    pub fn init_buffer(
        ds_data: []const u8, 
        ds_func: []const u8, 
        options: gf.DomainShaderOptions,
    ) !Self {
        _ = ds_data;
        _ = ds_func;
        _ = options;
        return .{};
    }
};

pub const GeometryShaderVulkan = struct {
    const Self = @This();
    
    pub fn deinit(self: *const Self) void {
        _ = self;
    }
    
    pub fn init_buffer(
        gs_data: []const u8, 
        gs_func: []const u8, 
        options: gf.GeometryShaderOptions,
    ) !Self {
        _ = gs_data;
        _ = gs_func;
        _ = options;
        return .{};
    }
};

pub const ComputeShaderVulkan = struct {
    const Self = @This();
    
    pub fn deinit(self: *const Self) void {
        _ = self;
    }
    
    pub fn init_buffer(
        cs_data: []const u8, 
        cs_func: []const u8,
        options: gf.ComputeShaderOptions,
    ) !Self {
        _ = cs_data;
        _ = cs_func;
        _ = options;
        return .{};
    }
};

inline fn rect_to_vulkan(rect: Rect) c.VkRect2D {
    return c.VkRect2D {
        .offset = .{
            .x = rect.left,
            .y = rect.top,
        },
        .extent = .{
            .width = rect.width(),
            .height = rect.height(),
        },
    };
}

fn indexformat_to_vulkan(indexformat: gf.IndexFormat) c.VkIndexType {
    return switch (indexformat) {
        .U16 => c.VK_INDEX_TYPE_UINT16,
        .U32 => c.VK_INDEX_TYPE_UINT32,
    };
}

fn convert_buffer_usage_flags_to_vulkan(usage: gf.BufferUsageFlags) c.VkBufferUsageFlags {
    var flags: c.VkBufferUsageFlags = 0;

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

fn convert_texture_usage_flags_to_vulkan(usage: gf.TextureUsageFlags) c.VkImageUsageFlags {
    var flags: c.VkImageUsageFlags = 0;

    if (usage.ShaderResource) {
        flags |= c.VK_IMAGE_USAGE_SAMPLED_BIT;
    }
    if (usage.RenderTarget) {
        flags |= c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    }
    if (usage.DepthStencil) {
        flags |= c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT;
    }
    if (usage.TransferSrc) {
        flags |= c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
    }
    if (usage.TransferDst) {
        flags |= c.VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    }

    return flags;
}

fn find_vulkan_memory_type(type_filter: u32, property_flags: c.VkMemoryPropertyFlags) !u32 {
    var vk_mem_properties: c.VkPhysicalDeviceMemoryProperties = undefined;
    c.vkGetPhysicalDeviceMemoryProperties(GfxStateVulkan.get().physical_device, &vk_mem_properties);

    for (vk_mem_properties.memoryTypes[0..(vk_mem_properties.memoryTypeCount)], 0..) |mem_type, idx| {
        const contains_all_properties = ((mem_type.propertyFlags & property_flags) == property_flags);
        if ((type_filter & (@as(u32, 1) << @intCast(idx)) != 0) and contains_all_properties) {
            return @intCast(idx);
        }
    }

    return error.CouldNotFindSuitableVulkanMemory;
}

fn begin_single_time_command_buffer(command_pool: c.VkCommandPool) !c.VkCommandBuffer {
    const alloc_info = c.VkCommandBufferAllocateInfo {
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandBufferCount = 1,
        .commandPool = GfxStateVulkan.get().all_command_pool,
        .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
    };

    var vk_command_buffer: c.VkCommandBuffer = undefined;
    try vkt(c.vkAllocateCommandBuffers(GfxStateVulkan.get().device, &alloc_info, &vk_command_buffer));
    errdefer c.vkFreeCommandBuffers(GfxStateVulkan.get().device, command_pool, 1, &vk_command_buffer);

    const begin_info = c.VkCommandBufferBeginInfo {
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };

    try vkt(c.vkBeginCommandBuffer(vk_command_buffer, &begin_info));
    errdefer c.vkEndCommandBuffer(vk_command_buffer);

    return vk_command_buffer;
}

fn end_single_time_command_buffer(command_pool: c.VkCommandPool, command_buffer: c.VkCommandBuffer) void {
    if (vkt(c.vkEndCommandBuffer(command_buffer))) {
        const submit_info = c.VkSubmitInfo {
            .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .commandBufferCount = 1,
            .pCommandBuffers = &command_buffer,
        };
        
        vkt(c.vkQueueSubmit(GfxStateVulkan.get().queues.all, 1, &submit_info, @ptrCast(c.VK_NULL_HANDLE))) catch |err| {
            std.log.warn("Unable to submit one time command buffer: {}", .{err});
        };
        vkt(c.vkQueueWaitIdle(GfxStateVulkan.get().queues.all)) catch {};
    } else |err| {
        std.log.warn("Unable to end command buffer: {}", .{err});
    }

    c.vkFreeCommandBuffers(GfxStateVulkan.get().device, command_pool, 1, &command_buffer);
}

pub const BufferVulkan = struct {
    const Self = @This();

    vk_buffer_info: c.VkBufferCreateInfo,
    vk_buffer: c.VkBuffer,
    vk_device_memory: c.VkDeviceMemory,

    pub fn deinit(self: *const Self) void {
        c.vkFreeMemory(eng.get().gfx.platform.device, self.vk_device_memory, null);
        c.vkDestroyBuffer(eng.get().gfx.platform.device, self.vk_buffer, null);
    }

    pub fn init(
        byte_size: u32,
        usage_flags: gf.BufferUsageFlags,
        access_flags: gf.AccessFlags,
    ) !Self {
        // @TODO: use the dedicated transfer queue
        const use_shared = false; // gfx.platform.queues.has_distinct_transfer_queue() and
            // (access_flags.CpuRead or access_flags.CpuWrite);
        const family_indices: []const u32 = &.{
            GfxStateVulkan.get().queues.all_family_index,
            GfxStateVulkan.get().queues.cpu_gpu_transfer_family_index
        };

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
        try vkt(c.vkCreateBuffer(GfxStateVulkan.get().device, &buffer_create_info, null, &vk_buffer));
        errdefer c.vkDestroyBuffer(GfxStateVulkan.get().device, vk_buffer, null);

        var vk_memory_requirements: c.VkMemoryRequirements = undefined;
        c.vkGetBufferMemoryRequirements(GfxStateVulkan.get().device, vk_buffer, &vk_memory_requirements);

        const memory_properties: c.VkMemoryPropertyFlags = if (access_flags.CpuRead or access_flags.CpuWrite)
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT
            else c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;

        const memory_allocate_info = c.VkMemoryAllocateInfo {
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = vk_memory_requirements.size,
            .memoryTypeIndex = try find_vulkan_memory_type(
                vk_memory_requirements.memoryTypeBits,
                memory_properties,
            ),
        };

        // TODO better memory allocation strategy
        var vk_device_memory: c.VkDeviceMemory = undefined;
        try vkt(c.vkAllocateMemory(GfxStateVulkan.get().device, &memory_allocate_info, null, &vk_device_memory));
        errdefer c.vkFreeMemory(GfxStateVulkan.get().device, vk_device_memory, null);

        try vkt(c.vkBindBufferMemory(GfxStateVulkan.get().device, vk_buffer, vk_device_memory, 0));

        return .{
            .vk_buffer_info = buffer_create_info,
            .vk_buffer = vk_buffer,
            .vk_device_memory = vk_device_memory,
        };
    }
    
    pub fn init_with_data(
        data: []const u8,
        usage_flags: gf.BufferUsageFlags,
        access_flags: gf.AccessFlags,
    ) !Self {
        var usage_flags_plus = usage_flags;
        usage_flags_plus.TransferDst = true;

        const self = try Self.init(@intCast(data.len), usage_flags_plus, access_flags);
        errdefer self.deinit();

        const staging = try Self.init(
            @intCast(data.len), 
            .{ .TransferSrc = true, },
            .{ .CpuWrite = true, },
        );
        defer staging.deinit();

        {
            var data_ptr: ?*anyopaque = undefined;
            try vkt(c.vkMapMemory(GfxStateVulkan.get().device, staging.vk_device_memory, 0, staging.vk_buffer_info.size, 0, &data_ptr));
            defer c.vkUnmapMemory(GfxStateVulkan.get().device, staging.vk_device_memory);

            @memcpy(@as([*]u8, @ptrCast(data_ptr))[0..(staging.vk_buffer_info.size)], data[0..]);
        }

        const command_buffer = try begin_single_time_command_buffer(GfxStateVulkan.get().all_command_pool);

        const buffer_copy_region = c.VkBufferCopy {
            .size = staging.vk_buffer_info.size,
            .dstOffset = 0,
            .srcOffset = 0,
        };
        c.vkCmdCopyBuffer(command_buffer, staging.vk_buffer, self.vk_buffer, 1, &buffer_copy_region);

        end_single_time_command_buffer(GfxStateVulkan.get().all_command_pool, command_buffer);

        return self;
    }

    pub fn map(self: *const Self, options: gf.Buffer.MapOptions) !MappedBuffer {
        _ = options;
        var data_ptr: ?*anyopaque = undefined;
        try vkt(c.vkMapMemory(GfxStateVulkan.get().device, self.vk_device_memory, 0, self.vk_buffer_info.size, 0, &data_ptr));

        return MappedBuffer {
            .data_ptr = data_ptr,
            .device_memory = self.vk_device_memory,
        };
    }

    pub const MappedBuffer = struct {
        data_ptr: ?*anyopaque,
        device_memory: c.VkDeviceMemory,

        pub inline fn unmap(self: *const MappedBuffer) void {
            c.vkUnmapMemory(GfxStateVulkan.get().device, self.device_memory);
        }

        pub inline fn data(self: *const MappedBuffer, comptime Type: type) *Type {
            return @alignCast(@ptrCast(self.data_ptr));
        }

        pub inline fn data_array(self: *const MappedBuffer, comptime Type: type, length: usize) []Type {
            return @as([*]Type, @alignCast(@ptrCast(self.data_ptr)))[0..(length)];
        }
    };

};

pub const ImageVulkan = struct {
    const Self = @This();

    alloc: std.mem.Allocator,
    false_data: []u8,

    vk_image: c.VkImage,
    vk_device_memory: c.VkDeviceMemory,
    vk_layout: c.VkImageLayout,
    vk_format: c.VkFormat,

    pub fn deinit(self: *const Self) void {
        self.alloc.free(self.false_data);
        c.vkFreeMemory(GfxStateVulkan.get().device, self.vk_device_memory, null);
        c.vkDestroyImage(GfxStateVulkan.get().device, self.vk_image, null);
    }

    pub fn init(
        info: gf.ImageInfo,
        data: ?[]const u8,
    ) !Self {
        const alloc = GfxStateVulkan.get().alloc;
        const false_data = if (data) |d| try alloc.dupe(u8, d) 
            else try alloc.alloc(u8, info.height * info.width * info.array_length * info.format.byte_width());

        var usage_flags_plus = info.usage_flags;
        if (data != null) {
            usage_flags_plus.TransferDst = true;
        }
        const vk_usage_flags = convert_texture_usage_flags_to_vulkan(usage_flags_plus);

        const vk_format = textureformat_to_vulkan(info.format);

        const vk_layout = c.VK_IMAGE_LAYOUT_UNDEFINED;

        const image_info = c.VkImageCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .format = vk_format,
            .imageType = c.VK_IMAGE_TYPE_2D,
            .extent = c.VkExtent3D {
                .width = info.width,
                .height = info.height,
                .depth = 1,
            },
            .mipLevels = info.mip_levels,
            .arrayLayers = info.array_length,
            .tiling = c.VK_IMAGE_TILING_OPTIMAL,
            .initialLayout = vk_layout,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .samples = c.VK_SAMPLE_COUNT_1_BIT,
            .usage = vk_usage_flags,
        };

        var vk_image: c.VkImage = undefined;
        try vkt(c.vkCreateImage(GfxStateVulkan.get().device, &image_info, null, &vk_image));
        errdefer c.vkDestroyImage(GfxStateVulkan.get().device, vk_image, null);

        var memory_requirements: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(GfxStateVulkan.get().device, vk_image, &memory_requirements);

        const alloc_info = c.VkMemoryAllocateInfo {
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = memory_requirements.size,
            .memoryTypeIndex = try find_vulkan_memory_type(memory_requirements.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT),
        };

        // TODO better memory allocation strategy
        var vk_device_memory: c.VkDeviceMemory = undefined;
        try vkt(c.vkAllocateMemory(GfxStateVulkan.get().device, &alloc_info, null, &vk_device_memory));
        errdefer c.vkFreeMemory(GfxStateVulkan.get().device, vk_device_memory, null);

        try vkt(c.vkBindImageMemory(GfxStateVulkan.get().device, vk_image, vk_device_memory, 0));

        var self = Self {
            .alloc = alloc,
            .false_data = false_data,

            .vk_image = vk_image,
            .vk_device_memory = vk_device_memory,
            .vk_layout = c.VK_IMAGE_LAYOUT_UNDEFINED,
            .vk_format = vk_format,
        };

        if (data) |d| {
            const buffer_length = info.width * info.height * info.array_length * info.format.byte_width();
            const staging_buffer = try BufferVulkan.init(
                @intCast(buffer_length),
                .{ .TransferSrc = true, },
                .{ .CpuWrite = true, },
            );
            defer staging_buffer.deinit();

            {
                var mapped_buffer = try staging_buffer.map(.{ .write = true, });
                defer mapped_buffer.unmap();

                const mapped_slice = mapped_buffer.data_array(u8, buffer_length);
                @memcpy(mapped_slice, d);
            }

            try self.transition_layout(c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);

            const command_buffer = try begin_single_time_command_buffer(GfxStateVulkan.get().all_command_pool);
            const region = c.VkBufferImageCopy {
                .bufferOffset = 0,
                .bufferRowLength = 0,
                .bufferImageHeight = 0,

                .imageSubresource = .{
                    .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                    .mipLevel = 0,
                    .baseArrayLayer = 0,
                    .layerCount = 1,
                },

                .imageOffset = .{ .x = 0, .y = 0, .z = 0, },
                .imageExtent = .{
                    .width = info.width,
                    .height = info.height,
                    .depth = 1,
                }
            };
            c.vkCmdCopyBufferToImage(command_buffer, staging_buffer.vk_buffer, vk_image, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
            end_single_time_command_buffer(GfxStateVulkan.get().all_command_pool, command_buffer);

            try self.transition_layout(vk_layout);
        }

        return self;
    }

    pub fn map(self: *const Self, options: gf.Image.MapOptions) !MappedImage {
        _ = self;
        _ = options;
        return error.NotImplemented;
    }

    pub const MappedImage = struct {

        pub fn unmap(self: *const MappedImage) void {
            _ = self;
        }

        pub fn data(self: *const MappedImage, comptime Type: type) [*]align(16)Type {
            _ = self;
            unreachable;
        }
    };

    fn transition_layout(self: *Self, new_layout: c.VkImageLayout) !void {
        const command_buffer = try begin_single_time_command_buffer(GfxStateVulkan.get().all_command_pool);

        var src_access: c.VkAccessFlags = 0;
        var dst_access: c.VkAccessFlags = 0;

        var src_stage: c.VkPipelineStageFlags = 0;
        var dst_stage: c.VkPipelineStageFlags = 0;

        switch (self.vk_layout) {
            c.VK_IMAGE_LAYOUT_UNDEFINED => {},
            c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL => {
                src_access = c.VK_ACCESS_TRANSFER_WRITE_BIT;
                src_stage = c.VK_PIPELINE_STAGE_TRANSFER_BIT;
            },
            else => unreachable,
        }

        switch (new_layout) {
            c.VK_IMAGE_LAYOUT_UNDEFINED => {},
            c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL => {
                dst_access = c.VK_ACCESS_SHADER_READ_BIT;
                dst_stage = c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT; // TODO this could be any stage..
            },
            c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL => {
                dst_access = c.VK_ACCESS_TRANSFER_WRITE_BIT;
                dst_stage = c.VK_PIPELINE_STAGE_TRANSFER_BIT;
            },
            else => unreachable,
        }

        const image_barrier = c.VkImageMemoryBarrier {
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .image = self.vk_image,
            .oldLayout = self.vk_layout,
            .newLayout = new_layout,
            .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .srcAccessMask = src_access,
            .dstAccessMask = dst_access,
            .subresourceRange = .{
                .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 1,
                .layerCount = 1,
            },
        };
        c.vkCmdPipelineBarrier(
            command_buffer, 
            src_stage, 
            dst_stage, 
            0, 
            0, null,
            0, null,
            1, &image_barrier
        );

        end_single_time_command_buffer(GfxStateVulkan.get().all_command_pool, command_buffer);

        self.vk_layout = new_layout;
    }
};

pub const ImageViewVulkan = struct {
    vk_image_view: c.VkImageView,
    
    pub fn deinit(self: *const ImageViewVulkan) void {
        c.vkDestroyImageView(GfxStateVulkan.get().device, self.vk_image_view, null);
    }

    pub fn init(info: gf.ImageViewInfo) !ImageViewVulkan {
        const img = gf.GfxState.get().images.get(info.image.id) orelse return error.UnableToRetrieveImage;

        const view_type: c.VkImageViewType = blk: { // TODO cube
            if (img.info.depth == 1) {
                break :blk 
                    if (info.array_layer_count == 1) c.VK_IMAGE_VIEW_TYPE_2D
                    else c.VK_IMAGE_VIEW_TYPE_2D_ARRAY;
            } else {
                break :blk
                    if (info.array_layer_count == 1) c.VK_IMAGE_VIEW_TYPE_3D
                    else return error.CannotCreateImageView3DArray;
            }
        };

        const image_view_info = c.VkImageViewCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .image = img.platform.vk_image, 
            .viewType = view_type,
            .format = img.platform.vk_format,
            .subresourceRange = .{
                .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, // Depth?
                .baseMipLevel = info.base_mip_level,
                .levelCount = info.mip_level_count,
                .baseArrayLayer = info.base_array_layer,
                .layerCount = info.array_layer_count,
            },
        };

        var vk_image_view: c.VkImageView = undefined;
        try vkt(c.vkCreateImageView(GfxStateVulkan.get().device, &image_view_info, null, &vk_image_view));
        errdefer c.vkDestroyImageView(GfxStateVulkan.get().device, vk_image_view, null);

        return ImageViewVulkan {
            .vk_image_view = vk_image_view,
        };
    }
};

inline fn samplerfilter_to_vulkan(filter: gf.SamplerFilter) c.VkFilter {
    return switch (filter) {
        .Linear => c.VK_FILTER_LINEAR,
        .Point => c.VK_FILTER_NEAREST,
    };
}

inline fn samplerbordermode_to_vulkan(bordermode: gf.SamplerBorderMode) c.VkSamplerAddressMode {
    return switch (bordermode) {
        .BorderColour => c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER,
        .Clamp => c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .Mirror => c.VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT,
        .Wrap => c.VK_SAMPLER_ADDRESS_MODE_REPEAT,
    };
}

pub const SamplerVulkan = struct {
    const Self = @This();

    vk_sampler: c.VkSampler,

    pub fn deinit(self: *const Self) void {
        c.vkDestroySampler(GfxStateVulkan.get().device, self.vk_sampler, null);
    }

    pub fn init(info: gf.SamplerDescriptor) !Self {
        const sampler_info = c.VkSamplerCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            
            .magFilter = samplerfilter_to_vulkan(info.filter_min_mag),
            .minFilter = samplerfilter_to_vulkan(info.filter_min_mag),

            .mipmapMode = samplerfilter_to_vulkan(info.filter_mip),
            .mipLodBias = 0.0,

            .addressModeU = samplerbordermode_to_vulkan(info.border_mode),
            .addressModeV = samplerbordermode_to_vulkan(info.border_mode),
            .addressModeW = samplerbordermode_to_vulkan(info.border_mode),

            .anisotropyEnable = bool_to_vulkan(info.anisotropic_filter),
            .maxAnisotropy = 1, // TODO
            
            .borderColor = c.VK_BORDER_COLOR_FLOAT_OPAQUE_BLACK, // todo?

            .minLod = info.min_lod,
            .maxLod = info.max_lod,

            .unnormalizedCoordinates = c.VK_FALSE,
            
            .compareEnable = c.VK_FALSE,
            .compareOp = c.VK_COMPARE_OP_ALWAYS,
        };

        var vk_sampler: c.VkSampler = undefined;
        try vkt(c.vkCreateSampler(GfxStateVulkan.get().device, &sampler_info, null, &vk_sampler));
        errdefer c.vkDestroySampler(GfxStateVulkan.get().device, vk_sampler, null);

        return Self {
            .vk_sampler = vk_sampler,
        };
    }
};

fn formatclearvalue_to_vulkan(format: gf.ImageFormat, clear_value: zm.F32x4) c.VkClearValue {
    if (format.is_depth()) {
        return c.VkClearValue {
            .depthStencil = .{
                .depth = clear_value[0],
                .stencil = @intFromFloat(clear_value[1]),
            }
        };
    } else {
        return switch (format) {
            .Rgba8_Unorm_Srgb,
            .Rgba8_Unorm,
            .Bgra8_Unorm,
            .R24X8_Unorm_Uint,
            .D24S8_Unorm_Uint,
            .R32_Uint => c.VkClearValue {
                .color = .{ .uint32 = .{
                    @intFromFloat(clear_value[0]),
                    @intFromFloat(clear_value[1]),
                    @intFromFloat(clear_value[2]),
                    @intFromFloat(clear_value[3]),
                } }
            },
            .Unknown,
            .R32_Float,
            .Rg32_Float,
            .Rgba16_Float,
            .Rgba32_Float,
            .Rg11b10_Float =>  c.VkClearValue {
                .color = .{ .float32 = .{
                    clear_value[0],
                    clear_value[1],
                    clear_value[2],
                    clear_value[3],
                } }
            },
        };
    }
}

pub const RenderPassVulkan = struct {
    const Self = @This();
    
    vk_render_pass: c.VkRenderPass,
    vk_clear_values: []c.VkClearValue,

    pub fn deinit(self: *const Self) void {
        c.vkDestroyRenderPass(GfxStateVulkan.get().device, self.vk_render_pass, null);
        GfxStateVulkan.get().alloc.free(self.vk_clear_values);
    }

    pub fn init(info: gf.RenderPassInfo) !RenderPassVulkan {
        const alloc = GfxStateVulkan.get().alloc;

        const arena_obj = std.heap.ArenaAllocator.init(alloc);
        defer arena_obj.deinit();
        const arena = arena_obj.allocator();

        const SubpassRefInfo = struct {
            attachment_refs: []usize,
        };
        var subpass_refs = try arena.alloc(SubpassRefInfo, info.subpasses.len);
        arena.free(subpass_refs);

        for (info.subpasses, 0..) |subpass, sidx| {
            subpass_refs[sidx].attachment_refs = try arena.alloc(usize, subpass.attachments.len);

            for (subpass.attachments, 0..) |subpass_attachment_name, subpass_aidx| {
                const found_aidx: ?usize = for (info.attachments, 0..) |attachment, aidx| {
                    if (std.mem.eql(u8, attachment.name, subpass_attachment_name)) {
                        break aidx;
                    }
                } else null;

                if (found_aidx == null) { return error.SubpassAttachmentNameNotFound; }
                subpass_refs[sidx].attachment_refs[subpass_aidx] = found_aidx.?;
            }
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

        var attachment_descriptions = try arena.alloc(c.VkAttachmentDescription, info.attachments.len);
        defer arena.free(attachment_descriptions);

        var vk_clear_values = try alloc.alloc(c.VkClearValue, info.attachments.len);
        errdefer alloc.free(vk_clear_values);

        for (info.attachments, 0..) |*a, idx| {
            attachment_descriptions[idx] = c.VkAttachmentDescription {
                .format = textureformat_to_vulkan(a.format),
                .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
                .finalLayout = c.VK_IMAGE_LAYOUT_ATTACHMENT_OPTIMAL, // TODO
                .loadOp = loadop_to_vulkan(a.load_op),
                .storeOp = storeop_to_vulkan(a.store_op),
                .stencilLoadOp = loadop_to_vulkan(a.stencil_load_op),
                .stencilStoreOp = storeop_to_vulkan(a.stencil_store_op),
            };

            vk_clear_values[idx] = formatclearvalue_to_vulkan(a.format, a.clear_value);
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

        return RenderPassVulkan {
            .vk_render_pass = vk_render_pass,
            .vk_clear_values = vk_clear_values,
        };
    }
};

inline fn textureformat_to_vulkan(format: gf.ImageFormat) c.VkFormat {
    return switch (format) {
        .R32_Float => c.VK_FORMAT_R32_SFLOAT,
        .Rg32_Float => c.VK_FORMAT_R32G32_SFLOAT,
        .Rgba32_Float => c.VK_FORMAT_R32G32B32A32_SFLOAT,
        .Rgba16_Float => c.VK_FORMAT_R16G16B16A16_SFLOAT,
        .R32_Uint => c.VK_FORMAT_R32_UINT,
        .Bgra8_Unorm => c.VK_FORMAT_B8G8R8A8_UNORM,
        .D24S8_Unorm_Uint => c.VK_FORMAT_D24_UNORM_S8_UINT,
        .R24X8_Unorm_Uint => c.VK_FORMAT_D24_UNORM_S8_UINT,
        .Rg11b10_Float => c.VK_FORMAT_B10G11R11_UFLOAT_PACK32,
        .Rgba8_Unorm => c.VK_FORMAT_R8G8B8A8_UNORM,
        .Rgba8_Unorm_Srgb => c.VK_FORMAT_R8G8B8A8_SRGB,
        .Unknown => c.VK_FORMAT_UNDEFINED,
    };
}

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

inline fn bool_to_vulkan(b: bool) c_uint {
    return if (b) c.VK_TRUE else c.VK_FALSE;
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

inline fn blendtype_to_vulkan(blendtype: gf.BlendType) c.VkPipelineColorBlendAttachmentState {
    return switch (blendtype) {
        .None => c.VkPipelineColorBlendAttachmentState {
            .blendEnable = c.VK_FALSE,
            .colorWriteMask =   c.VK_COLOR_COMPONENT_R_BIT |
                c.VK_COLOR_COMPONENT_G_BIT |
                c.VK_COLOR_COMPONENT_B_BIT |
                c.VK_COLOR_COMPONENT_A_BIT,
            .srcColorBlendFactor = c.VK_BLEND_FACTOR_ONE,
            .dstColorBlendFactor = c.VK_BLEND_FACTOR_ZERO,
            .colorBlendOp = c.VK_BLEND_OP_ADD,
            .srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE,
            .dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ZERO,
            .alphaBlendOp = c.VK_BLEND_OP_ADD,
        },
        .Simple => c.VkPipelineColorBlendAttachmentState {
            .blendEnable = c.VK_TRUE,
            .colorWriteMask =   c.VK_COLOR_COMPONENT_R_BIT |
                c.VK_COLOR_COMPONENT_G_BIT |
                c.VK_COLOR_COMPONENT_B_BIT |
                c.VK_COLOR_COMPONENT_A_BIT,
            .srcColorBlendFactor = c.VK_BLEND_FACTOR_SRC_ALPHA,
            .dstColorBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            .colorBlendOp = c.VK_BLEND_OP_ADD,
            .srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ZERO,
            .dstAlphaBlendFactor = c.VK_BLEND_FACTOR_DST_ALPHA,
            .alphaBlendOp = c.VK_BLEND_OP_ADD,
        },
        .PremultipliedAlpha => c.VkPipelineColorBlendAttachmentState {
            .blendEnable = c.VK_TRUE,
            .colorWriteMask =   c.VK_COLOR_COMPONENT_R_BIT |
                c.VK_COLOR_COMPONENT_G_BIT |
                c.VK_COLOR_COMPONENT_B_BIT |
                c.VK_COLOR_COMPONENT_A_BIT,
            .srcColorBlendFactor = c.VK_BLEND_FACTOR_ONE,
            .dstColorBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            .colorBlendOp = c.VK_BLEND_OP_ADD,
            .srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE,
            .dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ZERO,
            .alphaBlendOp = c.VK_BLEND_OP_ADD,
        },
    };
}

inline fn loadop_to_vulkan(loadop: gf.AttachmentLoadOp) c.VkAttachmentLoadOp {
    return switch (loadop) {
        .Clear => c.VK_ATTACHMENT_LOAD_OP_CLEAR,
        .DontCare => c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .Load => c.VK_ATTACHMENT_LOAD_OP_LOAD,
    };
}

inline fn storeop_to_vulkan(storeop: gf.AttachmentStoreOp) c.VkAttachmentStoreOp {
    return switch (storeop) {
        .DontCare => c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .Store => c.VK_ATTACHMENT_STORE_OP_STORE,
    };
}

pub const GraphicsPipelineVulkan = struct {
    const Self = @This();

    vk_pipeline_layout: c.VkPipelineLayout,
    vk_graphics_pipeline: c.VkPipeline,

    pub fn deinit(self: *const Self) void {
        const device = eng.get().gfx.platform.device;
        c.vkDestroyPipeline(device, self.vk_graphics_pipeline, null);
        c.vkDestroyPipelineLayout(device, self.vk_pipeline_layout, null);
    }
    
    pub fn init(info: gf.GraphicsPipelineInfo) !Self {
        const render_pass = try info.render_pass.get();

        const alloc = eng.get().frame_allocator;
        var arena_struct = std.heap.ArenaAllocator.init(alloc);
        defer arena_struct.deinit();
        const arena = arena_struct.allocator();
        
        const dynamic_states: []const c.VkDynamicState = &.{
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
            .depthCompareOp = if (info.depth_test) |d| compareop_to_vulkan(d.compare_op) else c.VK_COMPARE_OP_ALWAYS,
            .depthWriteEnable = if (info.depth_test) |d| bool_to_vulkan(d.write) else c.VK_FALSE,
            .stencilTestEnable = c.VK_FALSE, // @TODO
            .depthBoundsTestEnable = c.VK_FALSE,
        };


        var color_blend_attachments = try arena.alloc(c.VkPipelineColorBlendAttachmentState, info.attachments.len);
        defer arena.free(color_blend_attachments);

        for (info.attachments, 0..) |*a, idx| {
            color_blend_attachments[idx] = blendtype_to_vulkan(a.blend_type); 
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
            .renderPass = render_pass.platform.vk_render_pass,
            .subpass = info.subpass_index,

            .basePipelineIndex = -1,
            .basePipelineHandle = @ptrCast(c.VK_NULL_HANDLE),
        };

        var vk_graphics_pipeline: c.VkPipeline = undefined;
        try vkt(c.vkCreateGraphicsPipelines(eng.get().gfx.platform.device, @ptrCast(c.VK_NULL_HANDLE), 1, &graphics_pipeline_info, null, &vk_graphics_pipeline));
        errdefer c.vkDestroyPipeline(eng.get().gfx.platform.device, vk_graphics_pipeline, null);

        return Self {
            .vk_pipeline_layout = vk_pipeline_layout,
            .vk_graphics_pipeline = vk_graphics_pipeline,
        };
    }
};

const FrameBufferAttachmentExtent = struct {
    width: u32,
    height: u32,
    layers: u32,

    pub fn eql(self: *const FrameBufferAttachmentExtent, oth: FrameBufferAttachmentExtent) bool {
        return 
            self.width == oth.width and
            self.height == oth.height and
            self.layers == oth.layers;
    }
};

inline fn framebufferattachment_extent(framebuffer_attachment: gf.FrameBufferAttachmentInfo) FrameBufferAttachmentExtent {
    return switch (framebuffer_attachment) {
        .Swapchain => .{
            .width = GfxStateVulkan.get().swapchain.extent.width,
            .height = GfxStateVulkan.get().swapchain.extent.height,
            .layers = 1,
        },
        .SwapchainDepth => .{
            .width = GfxStateVulkan.get().swapchain.extent.width,
            .height = GfxStateVulkan.get().swapchain.extent.height,
            .layers = 1,
        },
        .View => |v| blk: {
            const view = v.get() catch unreachable;
            break :blk .{
                .width = view.size.width,
                .height = view.size.height,
                .layers = view.info.array_layer_count,
            };
        },
    };
}

pub const FrameBufferVulkan = struct {
    vk_framebuffers: []c.VkFramebuffer,
    
    pub fn deinit(self: *const FrameBufferVulkan) void {
        for (self.vk_framebuffers) |f| {
            c.vkDestroyFramebuffer(eng.get().gfx.platform.device, f, null);
        }
        eng.get().general_allocator.free(self.vk_framebuffers);
    }

    pub fn init(info: gf.FrameBufferInfo) !FrameBufferVulkan {
        if (info.attachments.len == 0) { return error.NoAttachmentsProvided; }
        const render_pass = try info.render_pass.get();

        const alloc = eng.get().general_allocator;

        const create_multiple_for_frames_in_flight = blk: {
            var swapchain_index: ?usize = null;
            for (info.attachments, 0..) |a, i| {
                switch (a) {
                    .Swapchain => { swapchain_index = i; break; },
                    else => {},
                }
            }
            break :blk (swapchain_index != null);
        };

        const swapchain_images_count = eng.get().gfx.platform.swapchain.images.items.len;
        const framebuffers = try alloc.alloc(c.VkFramebuffer, if (create_multiple_for_frames_in_flight) swapchain_images_count else 1);
        errdefer alloc.free(framebuffers);

        const framebuffer_extent = framebufferattachment_extent(info.attachments[0]);

        const attachments = try alloc.alloc(c.VkImageView, info.attachments.len);
        defer alloc.free(attachments);

        for (framebuffers, 0..) |*framebuffer, fidx| {
            for (info.attachments, 0..) |*a, aidx| {
                attachments[aidx] = switch (a.*) {
                    .Swapchain => GfxStateVulkan.get().swapchain.image_views.items[fidx],
                    .SwapchainDepth => blk: {
                        const view = try gf.GfxState.get().default.depth_view.get();
                        break :blk view.platform.vk_image_view;
                    },
                    .View => |v| blk: {
                        const view = try v.get();
                        break :blk view.platform.vk_image_view;
                    },
                };

                const attachment_extent = framebufferattachment_extent(a.*);
                if (!attachment_extent.eql(framebuffer_extent)) {
                    return error.AttachmentsHaveDifferentExtents;
                }
            }

            const framebuffer_info = c.VkFramebufferCreateInfo {
                .sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
                .renderPass = render_pass.platform.vk_render_pass,
                .pAttachments = @ptrCast(attachments.ptr),
                .attachmentCount = @intCast(attachments.len),
                .width = framebuffer_extent.width,
                .height = framebuffer_extent.height,
                .layers = framebuffer_extent.layers,
            };

            vkt(c.vkCreateFramebuffer(eng.get().gfx.platform.device, &framebuffer_info, null, framebuffer)) catch |err| {
                for (0..fidx) |i| {
                    c.vkDestroyFramebuffer(eng.get().gfx.platform.device, framebuffers[i], null);
                }
                return err;
            };
        }
        errdefer {
            for (framebuffers) |framebuffer| {
                c.vkDestroyFramebuffer(eng.get().gfx.platform.device, framebuffer, null);
            }
        }

        return FrameBufferVulkan {
            .vk_framebuffers = framebuffers,
        };
    }
};

fn bindingtype_to_vulkan(bindingtype: gf.BindingType) c.VkDescriptorType {
    return switch (bindingtype) {
        .ImageView => c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
        .ImageViewAndSampler => c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .Sampler => c.VK_DESCRIPTOR_TYPE_SAMPLER,
        .UniformBuffer => c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        .StorageBuffer => c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
    };
}

fn shaderstageflags_to_vulkan(shaderstageflags: gf.ShaderStageFlags) c.VkShaderStageFlags {
    var flags: c.VkShaderStageFlags = 0;

    if (shaderstageflags.Vertex) {
        flags |= c.VK_SHADER_STAGE_VERTEX_BIT;
    }
    if (shaderstageflags.Pixel) {
        flags |= c.VK_SHADER_STAGE_FRAGMENT_BIT;
    }

    return flags;
}

pub const DescriptorLayoutVulkan = struct {
    vk_layout: c.VkDescriptorSetLayout,
    
    pub fn deinit(self: *const DescriptorLayoutVulkan) void {
        c.vkDestroyDescriptorSetLayout(GfxStateVulkan.get().device, self.vk_layout, null);
    }

    pub fn init(info: gf.DescriptorLayoutInfo) !DescriptorLayoutVulkan {
        const alloc = GfxStateVulkan.get().alloc;

        const vk_bindings = try alloc.alloc(c.VkDescriptorSetLayoutBinding, info.bindings.len);
        defer alloc.free(vk_bindings);

        for (info.bindings, 0..) |*binding, idx| {
            vk_bindings[idx] = c.VkDescriptorSetLayoutBinding {
                .binding = binding.binding,
                .descriptorType = bindingtype_to_vulkan(binding.binding_type),
                .stageFlags = shaderstageflags_to_vulkan(binding.shader_stages),
                .descriptorCount = binding.array_count,
                .pImmutableSamplers = null, // todo? idk
            };
        }

        const layout_info = c.VkDescriptorSetLayoutCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .pBindings = @ptrCast(vk_bindings.ptr),
            .bindingCount = @intCast(vk_bindings.len),
        };

        var vk_layout: c.VkDescriptorSetLayout = undefined;
        try vkt(c.vkCreateDescriptorSetLayout(GfxStateVulkan.get().device, &layout_info, null, &vk_layout));
        errdefer c.vkDestroyDescriptorSetLayout(GfxStateVulkan.get().device, vk_layout, null);

        return DescriptorLayoutVulkan {
            .vk_layout = vk_layout,
        };
    }
};

pub const DescriptorPoolVulkan = struct {
    vk_pool: c.VkDescriptorPool,

    pub fn deinit(self: *const DescriptorPoolVulkan) void {
        c.vkDestroyDescriptorPool(GfxStateVulkan.get().device, self.vk_pool, null);
    }

    pub fn init(info: gf.DescriptorPoolInfo) !DescriptorPoolVulkan {
        const alloc = GfxStateVulkan.get().alloc;

        const vk_pool_sizes: []c.VkDescriptorPoolSize = try switch (info.strategy) {
            .Layout => |layout_ref| blk: {
                const layout = try layout_ref.get();

                var descriptor_counts: [@typeInfo(gf.BindingType).@"enum".fields.len]u32 = undefined;
                @memset(descriptor_counts[0..], 0);

                for (layout.info.bindings) |binding| {
                    descriptor_counts[@intFromEnum(binding.binding_type)] += binding.array_count;
                }

                var vk_pool_sizes_list = std.ArrayList(c.VkDescriptorPoolSize).init(alloc);
                defer vk_pool_sizes_list.deinit();

                for (descriptor_counts[0..], 0..) |desc, idx| {
                    if (desc > 0) {
                        try vk_pool_sizes_list.append(c.VkDescriptorPoolSize {
                            .type = bindingtype_to_vulkan(@enumFromInt(idx)),
                            .descriptorCount = desc,
                        });
                    }
                }

                const vk_pool_sizes = try alloc.dupe(c.VkDescriptorPoolSize, vk_pool_sizes_list.items[0..]);
                break :blk vk_pool_sizes;
            },
            .Manual => |pool_sizes| blk: {
                const vk_pool_sizes = try alloc.alloc(c.VkDescriptorPoolSize, pool_sizes.len);

                for (pool_sizes, 0..) |size, idx| {
                    vk_pool_sizes[idx] = c.VkDescriptorPoolSize {
                        .type = bindingtype_to_vulkan(size.binding_type),
                        .descriptorCount = size.count,
                    };
                }

                break :blk vk_pool_sizes;
            },
        };
        defer alloc.free(vk_pool_sizes);

        for (vk_pool_sizes) |*pool_size| {
            // TODO check we can actually create this many in the pool
            pool_size.descriptorCount *= info.max_sets;
        }

        const pool_info = c.VkDescriptorPoolCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .maxSets = info.max_sets,
            .pPoolSizes = @ptrCast(vk_pool_sizes.ptr),
            .poolSizeCount = @intCast(vk_pool_sizes.len),
        };

        var vk_pool: c.VkDescriptorPool = undefined;
        try vkt(c.vkCreateDescriptorPool(GfxStateVulkan.get().device, &pool_info, null, &vk_pool));
        errdefer c.vkDestroyDescriptorPool(GfxStateVulkan.get().device, vk_pool, null);

        return DescriptorPoolVulkan {
            .vk_pool = vk_pool,
        };
    }

    pub fn allocate_sets(
        self: *const DescriptorPoolVulkan,
        alloc: std.mem.Allocator,
        info: gf.DescriptorSetInfo,
        number_of_sets: u32
    ) ![]gf.DescriptorSet {
        // todo multiple sets using multiple different layouts?
        const layout = try info.layout.get();

        const layouts = try alloc.alloc(c.VkDescriptorSetLayout, number_of_sets);
        defer alloc.free(layouts);

        for (layouts) |*l| {
            l.* = layout.platform.vk_layout;
        }

        const alloc_info = c.VkDescriptorSetAllocateInfo {
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .descriptorPool = self.vk_pool,
            .pSetLayouts = @ptrCast(layouts.ptr),
            .descriptorSetCount = @intCast(layouts.len),
        };

        const vk_sets = try alloc.alloc(gf.DescriptorSet, number_of_sets);
        defer alloc.free(vk_sets);

        const sets = try alloc.alloc(gf.DescriptorSet, number_of_sets);
        errdefer alloc.free(sets);

        try vkt(c.vkAllocateDescriptorSets(GfxStateVulkan.get().device, &alloc_info, @ptrCast(sets.ptr)));

        for (vk_sets, 0..) |vk_set, idx| {
            sets[idx] = gf.DescriptorSet {
                .platform = DescriptorSetVulkan.init(vk_set),
            };
        }

        return sets;
    }
};

pub const DescriptorSetVulkan = struct {
    vk_set: c.VkDescriptorSet,

    pub fn deinit(self: *DescriptorSetVulkan) void {
        _ = self;
    }

    fn init(vk_set: c.VkDescriptorSet) DescriptorSetVulkan {
        return .{
            .vk_set = vk_set,
        };
    }

    pub fn update(self: *const DescriptorSetVulkan, info: gf.DescriptorSetUpdateInfo) void {
        const alloc = GfxStateVulkan.get().alloc;

        var arena_obj = std.heap.ArenaAllocator.init(alloc);
        defer arena_obj.deinit();
        const arena = arena_obj.allocator();

        const vk_write_infos = try arena.alloc(c.VkWriteDescriptorSet, info.writes.len);
        defer arena.free(vk_write_infos);

        const BufferWritesList = std.SinglyLinkedList(c.VkDescriptorBufferInfo);
        var vk_buffer_writes = BufferWritesList {};

        const ImageViewWritesList = std.SinglyLinkedList(c.VkDescriptorImageInfo);
        var vk_view_writes = ImageViewWritesList {};

        for (info.writes, 0..) |write, idx| {
            const vk_write_info = &vk_write_infos[idx];

            vk_write_info.* = c.VkWriteDescriptorSet {
                .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .dstSet = self.vk_set,
                .dstBinding = write.binding,
                .dstArrayElement = write.array_element,
                .descriptorCount = write.array_count,
                .descriptorType = bindingtype_to_vulkan(std.meta.activeTag(write.data)),
                .pBufferInfo = null,
                .pImageInfo = null,
                .pTexelBufferView = null,
            };

            switch (write.data) {
                .UniformBuffer, .StorageBuffer => |buffer_writes| {
                    for (buffer_writes) |bw| {
                        const buffer = try bw.buffer.get();

                        const buffer_node = try arena.create(BufferWritesList.Node);
                        buffer_node.data = c.VkDescriptorBufferInfo {
                            .buffer = buffer.platform.vk_buffer,
                            .offset = bw.offset,
                            .range = bw.range,
                        };
                        vk_buffer_writes.prepend(buffer_node);
                        vk_write_info.pBufferInfo = &buffer_node.data;
                    }
                },
                .ImageView => |image_writes| {
                    for (image_writes) |iw| {
                        const view = try iw.get();

                        const view_node = try arena.create(ImageViewWritesList.Node);
                        view_node.data = c.VkDescriptorImageInfo {
                            .sampler = null,
                            .imageView = view.platform.vk_image_view,
                            .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                        };
                        vk_view_writes.prepend(view_node);
                        vk_write_info.pImageInfo = &view_node.data;
                    }
                },
                .Sampler => |sampler_writes| {
                    for (sampler_writes) |sw| {
                        const sampler = try sw.get();

                        const view_node = try arena.create(ImageViewWritesList.Node);
                        view_node.data = c.VkDescriptorImageInfo {
                            .sampler = sampler.platform.vk_sampler,
                            .imageView = null,
                            .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                        };
                        vk_view_writes.prepend(view_node);
                        vk_write_info.pImageInfo = &view_node.data;
                    }
                },
                .ImageViewAndSampler => |image_writes| {
                    for (image_writes) |iw| {
                        const view = try iw.view.get();
                        const sampler = try iw.sampler.get();

                        const view_node = try arena.create(ImageViewWritesList.Node);
                        view_node.data = c.VkDescriptorImageInfo {
                            .sampler = sampler.platform.vk_sampler,
                            .imageView = view.platform.vk_image_view,
                            .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                        };
                        vk_view_writes.prepend(view_node);
                        vk_write_info.pImageInfo = &view_node.data;
                    }
                }
            }
        }

        c.vkUpdateDescriptorSets(
            GfxStateVulkan.get().device,
            @intCast(vk_write_infos.len),
            @ptrCast(vk_write_infos.ptr),
            0,
            null
        );
    }
};

inline fn poolflags_to_vulkan(info: gf.CommandPoolInfo) c.VkCommandPoolCreateFlags {
    var flags: c.VkCommandPoolCreateFlags = 0;
    if (info.transient_buffers) {
        flags |= c.VK_COMMAND_POOL_CREATE_TRANSIENT_BIT;
    }
    if (info.allow_reset_command_buffers) {
        flags |= c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    }
    return flags;
}

pub const CommandPoolVulkan = struct {
    vk_pool: c.VkCommandPool,

    pub fn deinit(self: *const CommandPoolVulkan) void {
        c.vkDestroyCommandPool(GfxStateVulkan.get().device, self.vk_pool, null);
    }

    pub fn init(info: gf.CommandPoolInfo) !CommandPoolVulkan {
        const pool_info = c.VkCommandPoolCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .flags = poolflags_to_vulkan(info),
            .queueFamilyIndex = GfxStateVulkan.get().get_queue_family_index(info.queue_family),
        };

        var vk_pool: c.VkCommandPool = undefined;
        try vkt(c.vkCreateCommandPool(GfxStateVulkan.get().device, &pool_info, null, &vk_pool));
        errdefer c.vkDestroyCommandPool(GfxStateVulkan.get().device, vk_pool, null);

        return CommandPoolVulkan {
            .vk_pool = vk_pool,
        };
    }

    pub fn allocate_command_buffer(self: *CommandPoolVulkan, info: gf.CommandBufferInfo) !CommandBufferVulkan {
        const alloc_info = c.VkCommandBufferAllocateInfo {
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandBufferCount = 1,
            .commandPool = GfxStateVulkan.get().all_command_pool,
            .level = commandbufferlevel_to_vulkan(info.level),
        };

        var vk_command_buffer: c.VkCommandBuffer = undefined;
        try vkt(c.vkAllocateCommandBuffers(GfxStateVulkan.get().device, &alloc_info, &vk_command_buffer));
        errdefer c.vkFreeCommandBuffers(GfxStateVulkan.get().device, self.vk_pool, 1, &vk_command_buffer);

        return CommandBufferVulkan {
            .vk_pool = self.vk_pool,
            .vk_command_buffer = vk_command_buffer,
        };
    }
};

inline fn commandbufferlevel_to_vulkan(level: gf.CommandBufferLevel) c.VkCommandBufferLevel {
    return switch (level) {
        .Primary => c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .Secondary => c.VK_COMMAND_BUFFER_LEVEL_SECONDARY,
    };
}

pub const CommandBufferVulkan = struct {
    const Self = @This();

    vk_pool: c.VkCommandPool,
    vk_command_buffer: c.VkCommandBuffer,

    pub fn deinit(self: *const Self) void {
        c.vkFreeCommandBuffers(GfxStateVulkan.get().device, self.vk_pool, 1, &self.vk_command_buffer);
    }

    pub fn cmd_begin(self: *Self) !void {
        const begin_info = c.VkCommandBufferBeginInfo {
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = 0, // TODO
        };

        try vkt(c.vkBeginCommandBuffer(self.vk_command_buffer, &begin_info));
    }

    pub fn cmd_end(self: *Self) !void {
        try vkt(c.vkEndCommandBuffer(self.vk_command_buffer));
    }

    pub fn cmd_begin_render_pass(self: *Self, info: gf.CommandBuffer.BeginRenderPassInfo) void {
        const render_pass = info.render_pass.get() catch return;
        const framebuffer = info.framebuffer.get() catch return;
        
        const begin_info = c.VkRenderPassBeginInfo {
            .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            .renderPass = render_pass.platform.vk_render_pass,
            .framebuffer = framebuffer.platform.vk_framebuffers[0], // TODO idx
            .pClearValues = @ptrCast(render_pass.platform.vk_clear_values.ptr),
            .clearValueCount = @intCast(render_pass.platform.vk_clear_values.len),
            .renderArea = rect_to_vulkan(info.render_area),
        };

        const subpass_contents = switch (info.subpass_contents) {
            .Inline => c.VK_SUBPASS_CONTENTS_INLINE,
            .SecondaryCommandBuffers => c.VK_SUBPASS_CONTENTS_SECONDARY_COMMAND_BUFFERS,
        };

        c.vkCmdBeginRenderPass(self.vk_command_buffer, &begin_info, subpass_contents);
    }

    pub fn cmd_end_render_pass(self: *Self) void {
        c.vkCmdEndRenderPass(self.vk_command_buffer);
    }

    pub fn cmd_bind_graphics_pipeline(self: *Self, pipeline: gf.GraphicsPipeline.Ref) void {
        const p = pipeline.get() catch return;
        c.vkCmdBindPipeline(self.vk_command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, p.platform.vk_graphics_pipeline);
    }

    const max_vk_viewports = 6;
    pub fn cmd_set_viewport(self: *Self, info: gf.CommandBuffer.SetViewportsInfo) void {
        std.debug.assert(info.viewports.len <= max_vk_viewports);

        const vk_viewports: [max_vk_viewports]c.VkViewport = undefined;
        for (info.viewports, 0..) |v, idx| {
            vk_viewports[idx] = c.VkViewport {
                .x = v.top_left_x,
                .y = v.top_left_y,
                .width = v.width,
                .height = v.height,
                .minDepth = v.min_depth,
                .maxDepth = v.max_depth,
            };
        }
        c.vkCmdSetViewport(
            self.vk_command_buffer, 
            info.first_viewport, 
            @intCast(info.viewports.len),
            @ptrCast(vk_viewports[0..].ptr)
        );
    }

    pub fn cmd_set_scissor(self: *Self, info: gf.CommandBuffer.SetScissorsInfo) void {
        std.debug.assert(info.scissors.len <= max_vk_viewports);

        const vk_scissors: [max_vk_viewports]c.VkRect2D = undefined;
        for (info.scissors, 0..) |s, idx| {
            vk_scissors[idx] = rect_to_vulkan(s);
        }
        c.vkCmdSetScissor(
            self.vk_command_buffer,
            info.first_scissor,
            @intCast(info.scissors.len),
            @ptrCast(vk_scissors[0..].ptr)
        );
    }

    pub fn cmd_bind_vertex_buffers(self: *Self, info: gf.CommandBuffer.BindVertexBuffersInfo) void {
        const max_vertex_buffers = 16;
        std.debug.assert(info.buffers.len <= max_vertex_buffers);

        const vk_buffers: [max_vertex_buffers]c.VkBuffer = undefined;
        const vk_device_sizes: [max_vertex_buffers]c.VkDeviceSize = undefined;
        for (info.buffers, 0..) |b, idx| {
            const buffer = b.get() catch unreachable;
            vk_buffers[idx] = buffer.platform.vk_buffer;
            vk_device_sizes[idx] = b.offset;
        }
        c.vkCmdBindVertexBuffers(
            self.vk_command_buffer,
            info.first_binding,
            @intCast(info.buffers.len),
            @ptrCast(vk_buffers[0..].ptr),
            @ptrCast(vk_device_sizes[0..].ptr)
        );
    }

    pub fn cmd_bind_index_buffer(self: *Self, info: gf.CommandBuffer.BindIndexBufferInfo) void {
        const buffer = info.buffer.get() catch unreachable;
        c.vkCmdBindIndexBuffer(
            self.vk_command_buffer,
            buffer.platform.vk_buffer,
            info.offset,
            indexformat_to_vulkan(info.index_format)
        );
    }

    pub fn cmd_bind_descriptor_sets(self: *Self, info: gf.CommandBuffer.BindDescriptorSetInfo) void {
        const max_descriptor_sets = 16;
        std.debug.assert(info.descriptor_sets.len <= 16);

        const vk_descriptor_sets: [max_descriptor_sets]c.VkDescriptorSet = undefined;
        for (info.descriptor_sets, 0..) |s, idx| {
            const set = s.get() catch unreachable;
            vk_descriptor_sets[idx] = set.platform.vk_set;
        }

        const pipeline = info.graphics_pipeline.get() catch unreachable;
        c.vkCmdBindDescriptorSets(
            self.vk_command_buffer,
            c.VK_PIPELINE_BIND_POINT_GRAPHICS, // TODO compute
            pipeline.platform.vk_pipeline_layout,
            info.first_binding,
            @intCast(info.descriptor_sets.len),
            @ptrCast(vk_descriptor_sets[0..].ptr),
            @intCast(info.dynamic_offsets.len),
            @ptrCast(info.dynamic_offsets.ptr)
        );
    }

    pub fn cmd_draw(self: *Self, info: gf.CommandBuffer.DrawInfo) void {
        c.vkCmdDraw(
            self.vk_command_buffer,
            info.vertex_count,
            info.instance_count,
            info.first_vertex,
            info.first_instance
        );
    }

    pub fn cmd_draw_indexed(self: *Self, info: gf.CommandBuffer.DrawIndexedInfo) void {
        c.vkCmdDrawIndexed(
            self.vk_command_buffer,
            info.index_count,
            info.instance_count,
            info.first_index,
            info.vertex_offset,
            info.first_instance
        );
    }
};
