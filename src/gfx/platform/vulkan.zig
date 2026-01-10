const vk = @import("vulkan_import.zig");
const c = vk.c;
const vkt = @import("vulkan_error.zig").vulkan_result_to_zig_error;
const std = @import("std");
const zm = @import("zmath");
const eng = @import("self");
const gf = eng.gfx;
const pl = eng.platform;
const Rect = eng.Rect;

pub const GfxStateVulkan = struct {
    const Self = @This();
    const ENABLE_VALIDATION_LAYERS: bool = true;
    const FORCE_INTEGRATED_GPU: bool = false;

    pub const ShaderModule = ShaderModuleVulkan;
    pub const VertexInput = VertexInputVulkan;
    
    pub const Buffer = BufferVulkan;
    pub const Image = ImageVulkan;
    pub const ImageView = ImageViewVulkan;
    pub const Sampler = SamplerVulkan;

    pub const RenderPass = RenderPassVulkan;
    pub const GraphicsPipeline = GraphicsPipelineVulkan;
    pub const ComputePipeline = ComputePipelineVulkan;
    pub const FrameBuffer = FrameBufferVulkan;

    pub const DescriptorLayout = DescriptorLayoutVulkan;
    pub const DescriptorPool = DescriptorPoolVulkan;
    pub const DescriptorSet = DescriptorSetVulkan;

    pub const CommandPool = CommandPoolVulkan;
    pub const CommandBuffer = CommandBufferVulkan;

    pub const Semaphore = SemaphoreVulkan;
    pub const Fence = FenceVulkan;

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
    
    const BufferUpdates = struct {
        vk_buffers: []const c.VkBuffer,
        size: u64,
        count: usize,
    };

    alloc: std.mem.Allocator,

    vk_version: u32,
    instance: c.VkInstance,
    surface: c.VkSurfaceKHR,
    physical_device: c.VkPhysicalDevice,
    physical_device_properties: c.VkPhysicalDeviceProperties,
    device: c.VkDevice,
    queues: VkQueues,

    debug_messenger: ?c.VkDebugUtilsMessengerEXT,

    num_frames_in_flight: u32,
    frame_count: u128 = 0,

    all_command_pool: gf.CommandPool,
    transfer_command_pool: gf.CommandPool,

    swapchain: SwapchainVulkan,
    temp_frame_wait_fence: c.VkFence,

    buffer_updates: std.ArrayList(BufferUpdates),

    pub fn deinit(self: *Self) void {
        std.log.info("Vulkan deinit", .{});
        vkt(c.vkDeviceWaitIdle(self.device)) catch |err| {
            std.log.err("Unable to wait for device idle: {}", .{err});
        };

        self.buffer_updates.deinit(self.alloc);
        
        c.vkDestroyFence(self.device, self.temp_frame_wait_fence, null);
        self.swapchain.deinit(self);

        self.all_command_pool.deinit();
        self.transfer_command_pool.deinit();
        c.vkDestroyDevice(self.device, null);
        c.vkDestroySurfaceKHR(self.instance, self.surface, null);

        if (self.debug_messenger) |m| blk: {
            const vkDestroyDebugUtilsMessengerEXT = @as(
                c.PFN_vkDestroyDebugUtilsMessengerEXT,
                @ptrCast(c.vkGetInstanceProcAddr(self.instance, "vkDestroyDebugUtilsMessengerEXT"))
            ) orelse break :blk;

            vkDestroyDebugUtilsMessengerEXT(self.instance, m, null);
        }
        c.vkDestroyInstance(self.instance, null);
    }

    pub fn init(alloc: std.mem.Allocator, window: *pl.Window) !Self {
        // Request vulkan version
        var vk_version: u32 = 0;
        try vkt(c.vkEnumerateInstanceVersion(&vk_version));
        std.log.info("vulkan version is {}.{}.{}", .{
            c.VK_API_VERSION_MAJOR(vk_version),
            c.VK_API_VERSION_MINOR(vk_version),
            c.VK_API_VERSION_VARIANT(vk_version),
        });

        // Declare required instance layers
        var required_instance_layers = try std.ArrayList([*c]const u8).initCapacity(alloc, 8);
        defer required_instance_layers.deinit(alloc);

        if (Self.ENABLE_VALIDATION_LAYERS) {
            try required_instance_layers.append(alloc, "VK_LAYER_KHRONOS_validation");
        }

        var instance_layer_count: u32 = 0;
        try vkt(c.vkEnumerateInstanceLayerProperties(&instance_layer_count, null));

        const instance_layers = try alloc.alloc(c.VkLayerProperties, instance_layer_count);
        defer alloc.free(instance_layers);
        try vkt(c.vkEnumerateInstanceLayerProperties(&instance_layer_count, @ptrCast(instance_layers.ptr)));

        // Check required layers are available
        for (required_instance_layers.items) |required_layer| {
            var found: bool = false;
            for (instance_layers) |layer| {
                if (std.mem.eql(u8, std.mem.sliceTo(layer.layerName[0..], 0), std.mem.sliceTo(required_layer[0..], 0))) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                std.log.err("Required instance layer does not exist: {s}", .{required_layer});
                return error.RequiredInstanceLayerDoesNotExist;
            }
        }

        // Declare required instance extensions
        var instance_extensions = try std.ArrayList([*c]const u8).initCapacity(alloc, 8);
        defer instance_extensions.deinit(alloc);

        try instance_extensions.append(alloc, c.VK_KHR_SURFACE_EXTENSION_NAME);
        if (@import("builtin").os.tag == .windows) {
            try instance_extensions.append(alloc, c.VK_KHR_WIN32_SURFACE_EXTENSION_NAME);
        }
        if (Self.ENABLE_VALIDATION_LAYERS) {
            try instance_extensions.append(alloc, c.VK_EXT_DEBUG_UTILS_EXTENSION_NAME);
        }

        // Declare required device extensions
        var device_extensions = try std.ArrayList([*c]const u8).initCapacity(alloc, 8);
        defer device_extensions.deinit(alloc);

        try device_extensions.append(alloc, c.VK_KHR_SWAPCHAIN_EXTENSION_NAME);

        // Declare required physical device features
        const required_physical_device_features_info = c.VkPhysicalDeviceFeatures {
            .independentBlend = bool_to_vulkan(true),
            .fillModeNonSolid = bool_to_vulkan(true),
        };
        const required_physical_device_features_info_11 = c.VkPhysicalDeviceVulkan11Features {
            .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
            .pNext = null,
            .shaderDrawParameters = bool_to_vulkan(true),
        };

        // Create vulkan instance
        const create_instance_info = c.VkInstanceCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .enabledLayerCount = @intCast(required_instance_layers.items.len),
            .ppEnabledLayerNames = @ptrCast(required_instance_layers.items.ptr),
            .enabledExtensionCount = @intCast(instance_extensions.items.len),
            .ppEnabledExtensionNames = @ptrCast(instance_extensions.items.ptr),
            .flags = 0,// | c.VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR,
            .pApplicationInfo = null,
            .pNext = null,
        };

        var vk_instance: c.VkInstance = undefined;
        try vkt(c.vkCreateInstance(&create_instance_info, null, &vk_instance));
        errdefer c.vkDestroyInstance(vk_instance, null);

        // Create vulkan debug messenger
        var debug_messenger: ?c.VkDebugUtilsMessengerEXT = null;
        if (Self.ENABLE_VALIDATION_LAYERS) {
            const debug_messenger_create_info = c.VkDebugUtilsMessengerCreateInfoEXT {
                .sType = c.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
                .messageSeverity = 
                    c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT |
                    c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT |
                    c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
                .messageType = 
                    c.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
                    c.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
                    c.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT,
                .pfnUserCallback = &Self.debug_callback,
            };

            const vkCreateDebugUtilsMessengerEXT = @as(
                c.PFN_vkCreateDebugUtilsMessengerEXT,
                @ptrCast(c.vkGetInstanceProcAddr(vk_instance, "vkCreateDebugUtilsMessengerEXT"))
            ) orelse return error.ExtensionNotPresent;

            var vk_debug_messenger: c.VkDebugUtilsMessengerEXT = undefined;
            try vkt(vkCreateDebugUtilsMessengerEXT(vk_instance, &debug_messenger_create_info, null, @ptrCast(&vk_debug_messenger)));
            debug_messenger = vk_debug_messenger;
        }
        errdefer if (debug_messenger) |m| blk: {
            const vkDestroyDebugUtilsMessengerEXT = @as(
                c.PFN_vkDestroyDebugUtilsMessengerEXT,
                @ptrCast(c.vkGetInstanceProcAddr(vk_instance, "vkDestroyDebugUtilsMessengerEXT"))
            ) orelse break :blk;

            vkDestroyDebugUtilsMessengerEXT(vk_instance, m, null);
            debug_messenger = null;
        };

        // Create vulkan surface
        var vk_surface: c.VkSurfaceKHR = undefined;
        switch (@import("builtin").os.tag) {
            .windows => {
                const surface_create_info = c.VkWin32SurfaceCreateInfoKHR {
                    .sType = c.VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR,
                    .hwnd = @ptrCast(window.hwnd),
                    .hinstance = @ptrCast(window.hInstance),
                };

                try vkt(c.vkCreateWin32SurfaceKHR(vk_instance, @ptrCast(&surface_create_info), null, &vk_surface));
            },
            else => @compileError("Platform not implemented"),
        }
        errdefer c.vkDestroySurfaceKHR(vk_instance, vk_surface, null);

        // Discover all available physical devices
        var physical_device_count: u32 = 0;
        try vkt(c.vkEnumeratePhysicalDevices(vk_instance, &physical_device_count, null));

        const physical_device_storage = try alloc.alloc(c.VkPhysicalDevice, physical_device_count);
        defer alloc.free(physical_device_storage);
        try vkt(c.vkEnumeratePhysicalDevices(vk_instance, &physical_device_count, physical_device_storage.ptr));

        // Discover the most appropriate physical device to use
        var best_physical_device_idx: usize = std.math.maxInt(usize);
        std.log.info("Available physical devices:", .{});
        for (physical_device_storage, 0..) |physical_device, idx| {
            // Retrieve physical device properties
            var prop: c.VkPhysicalDeviceProperties = undefined;
            c.vkGetPhysicalDeviceProperties(physical_device, &prop);
            std.log.info("- {s}", .{std.mem.sliceTo(&prop.deviceName, 0)});

            var physical_device_extension_count: u32 = undefined;
            vkt(c.vkEnumerateDeviceExtensionProperties(physical_device, null, &physical_device_extension_count, null))
                catch continue;

            const physical_device_extension_storage = try alloc.alloc(c.VkExtensionProperties, physical_device_extension_count);
            defer alloc.free(physical_device_extension_storage);
            vkt(c.vkEnumerateDeviceExtensionProperties(physical_device, null, &physical_device_extension_count, physical_device_extension_storage.ptr))
                catch continue;

            var vk_physical_device_features_vulkan_11 = c.VkPhysicalDeviceVulkan11Features {
                .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
                .pNext = null,
            };
            var vk_physical_device_features_2 = c.VkPhysicalDeviceFeatures2 {
                .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
                .pNext = @ptrCast(&vk_physical_device_features_vulkan_11),
            };
            c.vkGetPhysicalDeviceFeatures2(physical_device, @ptrCast(&vk_physical_device_features_2));

            // Check physical device supports the required extensions
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

            // Check physical device supports all required features
            var supports_all_features: bool = true;
            inline for (@typeInfo(c.VkPhysicalDeviceFeatures).@"struct".fields) |field| {
                if (@field(required_physical_device_features_info, field.name) == bool_to_vulkan(true)) {
                    if (@field(vk_physical_device_features_2.features, field.name) != bool_to_vulkan(true)) {
                        std.log.info("  - doesn't support feature '{s}'", .{field.name});
                        supports_all_features = false;
                    }
                }
            }
            inline for (@typeInfo(c.VkPhysicalDeviceVulkan11Features).@"struct".fields) |field| {
                if (field.type == bool) {
                    if (@field(required_physical_device_features_info_11, field.name) == bool_to_vulkan(true)) {
                        if (@field(vk_physical_device_features_vulkan_11, field.name) != bool_to_vulkan(true)) {
                            std.log.info("  - doesn't support feature '{s}'", .{field.name});
                            supports_all_features = false;
                        }
                    }
                }
            }
            if (!supports_all_features) { continue; }

            // Retrieve physical device surface properties
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

            // Check physical device supports the required surface properties
            if (surface_fomats_count == 0 or surface_present_modes_count == 0) {
                std.log.info("  - doesn't satisfy all surface requirements", .{});
                continue;
            }

            // @TODO: better physical device selection
            if (!FORCE_INTEGRATED_GPU) {
                if (prop.deviceType == c.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) {
                    best_physical_device_idx = idx;
                }
            } else {
                if (prop.deviceType != c.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) {
                    best_physical_device_idx = idx;
                }
            }
        }

        // If a suitable physical device was not found then return error
        if (best_physical_device_idx >= physical_device_count) {
            return error.UnableToFindASuitablePhysicalDevice;
        }

        // Assign the selected physical device
        const vk_physical_device = physical_device_storage[best_physical_device_idx];

        // Record physical device properties
        var vk_physical_device_properties: c.VkPhysicalDeviceProperties = undefined;
        c.vkGetPhysicalDeviceProperties(vk_physical_device, &vk_physical_device_properties);

        std.log.info("Selected {s} as the physical device.", .{std.mem.sliceTo(&vk_physical_device_properties.deviceName, 0)});

        // Get physical device surface capabilities
        var surface_capabilities: c.VkSurfaceCapabilitiesKHR = undefined;
        try vkt(c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(vk_physical_device, vk_surface, &surface_capabilities));

        // Select number of frames in flight
        const num_frames_in_flight = std.math.clamp(
            surface_capabilities.minImageCount + 1,
            surface_capabilities.minImageCount,
            if (surface_capabilities.maxImageCount != 0) surface_capabilities.maxImageCount else std.math.maxInt(u32),
        );

        // Define preferred surface format and present mode
        var surface_format: c.VkSurfaceFormatKHR = .{
            .format = c.VK_FORMAT_B8G8R8A8_SRGB,
            .colorSpace = c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR,
        };
        var present_mode: c.VkPresentModeKHR = c.VK_PRESENT_MODE_MAILBOX_KHR;

        // Select closest surface format and present mode to the preferred
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

        // Get available queue family properties
        var queue_family_properties_count: u32 = 0;
        c.vkGetPhysicalDeviceQueueFamilyProperties(vk_physical_device, &queue_family_properties_count, null);

        const queue_family_properties_storage = try alloc.alloc(c.VkQueueFamilyProperties, queue_family_properties_count);
        defer alloc.free(queue_family_properties_storage);
        c.vkGetPhysicalDeviceQueueFamilyProperties(
            vk_physical_device, 
            &queue_family_properties_count, 
            queue_family_properties_storage.ptr
        );

        // Select queue family indices
        var all_queue_idx: u32 = std.math.maxInt(u32);
        var present_queue_idx: u32 = std.math.maxInt(u32);
        var transfer_queue_idx: u32 = std.math.maxInt(u32);
        for (queue_family_properties_storage, 0..) |queue_family_props, idx| {
            const is_graphics = (queue_family_props.queueFlags & c.VK_QUEUE_GRAPHICS_BIT) != 0;
            const is_compute = (queue_family_props.queueFlags & c.VK_QUEUE_COMPUTE_BIT) != 0;
            const is_transfer = (queue_family_props.queueFlags & c.VK_QUEUE_TRANSFER_BIT) != 0;

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

        // Define queue create infos
        var queue_create_infos = try std.ArrayList(c.VkDeviceQueueCreateInfo).initCapacity(alloc, 4);
        defer queue_create_infos.deinit(alloc);

        try queue_create_infos.append(alloc, .{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueCount = 1,
            .queueFamilyIndex = all_queue_idx,
            .pQueuePriorities = &@as(f32, 1.0),
        });

        if (present_queue_idx != all_queue_idx) {
            try queue_create_infos.append(alloc, .{
                .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .queueCount = 1,
                .queueFamilyIndex = present_queue_idx,
                .pQueuePriorities = &@as(f32, 1.0),
            });
        }

        if (transfer_queue_idx < queue_family_properties_count) {
            try queue_create_infos.append(alloc, .{
                .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .queueCount = 1,
                .queueFamilyIndex = transfer_queue_idx,
                .pQueuePriorities = &@as(f32, 1.0),
            });
        }

        // Create vulkan device
        const create_device_info = c.VkDeviceCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .pNext = &required_physical_device_features_info_11,
            .queueCreateInfoCount = @intCast(queue_create_infos.items.len),
            .pQueueCreateInfos = queue_create_infos.items.ptr,
            .enabledExtensionCount = @intCast(device_extensions.items.len),
            .ppEnabledExtensionNames = device_extensions.items.ptr,
            .pEnabledFeatures = &required_physical_device_features_info,
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

        // Retrieve created queues from vulkan device
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

        // Create common command pools for queues
        const transfer_command_pool_create_info = c.VkCommandPoolCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .queueFamilyIndex = queues.cpu_gpu_transfer_family_index,
        };

        var vk_transfer_command_pool: c.VkCommandPool = undefined;
        try vkt(c.vkCreateCommandPool(vk_device, &transfer_command_pool_create_info, null, &vk_transfer_command_pool));

        const transfer_command_pool = gf.CommandPool { .platform = CommandPoolVulkan { .vk_pool = vk_transfer_command_pool, } };
        errdefer transfer_command_pool.deinit();
        errdefer vkt(c.vkDeviceWaitIdle(vk_device)) catch unreachable;

        const all_command_pool_create_info = c.VkCommandPoolCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .queueFamilyIndex = queues.all_family_index,
        };

        var vk_all_command_pool: c.VkCommandPool = undefined;
        try vkt(c.vkCreateCommandPool(vk_device, &all_command_pool_create_info, null, &vk_all_command_pool));

        const all_command_pool = gf.CommandPool { .platform = CommandPoolVulkan { .vk_pool = vk_all_command_pool, } };
        errdefer all_command_pool.deinit();
        errdefer vkt(c.vkDeviceWaitIdle(vk_device)) catch unreachable;

        // Create frame wait fence?
        // TODO remove?
        const frame_wait_fence_info = c.VkFenceCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .flags = c.VK_FENCE_CREATE_SIGNALED_BIT,
        };

        var vk_temp_frame_wait_fence: c.VkFence = undefined;
        try vkt(c.vkCreateFence(vk_device, &frame_wait_fence_info, null, &vk_temp_frame_wait_fence));
        errdefer c.vkDestroyFence(vk_device, vk_temp_frame_wait_fence, null);

        // Create FiF buffer updates structure
        const buffer_updates = try std.ArrayList(BufferUpdates).initCapacity(alloc, 32);
        errdefer buffer_updates.deinit();

        return Self {
            .alloc = alloc,

            .vk_version = vk_version,
            .instance = vk_instance,
            .surface = vk_surface,
            .physical_device = vk_physical_device,
            .physical_device_properties = vk_physical_device_properties,
            .device = vk_device,
            .queues = queues,

            .debug_messenger = debug_messenger,

            .num_frames_in_flight = num_frames_in_flight,

            .all_command_pool = all_command_pool,
            .transfer_command_pool = transfer_command_pool,

            .swapchain = SwapchainVulkan {
                .surface_format = surface_format,
                .present_mode = present_mode,
                .swapchain = undefined,
                .extent = undefined,
                .image_available_semaphores = undefined,
                .present_transition_semaphores = undefined,
                .swapchain_image_views = undefined,
                .swapchain_images = undefined,
            },
            .temp_frame_wait_fence = vk_temp_frame_wait_fence,

            .buffer_updates = buffer_updates,
        };
    }

    pub fn init_late(self: *Self, window: *pl.Window) !void {
        // Create swap chain
        const window_size = try window.get_client_size();
        self.swapchain = try SwapchainVulkan.init(self, .{
            .width = @intCast(@max(window_size.width, 1)),
            .height = @intCast(@max(window_size.height, 1)),
            .format = self.swapchain.surface_format,
            .present_mode = self.swapchain.present_mode,
        });
        errdefer self.swapchain.deinit(self);
    }

    pub fn debug_callback (
        severity: c.VkDebugUtilsMessageSeverityFlagBitsEXT,
        messageType: c.VkDebugUtilsMessageTypeFlagsEXT,
        pCallbackData: ?*const c.VkDebugUtilsMessengerCallbackDataEXT,
        pUserData: ?*const anyopaque,
    ) callconv(.c) c.VkBool32 {
        _ = messageType;
        _ = pUserData;

        std.debug.print("\n\x1b[{s}mVulkan Validation [{s}]:\n{s}\x1b[0m\n\n", .{
            switch (severity) {
                c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT => "33", // yellow
                c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT => "31", // red
                c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT => "0", // normal
                c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT => "0", // normal
                else => "0",
            },
            switch (severity) {
                c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT => "WARNING",
                c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT => "ERROR",
                c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT => "INFO",
                c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT => "VERBOSE",
                else => "???",
            },
            pCallbackData.?.pMessage,
        });

        var addresses: [32]usize = undefined;
        var stack_trace = std.builtin.StackTrace { .index = 0, .instruction_addresses = &addresses, };
        std.debug.captureStackTrace(null, &stack_trace);

        std.debug.print("stack trace:\n", .{});
        for (stack_trace.instruction_addresses[0..stack_trace.index]) |addr| {
            const debug_info = std.debug.getSelfDebugInfo() catch {
                std.debug.print("\terror.FailedToGetDebugInfo\n", .{});
                continue;
            };

            const module_info = debug_info.getModuleForAddress(addr) catch {
                std.debug.print("\terror.FailedToGetModuleForAddress\n", .{});
                continue;
            };

            const symbol_info = module_info.getSymbolAtAddress(debug_info.allocator, addr) catch {
                std.debug.print("\terror.FailedToGetSymbolAtAddress\n", .{});
                continue;
            };

            const source_location = symbol_info.source_location orelse std.debug.SourceLocation {
                .file_name = "unknown",
                .column = 0,
                .line = 0,
            };

            std.debug.print("\t{s}:{}\n", .{
                source_location.file_name,
                source_location.line,
            });
        }
        std.debug.print("\n", .{});

        // do not abort call
        return c.VK_FALSE;
    }

    pub inline fn get() *Self {
        return &eng.get().gfx.platform;
    }

    pub inline fn props(self: *const Self) gf.PlatformProperties {
        return self.properties;
    }

    pub inline fn swapchain_size(self: *const Self) [2]u32 {
        return .{ self.swapchain.extent.width, self.swapchain.extent.height };
    }

    pub inline fn frames_in_flight(self: *const Self) u32 {
        return self.num_frames_in_flight;
    }

    pub inline fn current_frame_index(self: *const Self) u32 {
        return self.swapchain.current_image_index;
    }

    pub fn begin_frame(self: *Self) !gf.Semaphore {
        self.frame_count += 1;

        const image_available_semaphore = self.swapchain.image_available_semaphores[self.current_frame_index()];

        while (true) {
            vkt(c.vkAcquireNextImageKHR(
                    self.device,
                    self.swapchain.swapchain,
                    std.math.maxInt(u32),
                    image_available_semaphore.platform.vk_semaphore,
                    @ptrCast(c.VK_NULL_HANDLE),
                    &self.swapchain.current_image_index
            )) catch |err| {
                switch (err) {
                    error.VK_ERROR_OUT_OF_DATE_KHR => {
                        self.resize_swapchain(self.swapchain_size()[0], self.swapchain_size()[1]) catch unreachable;
                        continue;
                    },
                    else => return err,
                }
            };
            break;
        }
        // TODO do I have to wait on a fence for image acquisition before updating buffers?

        // Update frame in flight resources before continuing to the new frame
        self.copy_updated_fif_buffers() catch |err| {
            std.log.warn("Unable to update fif buffers: {}", .{err});
        };

        return image_available_semaphore;
    }

    fn copy_updated_fif_buffers(self: *Self) !void {
        var cmd = try begin_single_time_command_buffer(&self.all_command_pool);
        defer end_single_time_command_buffer(&cmd, null);

        const cfi = self.current_frame_index();
        const cfi_minus_one = (cfi + self.frames_in_flight() - 1) % self.frames_in_flight();

        // std.log.info("fif update count is {}", .{self.buffer_updates.items.len});

        var iter = std.mem.reverseIterator(self.buffer_updates.items);
        while (iter.nextPtr()) |update| {
            const buffer_copy_region = c.VkBufferCopy {
                .size = update.size,
                .dstOffset = 0,
                .srcOffset = 0,
            };
            c.vkCmdCopyBuffer(
                cmd.platform.vk_command_buffer,
                update.vk_buffers[cfi_minus_one],
                update.vk_buffers[cfi],
                1,
                &buffer_copy_region
            );
            update.count += 1;

            if (update.count >= self.frames_in_flight()) {
                _ = self.buffer_updates.swapRemove(iter.index);
            }
        }
    }

    pub fn submit_command_buffer(self: *Self, info: gf.GfxState.SubmitInfo) !void {
        const MAX_COMMAND_BUFFERS = 16;
        std.debug.assert(info.command_buffers.len < MAX_COMMAND_BUFFERS);
        const MAX_SIGNAL_SEMAPHORES = 16;
        std.debug.assert(info.signal_semaphores.len < MAX_SIGNAL_SEMAPHORES);
        const MAX_WAIT_SEMAPHORES = 16;
        std.debug.assert(info.wait_semaphores.len < MAX_WAIT_SEMAPHORES);

        var vk_command_buffers: [MAX_COMMAND_BUFFERS]c.VkCommandBuffer = undefined;
        for (info.command_buffers, 0..) |cmd, idx| {
            vk_command_buffers[idx] = cmd.platform.vk_command_buffer;
        }

        var vk_signal_semaphores: [MAX_SIGNAL_SEMAPHORES]c.VkSemaphore = undefined;
        for (info.signal_semaphores, 0..) |s, idx| {
            vk_signal_semaphores[idx] = s.platform.vk_semaphore;
        }

        var vk_wait_semaphores: [MAX_WAIT_SEMAPHORES]c.VkSemaphore = undefined;
        var vk_wait_dst_stages: [MAX_WAIT_SEMAPHORES]c.VkPipelineStageFlagBits = undefined;
        for (info.wait_semaphores, 0..) |s, idx| {
            vk_wait_semaphores[idx] = s.semaphore.platform.vk_semaphore;
            vk_wait_dst_stages[idx] = pipelinestageflags_to_vulkan(s.dst_stage);
        }

        const submit_info = c.VkSubmitInfo {
            .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pCommandBuffers = @ptrCast(vk_command_buffers[0..].ptr),
            .commandBufferCount = @intCast(info.command_buffers.len),
            .pSignalSemaphores = @ptrCast(vk_signal_semaphores[0..].ptr),
            .signalSemaphoreCount = @intCast(info.signal_semaphores.len),
            .pWaitSemaphores = @ptrCast(vk_wait_semaphores[0..].ptr),
            .waitSemaphoreCount = @intCast(info.wait_semaphores.len),
            .pWaitDstStageMask = @ptrCast(vk_wait_dst_stages[0..].ptr),
        };
        const vk_fence = if (info.fence) |f| f.platform.vk_fence else @as(c.VkFence, @ptrCast(c.VK_NULL_HANDLE));
        try vkt(c.vkQueueSubmit(self.queues.all, 1, &submit_info, vk_fence));
    }

    pub fn present(self: *Self, wait_semaphores: []const *gf.Semaphore) !void {
        const MAX_WAIT_SEMAPHORES = 16;
        std.debug.assert(wait_semaphores.len < MAX_WAIT_SEMAPHORES);

        const present_transition_semaphore = self.swapchain.present_transition_semaphores[self.current_frame_index()];
        {
            var cmd = try begin_single_time_command_buffer(&self.all_command_pool);
            defer end_single_time_command_buffer(&cmd, present_transition_semaphore);

            const image_barrier = c.VkImageMemoryBarrier {
                .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                .image = self.swapchain.swapchain_images[@intCast(self.current_frame_index())],
                .oldLayout = imagelayout_to_vulkan(.ColorAttachmentOptimal),
                .newLayout = imagelayout_to_vulkan(.PresentSrc),
                .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
                .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
                .srcAccessMask = accessflags_to_vulkan(.{ .color_attachment_write = true, }),
                .dstAccessMask = accessflags_to_vulkan(.{ .color_attachment_read = true, }),
                .subresourceRange = .{
                    .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                    .baseMipLevel = 0,
                    .levelCount = 1,
                    .baseArrayLayer = 0,
                    .layerCount = 1,
                },
            };
            c.vkCmdPipelineBarrier(
                cmd.platform.vk_command_buffer, 
                pipelinestageflags_to_vulkan(.{ .color_attachment_output = true, }), 
                pipelinestageflags_to_vulkan(.{ .all_commands = true, }), 
                0, 
                0, null,
                0, null,
                1, &image_barrier
            );
        }

        var vk_wait_semaphores: [MAX_WAIT_SEMAPHORES + 1]c.VkSemaphore = undefined;

        for (wait_semaphores, 0..) |s, idx| {
            vk_wait_semaphores[idx] = s.platform.vk_semaphore;
        }
        vk_wait_semaphores[wait_semaphores.len] = present_transition_semaphore.platform.vk_semaphore;

        const present_info = c.VkPresentInfoKHR {
            .sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .swapchainCount = 1,
            .pSwapchains = @ptrCast(&self.swapchain.swapchain),
            .pImageIndices = @ptrCast(&self.swapchain.current_image_index),
            .pResults = null,
            .waitSemaphoreCount = @intCast(wait_semaphores.len + 1),
            .pWaitSemaphores = @ptrCast(vk_wait_semaphores[0..].ptr),
        };

        try vkt(c.vkQueuePresentKHR(self.queues.present, &present_info));
    }

    pub fn flush(self: *Self) void {
        vkt(c.vkDeviceWaitIdle(self.device)) catch |err| {
            std.log.err("Unable to wait for vulkan device idle: {}", .{err});
            // probably device lost
            unreachable;
        };
    }

    fn image_needs_to_be_recreated_on_swapchain_changes(image: *gf.Image) bool {
        return image.info.match_swapchain_extent;
    }

    fn recreate_swapchain_dependant_gfx_structures(self: *Self) !void {
        self.flush();
        defer self.flush();

        // Recreate images (and image views that refer to images)
        for (gf.GfxState.get().images.data.items, 0..) |*item, idx| {
            if (item.item_data) |*image| {
                if (image_needs_to_be_recreated_on_swapchain_changes(image)) {
                    const image_ref = try gf.Image.Ref.init_from_index(idx);
                    image.reinit(image_ref) catch |err| {
                        std.log.err("Unable to recreate image with new swapchain size: {}", .{err});
                        continue;
                    };
                }
            }
        }

        // Recreate framebuffers
        for (gf.GfxState.get().framebuffers.data.items) |*item| {
            if (item.item_data) |*framebuffer| {
                const should_recreate = sr: for (framebuffer.info.attachments) |attachment| {
                    switch (attachment) {
                        .View => |framebuffer_view| {
                            const view = framebuffer_view.get() catch unreachable;
                            const image = view.info.image.get() catch unreachable;
                            break :sr image_needs_to_be_recreated_on_swapchain_changes(image);
                        },
                        .SwapchainLDR, .SwapchainHDR, .SwapchainDepth => break :sr true,
                    }
                } else false;

                if (should_recreate) {
                    framebuffer.reinit() catch |err| {
                        std.log.warn("Unable to recreate framebuffer with swapchain resize: {}", .{err});
                        continue;
                    };
                }
            }
        }

        // Set all descriptor sets to update themselves over the next few frames
        for (gf.GfxState.get().descriptor_sets.data.items) |*item| {
            if (item.item_data) |*set| {
                set.platform.reapply_all_stored_writes();
            }
        }
    }

    pub fn resize_swapchain(self: *Self, new_width: u32, new_height: u32) !void {
        self.flush();
        defer self.flush();

        self.swapchain.deinit(self);
        self.swapchain = SwapchainVulkan.init(self, .{
            .width = new_width,
            .height = new_height,
            .format = self.swapchain.surface_format,
            .present_mode = self.swapchain.present_mode,
        }) catch |err| {
            std.log.err("Unable to resize swapchain: {}", .{err});
            return err;
        };

        self.recreate_swapchain_dependant_gfx_structures() catch |err| {
            std.log.err("Failed to recreate swapchain dependant gfx structures: {}", .{err});
            return err;
        };
    }

    pub inline fn get_queue_family_index(self: *const Self, queue_family: gf.QueueFamily) u32 {
        return switch (queue_family) {
            .Graphics, .Compute => self.queues.all_family_index,
            .Transfer => self.queues.cpu_gpu_transfer_family_index,
        };
    }
};

const SwapchainVulkan = struct {
    swapchain: c.VkSwapchainKHR,
    swapchain_images: []c.VkImage,
    swapchain_image_views: []c.VkImageView,

    surface_format: c.VkSurfaceFormatKHR,
    present_mode: c.VkPresentModeKHR,
    extent: c.VkExtent2D,

    current_image_index: u32 = 0,
    image_available_semaphores: []gf.Semaphore,
    present_transition_semaphores: []gf.Semaphore,

    pub fn deinit(self: *@This(), gfx_state: *GfxStateVulkan) void {
        for (self.swapchain_image_views) |image_view| {
            c.vkDestroyImageView(gfx_state.device, image_view, null);
        }
        gfx_state.alloc.free(self.swapchain_image_views);
        
        c.vkDestroySwapchainKHR(gfx_state.device, self.swapchain, null);
        gfx_state.alloc.free(self.swapchain_images);

        for (self.image_available_semaphores) |s| { s.deinit(); }
        gfx_state.alloc.free(self.image_available_semaphores);

        for (self.present_transition_semaphores) |s| { s.deinit(); }
        gfx_state.alloc.free(self.present_transition_semaphores);
    }

    pub const SwapchainCreateOptions = struct {
        width: u32,
        height: u32,
        format: c.VkSurfaceFormatKHR,
        present_mode: c.VkPresentModeKHR,
    };

    pub fn init(gfxstate: *GfxStateVulkan, opt: SwapchainCreateOptions) !SwapchainVulkan {
        var surface_capabilities: c.VkSurfaceCapabilitiesKHR = undefined;
        try vkt(c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(gfxstate.physical_device, gfxstate.surface, &surface_capabilities));

        var swapchain_extent = surface_capabilities.currentExtent;
        if (swapchain_extent.width == std.math.maxInt(u32)) {
            swapchain_extent = c.VkExtent2D {
                .width = std.math.clamp(@as(u32, @intCast(opt.width)),
                    surface_capabilities.minImageExtent.width, surface_capabilities.maxImageExtent.width),
                .height = std.math.clamp(@as(u32, @intCast(opt.height)),
                    surface_capabilities.minImageExtent.height, surface_capabilities.maxImageExtent.height),
            };
        }
        if (swapchain_extent.width == 0 or swapchain_extent.height == 0) {
            return error.RequestedSwapchainSizeIsZero;
        }

        var swapchain_create_info = c.VkSwapchainCreateInfoKHR {
            .sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .surface = gfxstate.surface,
            .minImageCount = gfxstate.frames_in_flight(),
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
        const swapchain_create_queue_indices = [2]u32 { gfxstate.queues.all_family_index, gfxstate.queues.present_family_index };
        if (gfxstate.queues.all_family_index == gfxstate.queues.present_family_index) {
            swapchain_create_info.imageSharingMode = c.VK_SHARING_MODE_CONCURRENT;
            swapchain_create_info.queueFamilyIndexCount = @intCast(swapchain_create_queue_indices.len);
            swapchain_create_info.pQueueFamilyIndices = &swapchain_create_queue_indices;
        }

        var vk_swapchain: c.VkSwapchainKHR = undefined;
        try vkt(c.vkCreateSwapchainKHR(gfxstate.device, &swapchain_create_info, null, &vk_swapchain));
        errdefer c.vkDestroySwapchainKHR(gfxstate.device, vk_swapchain, null);

        var swapchain_images_count: u32 = 0;
        try vkt(c.vkGetSwapchainImagesKHR(gfxstate.device, vk_swapchain, &swapchain_images_count, null));
        std.debug.assert(swapchain_images_count == gfxstate.frames_in_flight());

        const swapchain_images = try gfxstate.alloc.alloc(c.VkImage, swapchain_images_count);
        errdefer gfxstate.alloc.free(swapchain_images);

        try vkt(c.vkGetSwapchainImagesKHR(gfxstate.device, vk_swapchain, &swapchain_images_count, swapchain_images.ptr));

        const swapchain_image_views = try gfxstate.alloc.alloc(c.VkImageView, swapchain_images_count);
        errdefer gfxstate.alloc.free(swapchain_image_views);

        var swapchain_image_views_list = std.ArrayList(c.VkImageView).initBuffer(swapchain_image_views);
        errdefer for (swapchain_image_views_list.items) |image_view| { c.vkDestroyImageView(gfxstate.device, image_view, null); };

        for (swapchain_images) |img| {
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
            try vkt(c.vkCreateImageView(gfxstate.device, &view_create_info, null, &swapchain_image_view));
            errdefer c.vkDestroyImageView(gfxstate.device, swapchain_image_view, null);

            try swapchain_image_views_list.append(gfxstate.alloc, swapchain_image_view);
        }

        const image_available_semaphores = try gfxstate.alloc.alloc(gf.Semaphore, gfxstate.frames_in_flight());
        errdefer gfxstate.alloc.free(image_available_semaphores);

        var image_available_semaphores_list = std.ArrayList(gf.Semaphore).initBuffer(image_available_semaphores);
        errdefer for (image_available_semaphores_list.items) |s| { s.deinit(); };

        for (0..gfxstate.frames_in_flight()) |_| {
            const semaphore = try gf.Semaphore.init(.{});
            errdefer semaphore.deinit();

            try image_available_semaphores_list.append(gfxstate.alloc, semaphore);
        }

        const present_transition_semaphores = try gfxstate.alloc.alloc(gf.Semaphore, gfxstate.frames_in_flight());
        errdefer gfxstate.alloc.free(present_transition_semaphores);

        var present_transition_semaphores_list = std.ArrayList(gf.Semaphore).initBuffer(present_transition_semaphores);
        errdefer for (present_transition_semaphores_list.items) |s| { s.deinit(); };

        for (0..gfxstate.frames_in_flight()) |_| {
            const semaphore = try gf.Semaphore.init(.{});
            errdefer semaphore.deinit();

            try present_transition_semaphores_list.append(gfxstate.alloc, semaphore);
        }

        std.log.info("swapchain extent is {}", .{swapchain_extent});
        return .{
            .swapchain = vk_swapchain,
            .swapchain_images = swapchain_images,
            .swapchain_image_views = swapchain_image_views,

            .extent = swapchain_extent,
            .surface_format = opt.format,
            .present_mode = opt.present_mode,
            .image_available_semaphores = image_available_semaphores,
            .present_transition_semaphores = present_transition_semaphores,
        };
    }

    pub inline fn swapchain_image_count(self: *const SwapchainVulkan) u32 {
        return @intCast(self.swapchain_images.len);
    }
};

fn pipelinestageflags_to_vulkan(p: gf.PipelineStageFlags) c.VkPipelineStageFlagBits {
    var flags: c.VkPipelineStageFlagBits = 0;
    if (p.top_of_pipe) { flags |= c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT; }
    if (p.draw_indirect) { flags |= c.VK_PIPELINE_STAGE_DRAW_INDIRECT_BIT; }
    if (p.vertex_input) { flags |= c.VK_PIPELINE_STAGE_VERTEX_INPUT_BIT; }
    if (p.vertex_shader) { flags |= c.VK_PIPELINE_STAGE_VERTEX_SHADER_BIT; }
    if (p.tessellation_control_shader) { flags |= c.VK_PIPELINE_STAGE_TESSELLATION_CONTROL_SHADER_BIT; }
    if (p.tessellation_evaluation_shader) { flags |= c.VK_PIPELINE_STAGE_TESSELLATION_EVALUATION_SHADER_BIT; }
    if (p.geometry_shader) { flags |= c.VK_PIPELINE_STAGE_GEOMETRY_SHADER_BIT; }
    if (p.fragment_shader) { flags |= c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT; }
    if (p.early_fragment_tests) { flags |= c.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT; }
    if (p.late_fragment_tests) { flags |= c.VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT; }
    if (p.color_attachment_output) { flags |= c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT; }
    if (p.compute_shader) { flags |= c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT; }
    if (p.transfer) { flags |= c.VK_PIPELINE_STAGE_TRANSFER_BIT; }
    if (p.bottom_of_pipe) { flags |= c.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT; }
    if (p.host) { flags |= c.VK_PIPELINE_STAGE_HOST_BIT; }
    if (p.all_graphics) { flags |= c.VK_PIPELINE_STAGE_ALL_GRAPHICS_BIT; }
    if (p.all_commands) { flags |= c.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT; }
    return flags;
}

fn accessflags_to_vulkan(p: gf.AccessMaskFlags) c.VkAccessFlagBits {
    var flags: c.VkAccessFlagBits = 0;
    if (p.indirect_command_read) { flags |= c.VK_ACCESS_INDIRECT_COMMAND_READ_BIT; }
    if (p.index_read) { flags |= c.VK_ACCESS_INDEX_READ_BIT; }
    if (p.vertex_attribute_read) { flags |= c.VK_ACCESS_VERTEX_ATTRIBUTE_READ_BIT; }
    if (p.uniform_read) { flags |= c.VK_ACCESS_UNIFORM_READ_BIT; }
    if (p.input_attachment_read) { flags |= c.VK_ACCESS_INPUT_ATTACHMENT_READ_BIT; }
    if (p.shader_read) { flags |= c.VK_ACCESS_SHADER_READ_BIT; }
    if (p.shader_write) { flags |= c.VK_ACCESS_SHADER_WRITE_BIT; }
    if (p.color_attachment_read) { flags |= c.VK_ACCESS_COLOR_ATTACHMENT_READ_BIT; }
    if (p.color_attachment_write) { flags |= c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT; }
    if (p.depth_stencil_attachment_read) { flags |= c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT; }
    if (p.depth_stencil_attachment_write) { flags |= c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT; }
    if (p.transfer_read) { flags |= c.VK_ACCESS_TRANSFER_READ_BIT; }
    if (p.transfer_write) { flags |= c.VK_ACCESS_TRANSFER_WRITE_BIT; }
    if (p.host_read) { flags |= c.VK_ACCESS_HOST_READ_BIT; }
    if (p.host_write) { flags |= c.VK_ACCESS_HOST_WRITE_BIT; }
    if (p.memory_read) { flags |= c.VK_ACCESS_MEMORY_READ_BIT; }
    if (p.memory_write) { flags |= c.VK_ACCESS_MEMORY_WRITE_BIT; }
    return flags;
}

fn imagelayout_to_vulkan(p: gf.ImageLayout) c.VkImageLayout {
    return switch (p) {
        .Undefined => c.VK_IMAGE_LAYOUT_UNDEFINED,
        .General => c.VK_IMAGE_LAYOUT_GENERAL,
        .ColorAttachmentOptimal => c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .DepthStencilAttachmentOptimal => c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        .DepthStencilReadOnlyOptimal => c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL,
        .ShaderReadOnlyOptimal => c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        .TransferSrcOptimal => c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        .TransferDstOptimal => c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        .Preinitialized => c.VK_IMAGE_LAYOUT_PREINITIALIZED,
        .PresentSrc => c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
    };
}

const ShaderModuleVulkan = struct {
    const Self = @This();

    vk_shader_module: c.VkShaderModule,

    pub fn deinit(self: *const Self) void {
        c.vkDestroyShaderModule(eng.get().gfx.platform.device, self.vk_shader_module, null);
    }

    pub fn init(info: gf.ShaderModuleInfo) !Self {
        const gfx = gf.GfxState.get();
        const alloc = gfx.platform.alloc;

        const aligned_data = try alloc.alignedAlloc(u8, std.mem.Alignment.@"4", info.spirv_data.len);
        defer alloc.free(aligned_data);
        @memcpy(aligned_data, info.spirv_data);

        const shader_create_info = c.VkShaderModuleCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .codeSize = @intCast(aligned_data.len),
            .pCode = @ptrCast(aligned_data.ptr),// @ptrCast(@alignCast(shader_data.ptr)),
        };

        var shader_module: c.VkShaderModule = undefined;
        try vkt(c.vkCreateShaderModule(gfx.platform.device, &shader_create_info, null, &shader_module));
        errdefer c.vkDestroyShaderModule(gfx.platform.device, shader_module, null);

        return .{
            .vk_shader_module = shader_module,
        };
    }
};

pub const VertexInputVulkan = struct {
    const Self = @This();

    vk_vertex_input_binding_description: []c.VkVertexInputBindingDescription,
    vk_vertex_input_attrib_description: []c.VkVertexInputAttributeDescription,

    pub fn deinit(self: *const Self) void {
        const alloc = eng.get().gfx.platform.alloc;
        
        alloc.free(self.vk_vertex_input_attrib_description);
        alloc.free(self.vk_vertex_input_binding_description);
    }

    pub fn init(info: gf.VertexInputInfo) !Self {
        const gfx = gf.GfxState.get();
        const alloc = gfx.platform.alloc;

        const vertex_input_bindings = try alloc.alloc(c.VkVertexInputBindingDescription, info.bindings.len);
        errdefer alloc.free(vertex_input_bindings);

        const vertex_input_attrib_descriptions = try alloc.alloc(c.VkVertexInputAttributeDescription, info.attributes.len);
        errdefer alloc.free(vertex_input_attrib_descriptions);

        for (info.bindings, 0..) |binding, idx| {
            vertex_input_bindings[idx] = c.VkVertexInputBindingDescription {
                .binding = binding.binding,
                .stride = binding.stride,
                .inputRate = switch (binding.input_rate) {
                    .Vertex => c.VK_VERTEX_INPUT_RATE_VERTEX,
                    .Instance => c.VK_VERTEX_INPUT_RATE_INSTANCE,
                },
            };
        }

        for (info.attributes, 0..) |attrib, idx| {
            vertex_input_attrib_descriptions[idx] = c.VkVertexInputAttributeDescription {
                .binding = attrib.binding,
                .location = attrib.location,
                .offset = attrib.offset,
                .format = switch (attrib.format) {
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
            .vk_vertex_input_binding_description = vertex_input_bindings,
            .vk_vertex_input_attrib_description = vertex_input_attrib_descriptions,
        };
    }
};

inline fn rect_to_vulkan(rect: Rect) c.VkRect2D {
    return c.VkRect2D {
        .offset = .{
            .x = @intFromFloat(@round(rect.left)),
            .y = @intFromFloat(@round(rect.top)),
        },
        .extent = .{
            .width = @intFromFloat(@round(rect.width())),
            .height = @intFromFloat(@round(rect.height())),
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
    if (usage.StorageBuffer) {
        flags |= c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
    }
    if (usage.TransferSrc) {
        flags |= c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
    }
    if (usage.TransferDst) {
        flags |= c.VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    }

    return flags;
}

fn convert_texture_usage_flags_to_vulkan(usage: gf.ImageUsageFlags) c.VkImageUsageFlags {
    var flags: c.VkImageUsageFlags = 0;

    if (usage.RenderTarget) {
        flags |= c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    }
    if (usage.DepthStencil) {
        flags |= c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT;
    }
    if (usage.ShaderResource) {
        flags |= c.VK_IMAGE_USAGE_SAMPLED_BIT;
    }
    if (usage.StorageResource) {
        flags |= c.VK_IMAGE_USAGE_STORAGE_BIT;
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

fn begin_single_time_command_buffer(command_pool: *gf.CommandPool) !gf.CommandBuffer {
    var cmd = try command_pool.allocate_command_buffer(.{ .level = .Primary });
    errdefer cmd.deinit();

    try cmd.cmd_begin(.{ .one_time_submit = true, });
    errdefer cmd.cmd_end() catch {};

    return cmd;
}

fn end_single_time_command_buffer(cmd: *gf.CommandBuffer, signal_semaphore: ?gf.Semaphore) void {
    if (cmd.cmd_end()) {
        var fence_exists: bool = true;
        var fence = gf.Fence.init(.{}) catch |err| blk: {
            std.log.warn("Unable to create fence: {}", .{err});
            fence_exists = false;
            break :blk undefined;
        };
        defer if (fence_exists) { fence.deinit(); };

        GfxStateVulkan.get().submit_command_buffer(.{
            .command_buffers = &.{ cmd },
            .signal_semaphores = if (signal_semaphore) |s| &.{ &s } else &.{},
            .fence = fence,
        }) catch |err| {
            std.log.warn("Unable to submit one time command buffer: {}", .{err});
        };

        fence.wait() catch |err| {
            std.log.warn("Unable to wait on fence: {}", .{err});
            GfxStateVulkan.get().flush();
        };
        if (!fence_exists) {
            GfxStateVulkan.get().flush();
        }
    } else |err| {
        std.log.warn("Unable to end command buffer: {}", .{err});
    }

    cmd.deinit();
}

inline fn align_up(value: anytype, alignment: anytype) @TypeOf(value) {
    return @divFloor(value + alignment - 1, alignment) * alignment;
}

inline fn lcm(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    return (a * b) / std.math.gcd(a, b);
}

pub const BufferVulkan = struct {
    const Self = @This();

    buffer_size: u64,
    aligned_buffer_size: u64,
    vk_buffers: []c.VkBuffer,
    vk_device_memory: c.VkDeviceMemory,

    pub fn deinit(self: *const Self) void {
        // Remove this buffer from FiF buffer data propogation structure
        {
            var iter = std.mem.reverseIterator(GfxStateVulkan.get().buffer_updates.items);
            while (iter.nextPtr()) |item| {
                if (item.vk_buffers[0] == self.vk_buffers[0]) {
                    _ = GfxStateVulkan.get().buffer_updates.swapRemove(iter.index);
                }
            }
        }

        // Free vulkan memory and destroy vulkan buffers
        for (self.vk_buffers) |buf| {
            c.vkDestroyBuffer(eng.get().gfx.platform.device, buf, null);
        }
        c.vkFreeMemory(eng.get().gfx.platform.device, self.vk_device_memory, null);

        // Free cpu memory assosciated with buffer
        GfxStateVulkan.get().alloc.free(self.vk_buffers);
    }

    pub fn init(
        byte_size: u32,
        usage_flags: gf.BufferUsageFlags,
        access_flags: gf.AccessFlags,
    ) !Self {
        const fif = GfxStateVulkan.get().frames_in_flight();
        const alloc = GfxStateVulkan.get().alloc;

        // @TODO: use the dedicated transfer queue
        const use_shared = false; // gfx.platform.queues.has_distinct_transfer_queue() and
            // (access_flags.CpuRead or access_flags.CpuWrite);
        const family_indices: []const u32 = &.{
            GfxStateVulkan.get().queues.all_family_index,
            GfxStateVulkan.get().queues.cpu_gpu_transfer_family_index
        };


        const buffer_is_immutable = (access_flags.CpuWrite == false and access_flags.GpuWrite == false);
        const vk_buffer_count = if (buffer_is_immutable) 1 else fif;

        var usage_flags_plus = usage_flags;
        // Allow FiF transfers
        if (vk_buffer_count == fif) {
            usage_flags_plus.TransferSrc = true;
            usage_flags_plus.TransferDst = true;
        }

        const buffer_create_info = c.VkBufferCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .sharingMode = if (use_shared) c.VK_SHARING_MODE_CONCURRENT else c.VK_SHARING_MODE_EXCLUSIVE,
            .pQueueFamilyIndices = @ptrCast(family_indices.ptr),
            .queueFamilyIndexCount = if (use_shared) @intCast(family_indices.len) else 1,
            .size = @intCast(byte_size),
            .usage = convert_buffer_usage_flags_to_vulkan(usage_flags_plus),
        };
        std.debug.assert(buffer_create_info.usage != 0);

        const vk_buffers = try alloc.alloc(c.VkBuffer, vk_buffer_count);
        errdefer alloc.free(vk_buffers);

        var vk_buffers_list = std.ArrayList(c.VkBuffer).initBuffer(vk_buffers);
        errdefer for (vk_buffers_list.items) |b| { c.vkDestroyBuffer(GfxStateVulkan.get().device, b, null); };

        for (0..vk_buffer_count) |_| {
            var vk_buffer: c.VkBuffer = undefined;
            try vkt(c.vkCreateBuffer(GfxStateVulkan.get().device, &buffer_create_info, null, &vk_buffer));
            errdefer c.vkDestroyBuffer(GfxStateVulkan.get().device, vk_buffer, null);

            try vk_buffers_list.append(alloc, vk_buffer);
        }

        var vk_memory_requirements: c.VkMemoryRequirements = undefined;
        c.vkGetBufferMemoryRequirements(GfxStateVulkan.get().device, vk_buffers_list.items[0], &vk_memory_requirements);

        const memory_properties: c.VkMemoryPropertyFlags = if (access_flags.CpuRead or access_flags.CpuWrite)
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT
            else c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;

        const vk_limits = GfxStateVulkan.get().physical_device_properties.limits;

        var lcm_alignment: u64 = 1;
        if (access_flags.CpuRead or access_flags.CpuWrite) {
            lcm_alignment = lcm(lcm_alignment, vk_limits.minMemoryMapAlignment);
        }
        if (usage_flags_plus.ConstantBuffer) {
            lcm_alignment = lcm(lcm_alignment, vk_limits.minUniformBufferOffsetAlignment);
        }
        // TODO check if this will explode alignment value or not
        // if (usage_flags_plus.TransferSrc or usage_flags_plus.TransferDst) {
        //     lcm_alignment = lcm(lcm_alignment, vk_limits.optimalBufferCopyOffsetAlignment);
        // }
        const vk_buffer_size_aligned = align_up(vk_memory_requirements.size, lcm_alignment);

        const memory_allocate_info = c.VkMemoryAllocateInfo {
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = vk_buffer_size_aligned * vk_buffer_count,
            .memoryTypeIndex = try find_vulkan_memory_type(
                vk_memory_requirements.memoryTypeBits,
                memory_properties,
            ),
        };

        // TODO better memory allocation strategy
        var vk_device_memory: c.VkDeviceMemory = undefined;
        try vkt(c.vkAllocateMemory(GfxStateVulkan.get().device, &memory_allocate_info, null, &vk_device_memory));
        errdefer c.vkFreeMemory(GfxStateVulkan.get().device, vk_device_memory, null);

        for (vk_buffers_list.items, 0..) |vk_buffer, idx| {
            try vkt(c.vkBindBufferMemory(GfxStateVulkan.get().device, vk_buffer, vk_device_memory, idx * vk_buffer_size_aligned));
        }

        return .{
            .buffer_size = @intCast(byte_size),
            .aligned_buffer_size = @intCast(vk_buffer_size_aligned),
            .vk_buffers = vk_buffers,
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

        const staging = try Self.init_staging(data.len);
        defer staging.deinit();

        {
            var data_ptr: ?*anyopaque = undefined;
            try vkt(c.vkMapMemory(GfxStateVulkan.get().device, staging.vk_device_memory, 0, staging.buffer_size, 0, &data_ptr));
            defer c.vkUnmapMemory(GfxStateVulkan.get().device, staging.vk_device_memory);

            @memcpy(@as([*]u8, @ptrCast(data_ptr))[0..(data.len)], data[0..]);
        }

        var command_buffer = try begin_single_time_command_buffer(&GfxStateVulkan.get().all_command_pool);

        for (self.vk_buffers) |vk_buffer| {
            const buffer_copy_region = c.VkBufferCopy {
                .size = data.len,
                .dstOffset = 0,
                .srcOffset = 0,
            };
            c.vkCmdCopyBuffer(command_buffer.platform.vk_command_buffer, staging.get_frame_vk_buffer(), vk_buffer, 1, &buffer_copy_region);
        }

        end_single_time_command_buffer(&command_buffer, null);

        return self;
    }

    fn init_staging(
        byte_size: usize,
    ) !Self {
        const alloc = GfxStateVulkan.get().alloc;

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
            .usage = convert_buffer_usage_flags_to_vulkan(.{ .TransferSrc = true, }),
        };
        std.debug.assert(buffer_create_info.usage != 0);

        var vk_buffer: c.VkBuffer = undefined;
        try vkt(c.vkCreateBuffer(GfxStateVulkan.get().device, &buffer_create_info, null, &vk_buffer));
        errdefer c.vkDestroyBuffer(GfxStateVulkan.get().device, vk_buffer, null);

        var vk_memory_requirements: c.VkMemoryRequirements = undefined;
        c.vkGetBufferMemoryRequirements(GfxStateVulkan.get().device, vk_buffer, &vk_memory_requirements);

        const memory_properties: c.VkMemoryPropertyFlags = 
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;

        const vk_limits = GfxStateVulkan.get().physical_device_properties.limits;

        var lcm_alignment: u64 = 1;
        lcm_alignment = lcm(lcm_alignment, vk_limits.minMemoryMapAlignment);
        lcm_alignment = lcm(lcm_alignment, vk_limits.optimalBufferCopyOffsetAlignment);
        const vk_buffer_size_aligned = align_up(vk_memory_requirements.size, lcm_alignment);

        const memory_allocate_info = c.VkMemoryAllocateInfo {
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = vk_buffer_size_aligned,
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

        const vk_buffers = try alloc.alloc(c.VkBuffer, 1);
        errdefer alloc.free(vk_buffers);

        vk_buffers[0] = vk_buffer;

        return .{
            .buffer_size = @intCast(byte_size),
            .aligned_buffer_size = @intCast(vk_buffer_size_aligned),
            .vk_buffers = vk_buffers,
            .vk_device_memory = vk_device_memory,
        };
    }

    pub fn map(self: *const Self, options: gf.Buffer.MapOptions) !MappedBuffer {
        const cfi = GfxStateVulkan.get().current_frame_index();
        const buffer_index = cfi % self.vk_buffers.len;

        var data_ptr: ?*anyopaque = undefined;
        try vkt(c.vkMapMemory(
                GfxStateVulkan.get().device,
                self.vk_device_memory,
                @as(u64, @intCast(buffer_index)) * self.aligned_buffer_size,
                self.buffer_size,
                0,
                &data_ptr
        ));

        if (options.write == .Infrequent and self.vk_buffers.len > 1) {
            for (GfxStateVulkan.get().buffer_updates.items) |*item| {
                if (item.vk_buffers[0] == self.vk_buffers[0]) {
                    item.count = 0;
                    break;
                }
            } else {
                try GfxStateVulkan.get().buffer_updates.append(GfxStateVulkan.get().alloc, GfxStateVulkan.BufferUpdates {
                    .vk_buffers = self.vk_buffers,
                    .size = self.buffer_size,
                    .count = 0,
                });
            }
        }

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

    pub fn get_frame_vk_buffer(self: *const BufferVulkan) c.VkBuffer {
        const cfi = GfxStateVulkan.get().current_frame_index();
        return self.vk_buffers[@as(usize, @intCast(cfi)) % self.vk_buffers.len];
    }
};

pub const ImageVulkan = struct {
    const Self = @This();

    const ImageData = struct {
        vk_image: c.VkImage,
        vk_device_memory: c.VkDeviceMemory,
    };

    images: []ImageData,
    vk_format: c.VkFormat,
    format: gf.ImageFormat,

    pub fn deinit(self: *const Self) void {
        for (self.images) |i| {
            c.vkDestroyImage(GfxStateVulkan.get().device, i.vk_image, null);
            c.vkFreeMemory(GfxStateVulkan.get().device, i.vk_device_memory, null);
        }
        GfxStateVulkan.get().alloc.free(self.images);
    }

    pub fn init(
        info: gf.ImageInfo,
        data: ?[]const u8,
    ) !Self {
        std.debug.assert(data == null or (data != null and info.dst_layout != .Undefined));

        const alloc = GfxStateVulkan.get().alloc;

        var usage_flags_plus = info.usage_flags;
        if (data != null) {
            usage_flags_plus.TransferDst = true;
        }
        if (data != null and info.mip_levels > 1) {
            usage_flags_plus.TransferSrc = true;
        }
        const vk_usage_flags = convert_texture_usage_flags_to_vulkan(usage_flags_plus);

        const vk_format = textureformat_to_vulkan(info.format);

        const image_count = 
            if (usage_flags_plus.RenderTarget or usage_flags_plus.DepthStencil) GfxStateVulkan.get().frames_in_flight()
            else 1;

        const images = try alloc.alloc(ImageData, image_count);
        errdefer alloc.free(images);

        var images_list = std.ArrayList(ImageData).initBuffer(images);
        errdefer for (images_list.items) |i| {
            c.vkFreeMemory(GfxStateVulkan.get().device, i.vk_device_memory, null);
            c.vkDestroyImage(GfxStateVulkan.get().device, i.vk_image, null);
        };

        const vk_image_type: c.VkImageType = if (info.depth <= 1) c.VK_IMAGE_TYPE_2D else c.VK_IMAGE_TYPE_3D; 

        for (0..image_count) |_| {
            const image_info = c.VkImageCreateInfo {
                .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
                .format = vk_format,
                .imageType = vk_image_type,
                .extent = c.VkExtent3D {
                    .width = info.width,
                    .height = info.height,
                    .depth = @max(info.depth, 1),
                },
                .mipLevels = info.mip_levels,
                .arrayLayers = info.array_length,
                .tiling = c.VK_IMAGE_TILING_OPTIMAL,
                .initialLayout = imagelayout_to_vulkan(.Undefined),
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

            try images_list.append(alloc, .{
                .vk_image = vk_image,
                .vk_device_memory = vk_device_memory,
            });
        }

        var self = Self {
            .images = images,
            .vk_format = vk_format,
            .format = info.format,
        };

        if (data) |d| {
            const buffer_length = info.width * info.height * info.array_length * info.format.byte_width();
            const staging_buffer = try BufferVulkan.init_staging(@intCast(buffer_length));
            defer staging_buffer.deinit();

            {
                var mapped_buffer = try staging_buffer.map(.{ .write = .Infrequent, });
                defer mapped_buffer.unmap();

                const mapped_slice = mapped_buffer.data_array(u8, buffer_length);
                @memcpy(mapped_slice, d);
            }

            for (0..images.len) |image_idx| {
                try self.transition_layout(image_idx, .Undefined, .TransferDstOptimal);

                {
                    var command_buffer = try begin_single_time_command_buffer(&GfxStateVulkan.get().all_command_pool);
                    defer end_single_time_command_buffer(&command_buffer, null);

                    const region = c.VkBufferImageCopy {
                        .bufferOffset = 0,
                        .bufferRowLength = 0,
                        .bufferImageHeight = 0,

                        .imageSubresource = .{
                            .aspectMask = 
                                if (self.format.is_depth()) c.VK_IMAGE_ASPECT_DEPTH_BIT | c.VK_IMAGE_ASPECT_STENCIL_BIT
                                else c.VK_IMAGE_ASPECT_COLOR_BIT,
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

                    c.vkCmdCopyBufferToImage(
                        command_buffer.platform.vk_command_buffer,
                        staging_buffer.get_frame_vk_buffer(),
                        images[image_idx].vk_image,
                        c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                        1,
                        &region
                    );

                    // generate mipmaps
                    var mip_width: i32 = @intCast(info.width);
                    var mip_height: i32 = @intCast(info.height);

                    for (1..info.mip_levels) |mip_level| {
                        const barrier0_info = c.VkImageMemoryBarrier {
                            .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                            .image = images[image_idx].vk_image,
                            .oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                            .newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                            .srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT,
                            .dstAccessMask = c.VK_ACCESS_TRANSFER_READ_BIT,
                            .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
                            .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
                            .subresourceRange = .{
                                .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                                .baseArrayLayer = 0,
                                .layerCount = 1,
                                .baseMipLevel = @intCast(mip_level - 1),
                                .levelCount = 1,
                            }
                        };

                        c.vkCmdPipelineBarrier(
                            command_buffer.platform.vk_command_buffer,
                            c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_TRANSFER_BIT, 0,
                            0, null,
                            0, null,
                            1, @ptrCast(&barrier0_info)
                        );

                        const blit = c.VkImageBlit {
                            .srcOffsets = .{
                                .{ .x = 0, .y = 0, .z = 0, },
                                .{ .x = mip_width, .y = mip_height, .z = 1 },
                            },
                            .dstOffsets = .{
                                .{ .x = 0, .y = 0, .z = 0 },
                                .{ .x = if (mip_width > 1) @divTrunc(mip_width, 2) else 1, .y = if (mip_height > 1) @divTrunc(mip_height, 2) else 1, .z = 1 },
                            },
                            .srcSubresource = .{
                                .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                                .baseArrayLayer = 0,
                                .layerCount = 1,
                                .mipLevel = @intCast(mip_level - 1),
                            },
                            .dstSubresource = .{
                                .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                                .baseArrayLayer = 0,
                                .layerCount = 1,
                                .mipLevel = @intCast(mip_level),
                            }
                        };

                        c.vkCmdBlitImage(
                            command_buffer.platform.vk_command_buffer,
                            images[image_idx].vk_image, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                            images[image_idx].vk_image, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                            1, &blit,
                            c.VK_FILTER_LINEAR
                        );

                        const barrier1_info = c.VkImageMemoryBarrier {
                            .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                            .image = images[image_idx].vk_image,
                            .oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                            .newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                            .srcAccessMask = c.VK_ACCESS_TRANSFER_READ_BIT,
                            .dstAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT,
                            .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
                            .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
                            .subresourceRange = .{
                                .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                                .baseArrayLayer = 0,
                                .layerCount = 1,
                                .baseMipLevel = @intCast(mip_level - 1),
                                .levelCount = 1,
                            }
                        };

                        c.vkCmdPipelineBarrier(
                            command_buffer.platform.vk_command_buffer,
                            c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_ALL_GRAPHICS_BIT, 0,
                            0, null,
                            0, null,
                            1, @ptrCast(&barrier1_info)
                        );

                        if (mip_width > 1) { mip_width = @divTrunc(mip_width, 2); }
                        if (mip_height > 1) { mip_height = @divTrunc(mip_height, 2); }
                    }
                }
            }
        }

        for (0..images.len) |image_idx| {
            try self.transition_layout(
                image_idx,
                if (data) |_| .TransferDstOptimal else .Undefined,
                info.dst_layout
            );
        }

        return self;
    }

    pub inline fn get_frame_image(self: *const Self) *const ImageData {
        const idx = GfxStateVulkan.get().current_frame_index();
        return &self.images[@as(usize, @intCast(idx)) % self.images.len];
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

    fn transition_layout(
        self: *Self, 
        image_index: usize,
        old_layout: gf.ImageLayout, 
        new_layout: gf.ImageLayout,
    ) !void {
        var cmd = try begin_single_time_command_buffer(&GfxStateVulkan.get().all_command_pool);
        defer end_single_time_command_buffer(&cmd, null);

        var src_access: c.VkAccessFlags = 0;
        var dst_access: c.VkAccessFlags = 0;

        var src_stage: c.VkPipelineStageFlags = 0;
        var dst_stage: c.VkPipelineStageFlags = 0;

        switch (old_layout) {
            .Undefined => {
                src_stage = c.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
            },
            .TransferDstOptimal => {
                src_access = c.VK_ACCESS_TRANSFER_WRITE_BIT;
                src_stage = c.VK_PIPELINE_STAGE_TRANSFER_BIT;
            },
            else => unreachable,
        }

        switch (new_layout) {
            .ShaderReadOnlyOptimal => {
                dst_access = c.VK_ACCESS_SHADER_READ_BIT;
                dst_stage = c.VK_PIPELINE_STAGE_ALL_GRAPHICS_BIT;
            },
            .TransferDstOptimal => {
                dst_access = c.VK_ACCESS_TRANSFER_WRITE_BIT;
                dst_stage = c.VK_PIPELINE_STAGE_TRANSFER_BIT;
            },
            .DepthStencilAttachmentOptimal => {
                dst_access = c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
                dst_stage = c.VK_PIPELINE_STAGE_ALL_GRAPHICS_BIT;
            },
            .DepthStencilReadOnlyOptimal => {
                dst_access = c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT;
                dst_stage = c.VK_PIPELINE_STAGE_ALL_GRAPHICS_BIT;
            },
            .ColorAttachmentOptimal => {
                dst_access = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
                dst_stage = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
            },
            .PresentSrc => {
                dst_access = c.VK_ACCESS_COLOR_ATTACHMENT_READ_BIT;
                dst_stage = c.VK_PIPELINE_STAGE_ALL_GRAPHICS_BIT;
            },
            .General => {
                dst_access = c.VK_ACCESS_SHADER_WRITE_BIT;
                dst_stage = c.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
            },
            .Undefined => unreachable,
            else => unreachable,
        }

        const image_barrier = c.VkImageMemoryBarrier {
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .image = self.images[image_index].vk_image,
            .oldLayout = imagelayout_to_vulkan(old_layout),
            .newLayout = imagelayout_to_vulkan(new_layout),
            .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .srcAccessMask = src_access,
            .dstAccessMask = dst_access,
            .subresourceRange = .{
                .aspectMask = 
                    if (self.format.is_depth()) c.VK_IMAGE_ASPECT_DEPTH_BIT | c.VK_IMAGE_ASPECT_STENCIL_BIT
                    else c.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = c.VK_REMAINING_MIP_LEVELS,
                .baseArrayLayer = 0,
                .layerCount = c.VK_REMAINING_ARRAY_LAYERS,
            },
        };
        c.vkCmdPipelineBarrier(
            cmd.platform.vk_command_buffer, 
            src_stage, 
            dst_stage, 
            0, 
            0, null,
            0, null,
            1, &image_barrier
        );
    }
};

inline fn imageaspect_to_vulkan(aspect: gf.ImageAspect) c.VkImageAspectFlags {
    var vk_aspect: c.VkImageAspectFlags = 0;
    if (aspect.colour) { vk_aspect |= c.VK_IMAGE_ASPECT_COLOR_BIT; }
    if (aspect.depth) { vk_aspect |= c.VK_IMAGE_ASPECT_DEPTH_BIT; }
    if (aspect.stencil) { vk_aspect |= c.VK_IMAGE_ASPECT_STENCIL_BIT; }
    return vk_aspect;
}

pub const ImageViewVulkan = struct {
    const Self = @This();

    vk_image_views: []c.VkImageView,
    
    pub fn deinit(self: *const ImageViewVulkan) void {
        for (self.vk_image_views) |v| {
            c.vkDestroyImageView(GfxStateVulkan.get().device, v, null);
        }
        GfxStateVulkan.get().alloc.free(self.vk_image_views);
    }

    pub fn init(info: gf.ImageViewInfo) !ImageViewVulkan {
        const alloc = GfxStateVulkan.get().alloc;
        const img = try info.image.get();

        const view_type: c.VkImageViewType = switch (info.view_type) {
            .ImageView1D => c.VK_IMAGE_VIEW_TYPE_1D,
            .ImageView2D => c.VK_IMAGE_VIEW_TYPE_2D,
            .ImageView2DArray => c.VK_IMAGE_VIEW_TYPE_2D_ARRAY,
            .ImageView3D => c.VK_IMAGE_VIEW_TYPE_3D,
        };

        const image_views = try alloc.alloc(c.VkImageView, img.platform.images.len);
        errdefer alloc.free(image_views);

        var image_views_list = std.ArrayList(c.VkImageView).initBuffer(image_views);
        errdefer for (image_views_list.items) |v| { c.vkDestroyImageView(GfxStateVulkan.get().device, v, null); };

        const aspect_mask = if (info.aspect_mask) |am| imageaspect_to_vulkan(am) else unreachable;

        for (img.platform.images) |i| {
            const image_view_info = c.VkImageViewCreateInfo {
                .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                .image = i.vk_image, 
                .viewType = view_type,
                .format = img.platform.vk_format,
                .subresourceRange = .{
                    .aspectMask = aspect_mask,
                    .baseMipLevel = info.mip_levels.?.base_mip_level,
                    .levelCount = info.mip_levels.?.mip_level_count,
                    .baseArrayLayer = info.array_layers.?.base_array_layer,
                    .layerCount = info.array_layers.?.array_layer_count,
                },
            };

            var vk_image_view: c.VkImageView = undefined;
            try vkt(c.vkCreateImageView(GfxStateVulkan.get().device, &image_view_info, null, &vk_image_view));
            errdefer c.vkDestroyImageView(GfxStateVulkan.get().device, vk_image_view, null);

            try image_views_list.append(alloc, vk_image_view);
        }

        return ImageViewVulkan {
            .vk_image_views = image_views,
        };
    }

    pub inline fn get_frame_view(self: *const Self) c.VkImageView {
        if (self.vk_image_views.len == 1) { return self.vk_image_views[0]; }
        const idx = GfxStateVulkan.get().current_frame_index();
        std.debug.assert(idx < self.vk_image_views.len);
        return self.vk_image_views[idx];
    }
};

inline fn samplerfilter_to_vulkan(filter: gf.SamplerFilter) c.VkFilter {
    return switch (filter) {
        .Linear => c.VK_FILTER_LINEAR,
        .Point => c.VK_FILTER_NEAREST,
    };
}

inline fn samplermipmapmode_to_vulkan(mipmapmode: gf.SamplerFilter) c.VkSamplerMipmapMode {
    return switch (mipmapmode) {
        .Linear => c.VK_SAMPLER_MIPMAP_MODE_LINEAR,
        .Point => c.VK_SAMPLER_MIPMAP_MODE_NEAREST,
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

    pub fn init(info: gf.SamplerInfo) !Self {
        const sampler_info = c.VkSamplerCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            
            .magFilter = samplerfilter_to_vulkan(info.filter_min_mag),
            .minFilter = samplerfilter_to_vulkan(info.filter_min_mag),

            .mipmapMode = samplermipmapmode_to_vulkan(info.filter_mip),
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
            .D16S8_Unorm_Uint,
            .R32_Uint => c.VkClearValue {
                .color = .{ .uint32 = .{
                    @intFromFloat(clear_value[0] * 255.0),
                    @intFromFloat(clear_value[1] * 255.0),
                    @intFromFloat(clear_value[2] * 255.0),
                    @intFromFloat(clear_value[3] * 255.0),
                } }
            },
            .Unknown,
            .R32_Float,
            .Rg32_Float,
            .Rgb32_Float,
            .Rgba16_Float,
            .Rgba32_Float,
            .Bgra8_Srgb,
            .D32S8_Sfloat_Uint,
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

    const SubpassRefInfo = struct {
        attachment_refs: []usize,
        depth_ref: ?usize,
    };
    
    vk_render_pass: c.VkRenderPass,
    vk_clear_values: []c.VkClearValue,

    subpass_attachment_refs: []SubpassRefInfo,

    pub fn deinit(self: *const Self) void {
        const alloc = GfxStateVulkan.get().alloc;

        c.vkDestroyRenderPass(GfxStateVulkan.get().device, self.vk_render_pass, null);

        alloc.free(self.vk_clear_values);

        for (self.subpass_attachment_refs) |r| {
            alloc.free(r.attachment_refs);
        }
        alloc.free(self.subpass_attachment_refs);
    }

    pub fn init(info: gf.RenderPassInfo) !RenderPassVulkan {
        const alloc = GfxStateVulkan.get().alloc;

        var arena_obj = std.heap.ArenaAllocator.init(alloc);
        defer arena_obj.deinit();
        const arena = arena_obj.allocator();

        const subpass_refs = try alloc.alloc(SubpassRefInfo, info.subpasses.len);
        errdefer alloc.free(subpass_refs);
        {
            var subpass_refs_list = std.ArrayList(SubpassRefInfo).initBuffer(subpass_refs);
            errdefer for (subpass_refs_list.items) |s| { alloc.free(s.attachment_refs); };

            for (info.subpasses) |subpass| {
                const subpass_attachment_refs = try alloc.alloc(usize, subpass.attachments.len);
                errdefer alloc.free(subpass_attachment_refs);

                for (subpass.attachments, 0..) |subpass_attachment_name, subpass_aidx| {
                    const attachment_idx = find_attachment_by_name(subpass_attachment_name, info.attachments) catch {
                        return error.UnableToFindColourAttachmentName;
                    };
                    subpass_attachment_refs[subpass_aidx] = attachment_idx;
                }

                const depth_ref = if (subpass.depth_attachment) |depth_name| depth_blk: {
                    const attachment_idx = find_attachment_by_name(depth_name, info.attachments) catch {
                        return error.UnableToFindDepthAttachmentName;
                    };
                    break :depth_blk attachment_idx;
                } else null;

                try subpass_refs_list.appendBounded(SubpassRefInfo {
                    .attachment_refs = subpass_attachment_refs,
                    .depth_ref = depth_ref,
                });
            }

            std.debug.assert(subpass_refs_list.items.len == info.subpasses.len);
        }

        var subpass_descriptions = try arena.alloc(c.VkSubpassDescription, subpass_refs.len);
        defer arena.free(subpass_descriptions);

        for (subpass_refs, 0..) |ref, idx| {
            var attachment_refs = try arena.alloc(c.VkAttachmentReference, ref.attachment_refs.len);
            // freed by arena allocator
            
            for (ref.attachment_refs, 0..) |aidx, ridx| {
                attachment_refs[ridx] = .{
                    .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, // @TODO: depth? other layouts?
                    .attachment = @intCast(aidx),
                };
            }

            var depth_attachment_ref = if (ref.depth_ref) |r| c.VkAttachmentReference {
                .layout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
                .attachment = @intCast(r),
            } else null;

            subpass_descriptions[idx] = c.VkSubpassDescription{
                .pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS, // @TODO: other?
                .pColorAttachments = @ptrCast(attachment_refs.ptr),
                .colorAttachmentCount = @intCast(attachment_refs.len),
                .pDepthStencilAttachment = if (depth_attachment_ref) |*d| d else null,
                // @TODO: resolve attachments, preserve attachments, etc.
            };
        }

        var attachment_descriptions = try arena.alloc(c.VkAttachmentDescription, info.attachments.len);
        defer arena.free(attachment_descriptions);

        var vk_clear_values = try alloc.alloc(c.VkClearValue, info.attachments.len);
        errdefer alloc.free(vk_clear_values);

        for (info.attachments, 0..) |*a, idx| {
            attachment_descriptions[idx] = c.VkAttachmentDescription {
                .format = textureformat_to_vulkan(a.format),
                .initialLayout = imagelayout_to_vulkan(a.initial_layout),
                .finalLayout = imagelayout_to_vulkan(a.final_layout),
                .loadOp = loadop_to_vulkan(a.load_op),
                .storeOp = storeop_to_vulkan(a.store_op),
                .stencilLoadOp = loadop_to_vulkan(a.stencil_load_op),
                .stencilStoreOp = storeop_to_vulkan(a.stencil_store_op),
                .samples = c.VK_SAMPLE_COUNT_1_BIT,
            };

            vk_clear_values[idx] = formatclearvalue_to_vulkan(a.format, a.clear_value);
        }

        var vk_dependencies = try alloc.alloc(c.VkSubpassDependency, info.dependencies.len);
        defer alloc.free(vk_dependencies);

        for (info.dependencies, 0..) |d, idx| {
            vk_dependencies[idx] = c.VkSubpassDependency {
                .srcSubpass = if (d.src_subpass) |s| s else c.VK_SUBPASS_EXTERNAL,
                .dstSubpass = d.dst_subpass,
                .srcStageMask = pipelinestageflags_to_vulkan(d.src_stage_mask),
                .srcAccessMask = accessflags_to_vulkan(d.src_access_mask),
                .dstStageMask = pipelinestageflags_to_vulkan(d.dst_stage_mask),
                .dstAccessMask = accessflags_to_vulkan(d.dst_access_mask),
            };
        }

        const render_pass_info = c.VkRenderPassCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,

            .pAttachments = @ptrCast(attachment_descriptions.ptr),
            .attachmentCount = @intCast(attachment_descriptions.len),

            .pSubpasses = @ptrCast(subpass_descriptions.ptr),
            .subpassCount = @intCast(subpass_descriptions.len),

            .pDependencies = @ptrCast(vk_dependencies.ptr),
            .dependencyCount = @intCast(vk_dependencies.len),
        };

        var vk_render_pass: c.VkRenderPass = undefined;
        try vkt(c.vkCreateRenderPass(eng.get().gfx.platform.device, &render_pass_info, null, &vk_render_pass));
        errdefer c.vkDestroyRenderPass(eng.get().gfx.platform.device, vk_render_pass, null);

        return RenderPassVulkan {
            .vk_render_pass = vk_render_pass,
            .vk_clear_values = vk_clear_values,
            .subpass_attachment_refs = subpass_refs,
        };
    }

    inline fn find_attachment_by_name(name: []const u8, attachments: []const gf.AttachmentInfo) !usize {
        return for (attachments, 0..) |attachment, aidx| {
            if (std.mem.eql(u8, attachment.name, name)) {
                break aidx;
            }
        } else return error.UnableToFindAttachmentWithName;
    }
};

inline fn textureformat_to_vulkan(format: gf.ImageFormat) c.VkFormat {
    return switch (format) {
        .R32_Float => c.VK_FORMAT_R32_SFLOAT,
        .Rg32_Float => c.VK_FORMAT_R32G32_SFLOAT,
        .Rgb32_Float => c.VK_FORMAT_R32G32B32_SFLOAT,
        .Rgba32_Float => c.VK_FORMAT_R32G32B32A32_SFLOAT,
        .Rgba16_Float => c.VK_FORMAT_R16G16B16A16_SFLOAT,
        .R32_Uint => c.VK_FORMAT_R32_UINT,
        .Bgra8_Unorm => c.VK_FORMAT_B8G8R8A8_UNORM,
        .Bgra8_Srgb => c.VK_FORMAT_B8G8R8A8_SRGB,
        .D24S8_Unorm_Uint => c.VK_FORMAT_D24_UNORM_S8_UINT,
        .D16S8_Unorm_Uint => c.VK_FORMAT_D16_UNORM_S8_UINT,
        .D32S8_Sfloat_Uint => c.VK_FORMAT_D32_SFLOAT_S8_UINT,
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
        std.debug.assert(info.subpass_index < render_pass.platform.subpass_attachment_refs.len);

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

        const vertex_input = &info.vertex_input.platform;
        const vertex_input_info = c.VkPipelineVertexInputStateCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,

            .pVertexBindingDescriptions = @ptrCast(vertex_input.vk_vertex_input_binding_description.ptr),
            .vertexBindingDescriptionCount = @intCast(vertex_input.vk_vertex_input_binding_description.len),

            .pVertexAttributeDescriptions = @ptrCast(vertex_input.vk_vertex_input_attrib_description.ptr),
            .vertexAttributeDescriptionCount = @intCast(vertex_input.vk_vertex_input_attrib_description.len),
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

        const subpass_attachment_refs = render_pass.platform.subpass_attachment_refs[info.subpass_index];

        var color_blend_attachments = try arena.alloc(c.VkPipelineColorBlendAttachmentState, subpass_attachment_refs.attachment_refs.len);
        defer arena.free(color_blend_attachments);

        var color_blend_attachments_len: u32 = 0;
        for (subpass_attachment_refs.attachment_refs) |aidx| {
            std.debug.assert(aidx < render_pass.attachments_info.len);
            const attachment = render_pass.attachments_info[aidx];

            if (!attachment.format.is_depth()) {
                color_blend_attachments[color_blend_attachments_len] = blendtype_to_vulkan(attachment.blend_type); 
                color_blend_attachments_len += 1;
            }
        }

        const color_blend_info = c.VkPipelineColorBlendStateCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .pAttachments = @ptrCast(color_blend_attachments.ptr),
            .attachmentCount = color_blend_attachments_len,
            .logicOpEnable = c.VK_FALSE,
            .logicOp = c.VK_LOGIC_OP_COPY,
            .blendConstants = .{ 0.0, 0.0, 0.0, 0.0 },
        };

        const vk_set_layouts = try arena.alloc(c.VkDescriptorSetLayout, info.descriptor_set_layouts.len);
        defer arena.free(vk_set_layouts);

        for (info.descriptor_set_layouts, 0..) |l, idx| {
            const layout = try l.get();
            vk_set_layouts[idx] = layout.platform.vk_layout;
        }

        const vk_push_constant_ranges = try arena.alloc(c.VkPushConstantRange, info.push_constants.len);
        defer arena.free(vk_push_constant_ranges);

        for (info.push_constants, 0..) |p, idx| {
            std.debug.assert((p.offset % 4) == 0);
            std.debug.assert((p.size % 4) == 0);
            std.debug.assert((p.offset + p.size) <= 128);

            vk_push_constant_ranges[idx] = c.VkPushConstantRange {
                .stageFlags = shaderstageflags_to_vulkan(p.shader_stages),
                .offset = p.offset,
                .size = p.size,
            };
        }

        const pipeline_layout_info = c.VkPipelineLayoutCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .pSetLayouts = @ptrCast(vk_set_layouts.ptr),
            .setLayoutCount = @intCast(vk_set_layouts.len),
            .pPushConstantRanges = @ptrCast(vk_push_constant_ranges.ptr),
            .pushConstantRangeCount = @intCast(vk_push_constant_ranges.len),
        };

        var vk_pipeline_layout: c.VkPipelineLayout = undefined;
        try vkt(c.vkCreatePipelineLayout(eng.get().gfx.platform.device, &pipeline_layout_info, null, &vk_pipeline_layout));
        errdefer c.vkDestroyPipelineLayout(eng.get().gfx.platform.device, vk_pipeline_layout, null);

        const vk_shader_stages = try arena.alloc(c.VkPipelineShaderStageCreateInfo, 2); // TODO get other shader stages working
        defer arena.free(vk_shader_stages);

        vk_shader_stages[0] = c.VkPipelineShaderStageCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = c.VK_SHADER_STAGE_VERTEX_BIT,
            .module = info.vertex_shader.module.platform.vk_shader_module,
            .pName = @ptrCast(info.vertex_shader.entry_point.ptr),
            .pSpecializationInfo = null,
        };
        vk_shader_stages[1] = c.VkPipelineShaderStageCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT,
            .module = info.pixel_shader.module.platform.vk_shader_module,
            .pName = @ptrCast(info.pixel_shader.entry_point.ptr),
            .pSpecializationInfo = null,
        };
        
        const graphics_pipeline_info = c.VkGraphicsPipelineCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,

            .pStages = @ptrCast(vk_shader_stages.ptr),
            .stageCount = @intCast(vk_shader_stages.len),

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

pub const ComputePipelineVulkan = struct {
    const Self = @This();

    vk_pipeline_layout: c.VkPipelineLayout,
    vk_compute_pipeline: c.VkPipeline,

    pub fn deinit(self: *const Self) void {
        const device = eng.get().gfx.platform.device;
        c.vkDestroyPipeline(device, self.vk_compute_pipeline, null);
        c.vkDestroyPipelineLayout(device, self.vk_pipeline_layout, null);
    }
    
    pub fn init(info: gf.ComputePipelineInfo) !Self {
        const alloc = eng.get().frame_allocator;
        var arena_struct = std.heap.ArenaAllocator.init(alloc);
        defer arena_struct.deinit();
        const arena = arena_struct.allocator();

        const pipeline_shader_stage_info = c.VkPipelineShaderStageCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = c.VK_SHADER_STAGE_COMPUTE_BIT,
            .module = info.compute_shader.module.platform.vk_shader_module,
            .pName = @ptrCast(info.compute_shader.entry_point.ptr),
            .pSpecializationInfo = null,
        };

        const vk_set_layouts = try arena.alloc(c.VkDescriptorSetLayout, info.descriptor_set_layouts.len);
        defer arena.free(vk_set_layouts);

        for (info.descriptor_set_layouts, 0..) |l, idx| {
            const layout = try l.get();
            vk_set_layouts[idx] = layout.platform.vk_layout;
        }

        const vk_push_constant_ranges = try arena.alloc(c.VkPushConstantRange, info.push_constants.len);
        defer arena.free(vk_push_constant_ranges);

        for (info.push_constants, 0..) |p, idx| {
            std.debug.assert((p.offset % 4) == 0);
            std.debug.assert((p.size % 4) == 0);

            vk_push_constant_ranges[idx] = c.VkPushConstantRange {
                .stageFlags = shaderstageflags_to_vulkan(p.shader_stages),
                .offset = p.offset,
                .size = p.size,
            };
        }

        const pipeline_layout_info = c.VkPipelineLayoutCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .pSetLayouts = @ptrCast(vk_set_layouts.ptr),
            .setLayoutCount = @intCast(vk_set_layouts.len),
            .pPushConstantRanges = @ptrCast(vk_push_constant_ranges.ptr),
            .pushConstantRangeCount = @intCast(vk_push_constant_ranges.len),
        };

        var vk_pipeline_layout: c.VkPipelineLayout = undefined;
        try vkt(c.vkCreatePipelineLayout(eng.get().gfx.platform.device, &pipeline_layout_info, null, &vk_pipeline_layout));
        errdefer c.vkDestroyPipelineLayout(eng.get().gfx.platform.device, vk_pipeline_layout, null);

        const compute_pipeline_info = c.VkComputePipelineCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
            .layout = vk_pipeline_layout,
            .stage = pipeline_shader_stage_info,
        };

        var vk_compute_pipeline: c.VkPipeline = undefined;
        try vkt(c.vkCreateComputePipelines(eng.get().gfx.platform.device, @ptrCast(c.VK_NULL_HANDLE), 1, &compute_pipeline_info, null, &vk_compute_pipeline));
        errdefer c.vkDestroyPipeline(eng.get().gfx.platform.device, vk_compute_pipeline, null);
       
        return Self {
            .vk_pipeline_layout = vk_pipeline_layout,
            .vk_compute_pipeline = vk_compute_pipeline,
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
        .SwapchainLDR, .SwapchainHDR, .SwapchainDepth => .{
            .width = GfxStateVulkan.get().swapchain.extent.width,
            .height = GfxStateVulkan.get().swapchain.extent.height,
            .layers = 1,
        },
        .View => |v| blk: {
            const view = v.get() catch unreachable;
            break :blk .{
                .width = view.size.width,
                .height = view.size.height,
                .layers = view.info.array_layers.?.array_layer_count,
            };
        },
    };
}

pub const FrameBufferVulkan = struct {
    vk_framebuffers: []c.VkFramebuffer,
    
    pub fn deinit(self: *const FrameBufferVulkan) void {
        const alloc = GfxStateVulkan.get().alloc;
        for (self.vk_framebuffers) |f| {
            c.vkDestroyFramebuffer(eng.get().gfx.platform.device, f, null);
        }
        alloc.free(self.vk_framebuffers);
    }

    pub fn init(info: gf.FrameBufferInfo) !FrameBufferVulkan {
        if (info.attachments.len == 0) { return error.NoAttachmentsProvided; }
        const render_pass = try info.render_pass.get();

        const alloc = GfxStateVulkan.get().alloc;

        const create_multiple_for_frames_in_flight = blk: {
            var swapchain_index: ?usize = null;
            for (info.attachments, 0..) |a, i| {
                switch (a) {
                    .SwapchainLDR, .SwapchainHDR, .SwapchainDepth, .View => {
                        swapchain_index = i;
                        break;
                    },
                    //else => {},
                }
            }
            break :blk (swapchain_index != null);
        };

        const swapchain_images_count = eng.get().gfx.platform.swapchain.swapchain_image_count();
        const framebuffers = try alloc.alloc(c.VkFramebuffer, if (create_multiple_for_frames_in_flight) swapchain_images_count else 1);
        errdefer alloc.free(framebuffers);

        const framebuffer_extent = framebufferattachment_extent(info.attachments[0]);

        const attachments = try alloc.alloc(c.VkImageView, info.attachments.len);
        defer alloc.free(attachments);

        for (framebuffers, 0..) |*framebuffer, fidx| {
            for (info.attachments, 0..) |*a, aidx| {
                attachments[aidx] = switch (a.*) {
                    .SwapchainLDR => blk: {
                        break :blk GfxStateVulkan.get().swapchain.swapchain_image_views[fidx];
                    },
                    .SwapchainHDR => blk: {
                        const view = try gf.GfxState.get().default.hdr_image_view.get();
                        std.debug.assert(view.platform.vk_image_views.len == GfxStateVulkan.get().frames_in_flight());
                        break :blk view.platform.vk_image_views[fidx];
                    },
                    .SwapchainDepth => blk: {
                        const view = try gf.GfxState.get().default.depth_view.get();
                        std.debug.assert(view.platform.vk_image_views.len == GfxStateVulkan.get().frames_in_flight());
                        break :blk view.platform.vk_image_views[fidx];
                    },
                    .View => |v| blk: {
                        const view = try v.get();
                        std.debug.assert(view.platform.vk_image_views.len == GfxStateVulkan.get().frames_in_flight());
                        break :blk view.platform.vk_image_views[fidx];
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

    pub fn get_frame_framebuffer(self: *const FrameBufferVulkan) c.VkFramebuffer {
        const idx = @min(GfxStateVulkan.get().current_frame_index(), self.vk_framebuffers.len - 1);
        return self.vk_framebuffers[idx];
    }
};

fn bindingtype_to_vulkan(bindingtype: gf.BindingType) c.VkDescriptorType {
    return switch (bindingtype) {
        .ImageView => c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
        .ImageViewAndSampler => c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .Sampler => c.VK_DESCRIPTOR_TYPE_SAMPLER,
        .UniformBuffer => c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        .StorageBuffer => c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        .StorageImage => c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,
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
    if (shaderstageflags.Compute) {
        flags |= c.VK_SHADER_STAGE_COMPUTE_BIT;
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

        const vk_pool_sizes: []c.VkDescriptorPoolSize = switch (info.strategy) {
            .Layout => |layout_ref| blk: {
                const layout = try layout_ref.get();

                var descriptor_counts: [@typeInfo(gf.BindingType).@"enum".fields.len]u32 = undefined;
                @memset(descriptor_counts[0..], 0);

                for (layout.info.bindings) |binding| {
                    descriptor_counts[@intFromEnum(binding.binding_type)] += binding.array_count;
                }

                var vk_pool_sizes_list = try std.ArrayList(c.VkDescriptorPoolSize).initCapacity(alloc, descriptor_counts.len);
                defer vk_pool_sizes_list.deinit(alloc);

                for (descriptor_counts[0..], 0..) |desc, idx| {
                    if (desc > 0) {
                        try vk_pool_sizes_list.append(alloc, c.VkDescriptorPoolSize {
                            .type = bindingtype_to_vulkan(@enumFromInt(idx)),
                            .descriptorCount = desc,
                        });
                    }
                }

                vk_pool_sizes_list.shrinkAndFree(alloc, vk_pool_sizes_list.items.len);
                break :blk try vk_pool_sizes_list.toOwnedSlice(alloc);
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
            pool_size.descriptorCount *= info.max_sets * GfxStateVulkan.get().frames_in_flight();
        }

        const pool_info = c.VkDescriptorPoolCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .maxSets = info.max_sets * GfxStateVulkan.get().frames_in_flight(),
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
        const fif = GfxStateVulkan.get().frames_in_flight();
        const number_of_vk_sets = number_of_sets * fif;

        // todo multiple sets using multiple different layouts?
        const layout = try info.layout.get();

        const layouts = try alloc.alloc(c.VkDescriptorSetLayout, number_of_vk_sets);
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

        const vk_sets = try alloc.alloc(c.VkDescriptorSet, number_of_vk_sets);
        defer alloc.free(vk_sets);

        try vkt(c.vkAllocateDescriptorSets(GfxStateVulkan.get().device, &alloc_info, @ptrCast(vk_sets.ptr)));
        errdefer {
            if (false) { // TODO free individual sets
                vkt(c.vkFreeDescriptorSets(GfxStateVulkan.get().device, self.vk_pool, @intCast(vk_sets.len), @ptrCast(vk_sets.ptr))) catch |err| {
                    std.log.err("Unable to free descriptor sets: {}", .{err});
                };
            }
        }

        const sets = try alloc.alloc(gf.DescriptorSet, number_of_sets);
        errdefer alloc.free(sets);

        var vk_sets_window_iter = std.mem.window(c.VkDescriptorSet, vk_sets, fif, fif);
        var idx: usize = 0;
        while (vk_sets_window_iter.next()) |vk_set_chunk| {
            sets[idx] = gf.DescriptorSet {
                .platform = try DescriptorSetVulkan.init(self.vk_pool, vk_set_chunk, false),
            };
            idx += 1;
        }

        if (idx != number_of_sets) {
            return error.WasntAbleToFillAllRequestedSets;
        }

        return sets;
    }
};

pub const DescriptorSetVulkan = struct {
    const UpdateWriteInfo = struct {
        const BitSetMaxSize = 16;
        const UpdatedSetsBitSet = std.bit_set.IntegerBitSet(BitSetMaxSize);

        write: gf.DescriptorSetUpdateWriteInfo,
        updated_sets: UpdatedSetsBitSet = UpdatedSetsBitSet.initEmpty(),
    };

    vk_sets: []c.VkDescriptorSet,
    vk_pool: c.VkDescriptorPool,
    can_free_individual_sets: bool, // TODO free individual sets?

    write_infos: std.AutoHashMap(u32, UpdateWriteInfo),
    completed_update_propogations: bool = false,

    pub fn deinit(self: *DescriptorSetVulkan) void {
        const alloc = GfxStateVulkan.get().alloc;

        if (self.can_free_individual_sets) {
            vkt(c.vkFreeDescriptorSets(GfxStateVulkan.get().device, self.vk_pool, @intCast(self.vk_sets.len), @ptrCast(self.vk_sets.ptr))) catch |err| {
                std.log.err("Unable to free descriptor sets: {}", .{err});
            };
        }
        alloc.free(self.vk_sets);
        
        var write_infos_iter = self.write_infos.valueIterator();
        while (write_infos_iter.next()) |write_info| {
            deinit_update_write_info(&write_info.write);
        }
        self.write_infos.deinit();
    }

    fn init(vk_pool: c.VkDescriptorPool, vk_sets: []const c.VkDescriptorSet, can_free_individual_sets: bool) !DescriptorSetVulkan {
        std.debug.assert(GfxStateVulkan.get().frames_in_flight() < UpdateWriteInfo.BitSetMaxSize);

        const owned_vk_sets = try GfxStateVulkan.get().alloc.dupe(c.VkDescriptorSet, vk_sets);
        errdefer GfxStateVulkan.get().alloc.free(owned_vk_sets);

        return .{
            .vk_sets = owned_vk_sets,
            .vk_pool = vk_pool,
            .can_free_individual_sets = can_free_individual_sets,
            .write_infos = std.AutoHashMap(u32, UpdateWriteInfo).init(GfxStateVulkan.get().alloc),
        };
    }

    fn get_frame_set(self: *const DescriptorSetVulkan) c.VkDescriptorSet {
        return self.vk_sets[@min(GfxStateVulkan.get().current_frame_index(), self.vk_sets.len)];
    }

    fn deinit_update_write_info(info: *const gf.DescriptorSetUpdateWriteInfo) void {
        const alloc = GfxStateVulkan.get().alloc;

        switch (info.data) {
            .UniformBufferArray => |a| { alloc.free(a); },
            .StorageBufferArray => |a| { alloc.free(a); },
            .ImageViewArray => |a| { alloc.free(a); },
            .SamplerArray => |a| { alloc.free(a); },
            .ImageViewAndSamplerArray => |a| { alloc.free(a); },
            else => {},
        }
    }

    fn dupe_update_info(info: gf.DescriptorSetUpdateWriteInfo) !gf.DescriptorSetUpdateWriteInfo {
        const alloc = GfxStateVulkan.get().alloc;

        var duped_info = info;

        switch (info.data) {
            .UniformBufferArray => |a| {
                duped_info.data = .{ .UniformBufferArray = try alloc.dupe(gf.DescriptorSetWriteBufferInfo, a), };
            },
            .StorageBufferArray => |a| {
                duped_info.data = .{ .StorageBufferArray = try alloc.dupe(gf.DescriptorSetWriteBufferInfo, a), };
            },
            .ImageViewArray => |a| {
                duped_info.data = .{ .ImageViewArray = try alloc.dupe(gf.ImageView.Ref, a), };
            },
            .SamplerArray => |a| {
                duped_info.data = .{ .SamplerArray = try alloc.dupe(gf.Sampler.Ref, a), };
            },
            .ImageViewAndSamplerArray => |a| {
                duped_info.data = .{ .ImageViewAndSamplerArray = try alloc.dupe(gf.ImageViewAndSampler, a), };
            },
            else => {},
        }

        return duped_info;
    }

    pub fn update(self: *DescriptorSetVulkan, info: gf.DescriptorSetUpdateInfo) !void {
        for (info.writes) |write| {
            const duped_write = dupe_update_info(write) catch |err| {
                std.log.warn("Unable to dupe descriptor write info: {}", .{err});
                continue;
            };

            const maybe_fetched_write_info = self.write_infos.fetchPut(
                duped_write.binding,
                UpdateWriteInfo { .write = duped_write, }
            ) catch |err| {
                std.log.warn("Unable to put new write info into descriptor set: {}", .{err});
                continue;
            };

            if (maybe_fetched_write_info) |*fetched_write_info| {
                deinit_update_write_info(&fetched_write_info.value.write);
            }
        }

        self.completed_update_propogations = false;
    }

    pub fn reapply_all_stored_writes(self: *DescriptorSetVulkan) void {
        var write_info_iter = self.write_infos.valueIterator();
        while (write_info_iter.next()) |write_info| {
            write_info.updated_sets = UpdateWriteInfo.UpdatedSetsBitSet.initEmpty();
        }

        self.completed_update_propogations = false;
    }

    pub fn perform_updates_if_required(self: *DescriptorSetVulkan) !void {
        if (!self.completed_update_propogations) {
            try self.perform_updates_on_current_frame_set();
        }
    }

    fn perform_updates_on_current_frame_set(self: *DescriptorSetVulkan) !void {
        const alloc = GfxStateVulkan.get().alloc;
        const cfi = GfxStateVulkan.get().current_frame_index();
        const fif = GfxStateVulkan.get().frames_in_flight();
        std.debug.assert(cfi < self.vk_sets.len);

        var arena_obj = std.heap.ArenaAllocator.init(alloc);
        defer arena_obj.deinit();
        const arena = arena_obj.allocator();

        var writes_needed_list = try std.ArrayList(*const gf.DescriptorSetUpdateWriteInfo).initCapacity(alloc, 32);
        defer writes_needed_list.deinit(alloc);

        var more_updates_to_come = false;
        var writes_iter = self.write_infos.valueIterator();
        while (writes_iter.next()) |write| {
            if (!more_updates_to_come and write.updated_sets.count() < fif) {
                more_updates_to_come = true;
            }
            if (!write.updated_sets.isSet(cfi)) {
                try writes_needed_list.append(alloc, &write.write);
                write.updated_sets.set(cfi);
            }
        }

        if (!more_updates_to_come) {
            std.debug.assert(writes_needed_list.items.len == 0);
            self.completed_update_propogations = true;
            return;
        }

        const vk_write_infos = try arena.alloc(c.VkWriteDescriptorSet, writes_needed_list.items.len);
        defer arena.free(vk_write_infos);

        for (writes_needed_list.items, 0..) |write, idx| {
            const vk_write_info = &vk_write_infos[idx];

            vk_write_info.* = c.VkWriteDescriptorSet {
                .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .dstSet = self.vk_sets[cfi],
                .dstBinding = write.binding,
                .dstArrayElement = write.array_element,
                .descriptorCount = undefined,
                .descriptorType = bindingtype_to_vulkan(switch (write.data) {
                    .UniformBuffer, .UniformBufferArray => .UniformBuffer,
                    .StorageBuffer, .StorageBufferArray => .StorageBuffer,
                    .ImageView, .ImageViewArray => .ImageView,
                    .Sampler, .SamplerArray => .Sampler,
                    .ImageViewAndSampler, .ImageViewAndSamplerArray => .ImageViewAndSampler,
                    .StorageImage, .StorageImageArray => .StorageImage,
                }),
                .pBufferInfo = null,
                .pImageInfo = null,
                .pTexelBufferView = null,
            };

            switch (write.data) {
                .UniformBuffer, .StorageBuffer => |bw| {
                    const buffer = try bw.buffer.get();

                    const buffer_data = try arena.create(c.VkDescriptorBufferInfo);
                    buffer_data.* = c.VkDescriptorBufferInfo {
                        .buffer = buffer.platform.get_frame_vk_buffer(), // TODO frames in flight is a pain in the ass
                        .offset = bw.offset,
                        .range = bw.range,
                    };

                    vk_write_info.descriptorCount = 1;
                    vk_write_info.pBufferInfo = buffer_data;
                },
                .ImageView, .StorageImage => |iw| {
                    const view = try iw.get();

                    const view_data = try arena.create(c.VkDescriptorImageInfo);
                    view_data.* = c.VkDescriptorImageInfo {
                        .sampler = null,
                        .imageView = view.platform.get_frame_view(),
                        .imageLayout = switch (write.data) {
                            .ImageView => c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                            .StorageImage => c.VK_IMAGE_LAYOUT_GENERAL,
                            else => unreachable,
                        },
                    };
                    
                    vk_write_info.descriptorCount = 1;
                    vk_write_info.pImageInfo = view_data;
                },
                .Sampler => |sw| {
                    const sampler = try sw.get();

                    const view_data = try arena.create(c.VkDescriptorImageInfo);
                    view_data.* = c.VkDescriptorImageInfo {
                        .sampler = sampler.platform.vk_sampler,
                        .imageView = null,
                        .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                    };

                    vk_write_info.descriptorCount = 1;
                    vk_write_info.pImageInfo = view_data;
                },
                .ImageViewAndSampler => |iw| {
                    const view = try iw.view.get();
                    const sampler = try iw.sampler.get();

                    const view_data = try arena.create(c.VkDescriptorImageInfo);
                    view_data.* = c.VkDescriptorImageInfo {
                        .imageView = view.platform.get_frame_view(),
                        .sampler = sampler.platform.vk_sampler,
                        .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                    };

                    vk_write_info.descriptorCount = 1;
                    vk_write_info.pImageInfo = view_data;
                },
                .UniformBufferArray, .StorageBufferArray => |buffer_writes| {
                    const buffer_data_array = try arena.alloc(c.VkDescriptorBufferInfo, buffer_writes.len);

                    for (buffer_writes, 0..) |bw, bw_idx| {
                        const buffer = try bw.buffer.get();

                        buffer_data_array[bw_idx] = c.VkDescriptorBufferInfo {
                            .buffer = buffer.platform.get_frame_vk_buffer(),
                            .offset = bw.offset,
                            .range = bw.range,
                        };
                    }

                    vk_write_info.descriptorCount = @intCast(buffer_data_array.len);
                    vk_write_info.pBufferInfo = buffer_data_array.ptr;
                },
                .ImageViewArray, .StorageImageArray => |image_writes| {
                    const data_array = try arena.alloc(c.VkDescriptorImageInfo, image_writes.len);

                    for (image_writes, 0..) |iw, iw_idx| {
                        const view = try iw.get();

                        data_array[iw_idx] = c.VkDescriptorImageInfo {
                            .sampler = null,
                            .imageView = view.platform.get_frame_view(),
                            .imageLayout = switch (write.data) {
                                .ImageViewArray => c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                                .StorageImageArray => c.VK_IMAGE_LAYOUT_GENERAL,
                                else => unreachable,
                            },
                        };
                    }

                    vk_write_info.descriptorCount = @intCast(data_array.len);
                    vk_write_info.pImageInfo = data_array.ptr;
                },
                .SamplerArray => |sampler_writes| {
                    const data_array = try arena.alloc(c.VkDescriptorImageInfo, sampler_writes.len);

                    for (sampler_writes, 0..) |sw, sw_idx| {
                        const sampler = try sw.get();

                        data_array[sw_idx] = c.VkDescriptorImageInfo {
                            .sampler = sampler.platform.vk_sampler,
                            .imageView = null,
                            .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                        };
                    }

                    vk_write_info.descriptorCount = @intCast(data_array.len);
                    vk_write_info.pImageInfo = data_array.ptr;
                },
                .ImageViewAndSamplerArray => |image_writes| {
                    const data_array = try arena.alloc(c.VkDescriptorImageInfo, image_writes.len);

                    for (image_writes, 0..) |iw, iw_idx| {
                        const view = try iw.view.get();
                        const sampler = try iw.sampler.get();

                        data_array[iw_idx] = c.VkDescriptorImageInfo {
                            .imageView = view.platform.get_frame_view(),
                            .sampler = sampler.platform.vk_sampler,
                            .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                        };
                    }
                    
                    vk_write_info.descriptorCount = @intCast(data_array.len);
                    vk_write_info.pImageInfo = data_array.ptr;
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
        //std.debug.assert(poolflags_to_vulkan(info) != 0);

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

    pub fn allocate_command_buffers(self: *CommandPoolVulkan, info: gf.CommandBufferInfo, comptime count: usize) ![count]CommandBufferVulkan {
        const alloc_info = c.VkCommandBufferAllocateInfo {
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandBufferCount = count,
            .commandPool = self.vk_pool,
            .level = commandbufferlevel_to_vulkan(info.level),
        };

        var vk_command_buffers: [count]c.VkCommandBuffer = undefined;
        try vkt(c.vkAllocateCommandBuffers(GfxStateVulkan.get().device, &alloc_info, &vk_command_buffers));
        errdefer c.vkFreeCommandBuffers(GfxStateVulkan.get().device, self.vk_pool, count, &vk_command_buffers);

        var buffers: [count]CommandBufferVulkan = undefined;
        inline for (vk_command_buffers, 0..) |vk_b, idx| {
            buffers[idx] = CommandBufferVulkan {
                .vk_pool = self.vk_pool,
                .vk_command_buffer = vk_b,
            };
        }

        return buffers;
    }
};

inline fn commandbufferlevel_to_vulkan(level: gf.CommandBufferLevel) c.VkCommandBufferLevel {
    return switch (level) {
        .Primary => c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .Secondary => c.VK_COMMAND_BUFFER_LEVEL_SECONDARY,
    };
}

inline fn commandbufferbeginflags_to_vulkan(f: gf.CommandBuffer.BeginInfo) c.VkCommandBufferUsageFlags {
    var flags: c.VkCommandBufferUsageFlags = 0;
    if (f.one_time_submit) {
        flags |= c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    }
    if (f.render_pass_continue) {
        flags |= c.VK_COMMAND_BUFFER_USAGE_RENDER_PASS_CONTINUE_BIT;
    }
    if (f.simultaneous_use) {
        flags |= c.VK_COMMAND_BUFFER_USAGE_SIMULTANEOUS_USE_BIT;
    }
    return flags;
}

pub const CommandBufferVulkan = struct {
    const Self = @This();

    vk_pool: c.VkCommandPool,
    vk_command_buffer: c.VkCommandBuffer,

    bound_pipeline: union(enum) {
        None: void,
        Graphics: gf.GraphicsPipeline.Ref,
        Compute: gf.ComputePipeline.Ref,
    } = .None,

    pub fn deinit(self: *const Self) void {
        c.vkFreeCommandBuffers(GfxStateVulkan.get().device, self.vk_pool, 1, &self.vk_command_buffer);
    }

    pub fn reset(self: *Self) !void {
        try vkt(c.vkResetCommandBuffer(self.vk_command_buffer, 0));
    }

    pub fn cmd_begin(self: *Self, info: gf.CommandBuffer.BeginInfo) !void {
        const begin_info = c.VkCommandBufferBeginInfo {
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = commandbufferbeginflags_to_vulkan(info),
        };

        try vkt(c.vkBeginCommandBuffer(self.vk_command_buffer, &begin_info));
    }

    pub fn cmd_end(self: *Self) !void {
        try vkt(c.vkEndCommandBuffer(self.vk_command_buffer));
    }

    fn subpasscontents_to_vulkan(subpasscontents: gf.CommandBuffer.SubpassContents) c.VkSubpassContents {
        return switch (subpasscontents) {
            .Inline => c.VK_SUBPASS_CONTENTS_INLINE,
            .SecondaryCommandBuffers => c.VK_SUBPASS_CONTENTS_SECONDARY_COMMAND_BUFFERS,
        };
    }

    pub fn cmd_begin_render_pass(self: *Self, info: gf.CommandBuffer.BeginRenderPassInfo) void {
        const render_pass = info.render_pass.get() catch return;
        const framebuffer = info.framebuffer.get() catch return;
        
        const begin_info = c.VkRenderPassBeginInfo {
            .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            .renderPass = render_pass.platform.vk_render_pass,
            .framebuffer = framebuffer.platform.get_frame_framebuffer(),
            .pClearValues = @ptrCast(render_pass.platform.vk_clear_values.ptr),
            .clearValueCount = @intCast(render_pass.platform.vk_clear_values.len),
            .renderArea = rect_to_vulkan(info.render_area),
        };

        c.vkCmdBeginRenderPass(self.vk_command_buffer, &begin_info, subpasscontents_to_vulkan(info.subpass_contents));
    }

    pub fn cmd_next_subpass(self: *Self, info: gf.CommandBuffer.NextSubpassInfo) void {
        c.vkCmdNextSubpass(self.vk_command_buffer, subpasscontents_to_vulkan(info.subpass_contents));
    }

    pub fn cmd_end_render_pass(self: *Self) void {
        c.vkCmdEndRenderPass(self.vk_command_buffer);
    }

    pub fn cmd_bind_graphics_pipeline(self: *Self, pipeline: gf.GraphicsPipeline.Ref) void {
        const p = pipeline.get() catch return;

        self.bound_pipeline = .{ .Graphics = pipeline };
        c.vkCmdBindPipeline(self.vk_command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, p.platform.vk_graphics_pipeline);
    }

    pub fn cmd_bind_compute_pipeline(self: *Self, pipeline: gf.ComputePipeline.Ref) void {
        const p = pipeline.get() catch return;

        self.bound_pipeline = .{ .Compute = pipeline, };
        c.vkCmdBindPipeline(self.vk_command_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, p.platform.vk_compute_pipeline);
    }

    const max_vk_viewports = 6;
    pub fn cmd_set_viewports(self: *Self, info: gf.CommandBuffer.SetViewportsInfo) void {
        std.debug.assert(info.viewports.len <= max_vk_viewports);

        var vk_viewports: [max_vk_viewports]c.VkViewport = undefined;
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

    pub fn cmd_set_scissors(self: *Self, info: gf.CommandBuffer.SetScissorsInfo) void {
        std.debug.assert(info.scissors.len <= max_vk_viewports);

        var vk_scissors: [max_vk_viewports]c.VkRect2D = undefined;
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

        var vk_buffers: [max_vertex_buffers]c.VkBuffer = undefined;
        var vk_device_sizes: [max_vertex_buffers]c.VkDeviceSize = undefined;
        for (info.buffers, 0..) |b, idx| {
            const buffer = b.buffer.get() catch unreachable;
            vk_buffers[idx] = buffer.platform.get_frame_vk_buffer();
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
            buffer.platform.get_frame_vk_buffer(),
            info.offset,
            indexformat_to_vulkan(info.index_format)
        );
    }

    pub fn cmd_bind_descriptor_sets(self: *Self, info: gf.CommandBuffer.BindDescriptorSetInfo) void {
        const max_descriptor_sets = 16;
        std.debug.assert(info.descriptor_sets.len <= 16);

        var vk_descriptor_sets: [max_descriptor_sets]c.VkDescriptorSet = undefined;
        for (info.descriptor_sets, 0..) |s, idx| {
            const set = s.get() catch unreachable;
            set.platform.perform_updates_if_required() catch |err| {
                std.log.warn("Unable to perform updates on the bound descriptor set: {}", .{err});
            };

            vk_descriptor_sets[idx] = set.platform.get_frame_set();
        }

        const vk_bind_point: c.VkPipelineBindPoint, const vk_pipeline_layout = switch (self.bound_pipeline) {
            .Graphics => |p| .{ c.VK_PIPELINE_BIND_POINT_GRAPHICS, (p.get() catch unreachable).platform.vk_pipeline_layout },
            .Compute => |p| .{ c.VK_PIPELINE_BIND_POINT_COMPUTE, (p.get() catch unreachable).platform.vk_pipeline_layout },
            .None => {
                std.log.warn("Attempted to bind descriptor sets when no pipeline was bound.", .{});
                return;
            },
        };

        c.vkCmdBindDescriptorSets(
            self.vk_command_buffer,
            vk_bind_point,
            vk_pipeline_layout,
            info.first_binding,
            @intCast(info.descriptor_sets.len),
            @ptrCast(vk_descriptor_sets[0..].ptr),
            @intCast(info.dynamic_offsets.len),
            @ptrCast(info.dynamic_offsets.ptr)
        );
    }

    pub fn cmd_push_constants(self: *Self, info: gf.CommandBuffer.PushConstantsInfo) void {
        const vk_pipeline_layout = switch (self.bound_pipeline) {
            .Graphics => |p| (p.get() catch unreachable).platform.vk_pipeline_layout,
            .Compute => |p| (p.get() catch unreachable).platform.vk_pipeline_layout,
            .None => {
                std.log.warn("Attempted to push constants when no pipeline was bound.", .{});
                return;
            },
        };

        c.vkCmdPushConstants(
            self.vk_command_buffer,
            vk_pipeline_layout,
            shaderstageflags_to_vulkan(info.shader_stages),
            info.offset,
            @intCast(info.data.len),
            @ptrCast(info.data.ptr)
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

    pub fn cmd_pipeline_barrier(self: *Self, info: gf.CommandBuffer.PipelineBarrierInfo) void {
        const max_barriers_per_type = 8;
        std.debug.assert(info.memory_barriers.len < max_barriers_per_type);
        std.debug.assert(info.buffer_barriers.len < max_barriers_per_type);
        std.debug.assert(info.image_barriers.len < max_barriers_per_type);

        var vk_memory_barriers: [max_barriers_per_type]c.VkMemoryBarrier = undefined;
        var vk_buffer_barriers: [max_barriers_per_type]c.VkBufferMemoryBarrier = undefined;
        var vk_image_barriers: [max_barriers_per_type]c.VkImageMemoryBarrier = undefined;

        for (info.memory_barriers, 0..) |b, idx| {
            vk_memory_barriers[idx] = c.VkMemoryBarrier {
                .sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER,
                .srcAccessMask = accessflags_to_vulkan(b.src_access_mask),
                .dstAccessMask = accessflags_to_vulkan(b.dst_access_mask),
            };
        }

        for (info.buffer_barriers, 0..) |b, idx| {
            const buffer = b.buffer.get() catch unreachable;
            vk_buffer_barriers[idx] = c.VkBufferMemoryBarrier {
                .sType = c.VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
                .buffer = buffer.platform.get_frame_vk_buffer(),
                .offset = b.offset,
                .size = b.size,
                .srcAccessMask = accessflags_to_vulkan(b.src_access_mask),
                .dstAccessMask = accessflags_to_vulkan(b.dst_access_mask),
                .srcQueueFamilyIndex = if (b.src_queue) |q| GfxStateVulkan.get().get_queue_family_index(q) else c.VK_QUEUE_FAMILY_IGNORED,
                .dstQueueFamilyIndex = if (b.dst_queue) |q| GfxStateVulkan.get().get_queue_family_index(q) else c.VK_QUEUE_FAMILY_IGNORED,
            };
        }

        for (info.image_barriers, 0..) |b, idx| {
            const image = b.image.get() catch unreachable;
            vk_image_barriers[idx] = c.VkImageMemoryBarrier {
                .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                .image = image.platform.get_frame_image().vk_image, // TODO allow selecting inner image?
                .oldLayout = if (b.old_layout) |l| imagelayout_to_vulkan(l) else c.VK_IMAGE_LAYOUT_UNDEFINED,
                .newLayout = if (b.new_layout) |l| imagelayout_to_vulkan(l) else c.VK_IMAGE_LAYOUT_UNDEFINED,
                .srcAccessMask = accessflags_to_vulkan(b.src_access_mask),
                .dstAccessMask = accessflags_to_vulkan(b.dst_access_mask),
                .srcQueueFamilyIndex = if (b.src_queue) |q| GfxStateVulkan.get().get_queue_family_index(q) else c.VK_QUEUE_FAMILY_IGNORED,
                .dstQueueFamilyIndex = if (b.dst_queue) |q| GfxStateVulkan.get().get_queue_family_index(q) else c.VK_QUEUE_FAMILY_IGNORED,
                .subresourceRange = .{
                    .aspectMask =   if (!image.info.format.is_depth()) c.VK_IMAGE_ASPECT_COLOR_BIT
                                    else c.VK_IMAGE_ASPECT_DEPTH_BIT | c.VK_IMAGE_ASPECT_STENCIL_BIT,
                    .baseMipLevel = b.subresource_range.base_mip_level,
                    .levelCount = 
                        if (b.subresource_range.mip_level_count >= image.info.mip_levels - b.subresource_range.base_mip_level) c.VK_REMAINING_MIP_LEVELS
                        else b.subresource_range.mip_level_count,
                    .baseArrayLayer = b.subresource_range.base_array_layer,
                    .layerCount =
                        if (b.subresource_range.array_layer_count >= image.info.array_length - b.subresource_range.base_array_layer) c.VK_REMAINING_ARRAY_LAYERS
                        else b.subresource_range.array_layer_count,
                },
            };
        }

        c.vkCmdPipelineBarrier(
            self.vk_command_buffer, 
            pipelinestageflags_to_vulkan(info.src_stage), 
            pipelinestageflags_to_vulkan(info.dst_stage), 
            0, 
            @intCast(info.memory_barriers.len), @ptrCast(vk_memory_barriers[0..].ptr),
            @intCast(info.buffer_barriers.len), @ptrCast(vk_buffer_barriers[0..].ptr),
            @intCast(info.image_barriers.len), @ptrCast(vk_image_barriers[0..].ptr),
        );
    }

    pub fn cmd_copy_image_to_buffer(self: *Self, info: gf.CommandBuffer.CopyImageToBufferInfo) void {
        const alloc = eng.get().frame_allocator;

        var vk_copy_regions = std.ArrayList(c.VkBufferImageCopy).initCapacity(alloc, 16)
            catch unreachable;
        defer vk_copy_regions.deinit(alloc);

        for (info.copy_regions) |copy_region| {
            vk_copy_regions.append(alloc, c.VkBufferImageCopy {
                .bufferOffset = copy_region.buffer_offset,
                .bufferRowLength = copy_region.buffer_row_length,
                .bufferImageHeight = copy_region.buffer_image_height,
                .imageSubresource = .{
                    .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, // TODO depth aspect?
                    .baseArrayLayer = copy_region.base_array_layer,
                    .layerCount = copy_region.layer_count,
                    .mipLevel = copy_region.mip_level,
                },
                .imageOffset = .{
                    .x = copy_region.image_offset[0],
                    .y = copy_region.image_offset[1],
                    .z = copy_region.image_offset[2],
                },
                .imageExtent = .{
                    .width = copy_region.image_extent[0],
                    .height = copy_region.image_extent[1],
                    .depth = copy_region.image_extent[2],
                },
            }) catch |err| {
                std.debug.panic("Unable to append copy region: {}", .{err});
            };
        }

        const image = info.image.get() catch return;
        const buffer = info.buffer.get() catch return;

        c.vkCmdCopyImageToBuffer(
            self.vk_command_buffer,
            image.platform.get_frame_image().vk_image, // TODO allow selection of specific internal image. fix? using frame image should be recent enough (and prevent stalls, maybe)
            c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            buffer.platform.get_frame_vk_buffer(),
            @intCast(vk_copy_regions.items.len),
            @ptrCast(vk_copy_regions.items.ptr)
        );
    }

    pub fn cmd_copy_buffer_to_image(self: *Self, info: gf.CommandBuffer.CopyBufferToImageInfo) void {
        const alloc = eng.get().frame_allocator;

        var vk_copy_regions = std.ArrayList(c.VkBufferImageCopy).initCapacity(alloc, 16)
            catch unreachable;
        defer vk_copy_regions.deinit(alloc);

        for (info.copy_regions) |copy_region| {
            vk_copy_regions.append(alloc, c.VkBufferImageCopy {
                .bufferOffset = copy_region.buffer_offset,
                .bufferRowLength = copy_region.buffer_row_length,
                .bufferImageHeight = copy_region.buffer_image_height,
                .imageSubresource = .{
                    .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, // TODO depth aspect?
                    .baseArrayLayer = copy_region.base_array_layer,
                    .layerCount = copy_region.layer_count,
                    .mipLevel = copy_region.mip_level,
                },
                .imageOffset = .{
                    .x = copy_region.image_offset[0],
                    .y = copy_region.image_offset[1],
                    .z = copy_region.image_offset[2],
                },
                .imageExtent = .{
                    .width = copy_region.image_extent[0],
                    .height = copy_region.image_extent[1],
                    .depth = copy_region.image_extent[2],
                },
            }) catch |err| {
                std.debug.panic("Unable to append copy region: {}", .{err});
            };
        }

        const image = info.image.get() catch return;
        const buffer = info.buffer.get() catch return;

        c.vkCmdCopyBufferToImage(
            self.vk_command_buffer,
            buffer.platform.get_frame_vk_buffer(),
            image.platform.get_frame_image().vk_image, // TODO allow selection of specific internal image. fix? using frame image should be recent enough (and prevent stalls, maybe)
            c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            @intCast(vk_copy_regions.items.len),
            @ptrCast(vk_copy_regions.items.ptr)
        );
    }

    pub fn cmd_copy_image_to_image(self: *Self, info: gf.CommandBuffer.CopyImageToImageInfo) void {
        const alloc = eng.get().frame_allocator;

        var vk_copy_regions = std.ArrayList(c.VkImageCopy).initCapacity(alloc, 16) catch unreachable;
        defer vk_copy_regions.deinit(alloc);

        for (info.copy_regions) |copy_region| {
            vk_copy_regions.append(alloc, c.VkImageCopy {
                .srcSubresource = .{
                    .aspectMask = imageaspect_to_vulkan(copy_region.src_subresource.aspect_mask),
                    .baseArrayLayer = copy_region.src_subresource.base_array_layer,
                    .layerCount = copy_region.src_subresource.array_layer_count,
                    .mipLevel = copy_region.src_subresource.mip_level,
                },
                .srcOffset = .{ .x = copy_region.src_offset[0], .y = copy_region.src_offset[1], .z = copy_region.src_offset[2], },
                .dstSubresource = .{
                    .aspectMask = imageaspect_to_vulkan(copy_region.dst_subresource.aspect_mask),
                    .baseArrayLayer = copy_region.dst_subresource.base_array_layer,
                    .layerCount = copy_region.dst_subresource.array_layer_count,
                    .mipLevel = copy_region.dst_subresource.mip_level,
                },
                .dstOffset = .{ .x = copy_region.dst_offset[0], .y = copy_region.dst_offset[1], .z = copy_region.dst_offset[2], },
                .extent = .{ .width = copy_region.extent[0], .height = copy_region.extent[1], .depth = copy_region.extent[2], },
            }) catch |err| {
                std.debug.panic("Unable to append copy region: {}", .{err});
            };
        }

        const src_image = info.src_image.get() catch return;
        const dst_image = info.dst_image.get() catch return;

        c.vkCmdCopyImage(
            self.vk_command_buffer,
            src_image.platform.get_frame_image().vk_image,
            imagelayout_to_vulkan(info.src_image_layout),
            dst_image.platform.get_frame_image().vk_image,
            imagelayout_to_vulkan(info.dst_image_layout),
            @intCast(vk_copy_regions.items.len),
            @ptrCast(vk_copy_regions.items.ptr)
        );
    }

    pub fn cmd_dispatch(self: *Self, info: gf.CommandBuffer.DispatchInfo) void {
        c.vkCmdDispatch(
            self.vk_command_buffer, 
            info.group_count_x, 
            info.group_count_y, 
            info.group_count_z
        );
    }
};

pub const SemaphoreVulkan = struct {
    const Self = @This();

    vk_semaphore: c.VkSemaphore,

    pub inline fn deinit(self: *const Self) void {
        c.vkDestroySemaphore(GfxStateVulkan.get().device, self.vk_semaphore, null);
    }

    pub inline fn init(info: gf.SemaphoreCreateInfo) !Self {
        _ = info;

        const semaphore_info = c.VkSemaphoreCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        };

        var vk_semaphore: c.VkSemaphore = undefined;
        try vkt(c.vkCreateSemaphore(GfxStateVulkan.get().device, &semaphore_info, null, &vk_semaphore));
        errdefer c.vkDestroySemaphore(GfxStateVulkan.get().device, vk_semaphore, null);

        return Self {
            .vk_semaphore = vk_semaphore,
        };
    }
};

pub const FenceVulkan = struct {
    const Self = @This();

    vk_fence: c.VkFence,

    pub inline fn deinit(self: *const Self) void {
        c.vkDestroyFence(GfxStateVulkan.get().device, self.vk_fence, null);
    }

    pub inline fn init(info: gf.FenceCreateInfo) !Self {
        const fence_info = c.VkFenceCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .flags = if (info.create_signalled) c.VK_FENCE_CREATE_SIGNALED_BIT else 0,
        };

        var vk_fence: c.VkFence = undefined;
        try vkt(c.vkCreateFence(GfxStateVulkan.get().device, &fence_info, null, &vk_fence));
        errdefer c.vkDestroyFence(GfxStateVulkan.get().device, vk_fence, null);

        return Self {
            .vk_fence = vk_fence,
        };
    }

    pub inline fn wait(self: *Self) !void {
        vkt(c.vkWaitForFences(
                GfxStateVulkan.get().device,
                1,
                @ptrCast(&self.vk_fence),
                bool_to_vulkan(true),
                std.math.maxInt(u64)
        )) catch |err| {
            std.log.warn("Failed waiting for fence: {}", .{err});
        };
    }

    pub inline fn wait_all(fences: []const *Self) !void {
        const MAX_FENCES = 16;
        std.debug.assert(fences.len < MAX_FENCES);

        var vk_fences: [MAX_FENCES]c.VkFence = undefined;
        for (fences, 0..) |f, idx| {
            vk_fences[idx] = f.vk_fence;
        }

        try vkt(c.vkWaitForFences(
                GfxStateVulkan.get().device,
                @intCast(fences.len),
                @ptrCast(vk_fences[0..].ptr),
                bool_to_vulkan(true),
                std.math.maxInt(u64)
        ));
    }
    
    pub inline fn wait_any(fences: []const *Self) !void {
        const MAX_FENCES = 16;
        std.debug.assert(fences.len < MAX_FENCES);

        var vk_fences: [MAX_FENCES]c.VkFence = undefined;
        for (fences, 0..) |f, idx| {
            vk_fences[idx] = f.vk_fence;
        }

        try vkt(c.vkWaitForFences(
                GfxStateVulkan.get().device,
                @intCast(fences.len),
                @ptrCast(vk_fences[0..].ptr),
                bool_to_vulkan(false),
                std.math.maxInt(u64)
        ));
    }

    pub inline fn reset(self: *Self) !void {
        try vkt(c.vkResetFences(GfxStateVulkan.get().device, 1, self.vk_fence));
    }
};
