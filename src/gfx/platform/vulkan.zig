const std = @import("std");
const eng = @import("self");
const zm = eng.zmath;
const gf = eng.gfx;
const pl = eng.platform;
const Rect = eng.Rect;
const c = @import("vulkan/vk_import.zig").c;
const vkt = @import("vulkan/vk_error.zig").vulkan_result_to_zig_error;
const SwapchainVulkan = @import("vulkan/vk_swapchain.zig").SwapchainVulkan;

pub const GfxStateVulkan = struct {
    const Self = @This();
    const ENABLE_VALIDATION_LAYERS: bool = true;
    const FORCE_INTEGRATED_GPU: bool = false;

    pub const ShaderModule = @import("vulkan/vk_shader_module.zig").ShaderModuleVulkan;
    pub const VertexInput = @import("vulkan/vk_vertex_input.zig").VertexInputVulkan;
    
    pub const Buffer = @import("vulkan/vk_buffer.zig").BufferVulkan;
    pub const Image = @import("vulkan/vk_image.zig").ImageVulkan;
    pub const ImageView = @import("vulkan/vk_image_view.zig").ImageViewVulkan;
    pub const Sampler = @import("vulkan/vk_sampler.zig").SamplerVulkan;

    pub const RenderPass = @import("vulkan/vk_render_pass.zig").RenderPassVulkan;
    pub const GraphicsPipeline = @import("vulkan/vk_graphics_pipeline.zig").GraphicsPipelineVulkan;
    pub const ComputePipeline = @import("vulkan/vk_compute_pipeline.zig").ComputePipelineVulkan;
    pub const FrameBuffer = @import("vulkan/vk_frame_buffer.zig").FrameBufferVulkan;

    pub const DescriptorLayout = @import("vulkan/vk_descriptor_layout.zig").DescriptorLayoutVulkan;
    pub const DescriptorPool = @import("vulkan/vk_descriptor_pool.zig").DescriptorPoolVulkan;
    pub const DescriptorSet = @import("vulkan/vk_descriptor_set.zig").DescriptorSetVulkan;

    pub const CommandPool = @import("vulkan/vk_command_pool.zig").CommandPoolVulkan;
    pub const CommandBuffer = @import("vulkan/vk_command_buffer.zig").CommandBufferVulkan;

    pub const Semaphore = @import("vulkan/vk_synchronisation.zig").SemaphoreVulkan;
    pub const Fence = @import("vulkan/vk_synchronisation.zig").FenceVulkan;

    const VkQueues = struct {
        all: c.VkQueue,
        all_family_index: u32,
        present: c.VkQueue,
        present_family_index: u32,
        cpu_gpu_transfer: c.VkQueue,
        cpu_gpu_transfer_family_index: u32,

        pub fn has_distinct_transfer_queue(self: *const VkQueues) bool {
            return (self.all_family_index != self.cpu_gpu_transfer_family_index);
        }
    };
    
    pub const BufferUpdates = struct {
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

        const transfer_command_pool = gf.CommandPool { .platform = CommandPool { .vk_pool = vk_transfer_command_pool, } };
        errdefer transfer_command_pool.deinit();
        errdefer vkt(c.vkDeviceWaitIdle(vk_device)) catch unreachable;

        const all_command_pool_create_info = c.VkCommandPoolCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .queueFamilyIndex = queues.all_family_index,
        };

        var vk_all_command_pool: c.VkCommandPool = undefined;
        try vkt(c.vkCreateCommandPool(vk_device, &all_command_pool_create_info, null, &vk_all_command_pool));

        const all_command_pool = gf.CommandPool { .platform = CommandPool { .vk_pool = vk_all_command_pool, } };
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

    pub fn get() *Self {
        return &eng.get().gfx.platform;
    }

    pub fn props(self: *const Self) gf.PlatformProperties {
        return self.properties;
    }

    pub fn swapchain_size(self: *const Self) [2]u32 {
        return .{ self.swapchain.extent.width, self.swapchain.extent.height };
    }

    pub fn frames_in_flight(self: *const Self) u32 {
        return self.num_frames_in_flight;
    }

    pub fn current_frame_index(self: *const Self) u32 {
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

    pub fn get_queue_family_index(self: *const Self, queue_family: gf.QueueFamily) u32 {
        return switch (queue_family) {
            .Graphics, .Compute => self.queues.all_family_index,
            .Transfer => self.queues.cpu_gpu_transfer_family_index,
        };
    }
};

pub fn pipelinestageflags_to_vulkan(p: gf.PipelineStageFlags) c.VkPipelineStageFlagBits {
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

pub fn accessflags_to_vulkan(p: gf.AccessMaskFlags) c.VkAccessFlagBits {
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

pub fn imagelayout_to_vulkan(p: gf.ImageLayout) c.VkImageLayout {
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

pub fn rect_to_vulkan(rect: Rect) c.VkRect2D {
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

pub fn indexformat_to_vulkan(indexformat: gf.IndexFormat) c.VkIndexType {
    return switch (indexformat) {
        .U16 => c.VK_INDEX_TYPE_UINT16,
        .U32 => c.VK_INDEX_TYPE_UINT32,
    };
}

pub fn convert_buffer_usage_flags_to_vulkan(usage: gf.BufferUsageFlags) c.VkBufferUsageFlags {
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

pub fn convert_texture_usage_flags_to_vulkan(usage: gf.ImageUsageFlags) c.VkImageUsageFlags {
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

pub fn find_vulkan_memory_type(type_filter: u32, property_flags: c.VkMemoryPropertyFlags) !u32 {
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

pub fn begin_single_time_command_buffer(command_pool: *gf.CommandPool) !gf.CommandBuffer {
    var cmd = try command_pool.allocate_command_buffer(.{ .level = .Primary });
    errdefer cmd.deinit();

    try cmd.cmd_begin(.{ .one_time_submit = true, });
    errdefer cmd.cmd_end() catch {};

    return cmd;
}

pub fn end_single_time_command_buffer(cmd: *gf.CommandBuffer, signal_semaphore: ?gf.Semaphore) void {
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

pub fn align_up(value: anytype, alignment: anytype) @TypeOf(value) {
    return @divFloor(value + alignment - 1, alignment) * alignment;
}

pub fn lcm(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    return (a * b) / std.math.gcd(a, b);
}

pub fn imageaspect_to_vulkan(aspect: gf.ImageAspect) c.VkImageAspectFlags {
    var vk_aspect: c.VkImageAspectFlags = 0;
    if (aspect.colour) { vk_aspect |= c.VK_IMAGE_ASPECT_COLOR_BIT; }
    if (aspect.depth) { vk_aspect |= c.VK_IMAGE_ASPECT_DEPTH_BIT; }
    if (aspect.stencil) { vk_aspect |= c.VK_IMAGE_ASPECT_STENCIL_BIT; }
    return vk_aspect;
}

pub fn samplerfilter_to_vulkan(filter: gf.SamplerFilter) c.VkFilter {
    return switch (filter) {
        .Linear => c.VK_FILTER_LINEAR,
        .Point => c.VK_FILTER_NEAREST,
    };
}

pub fn samplermipmapmode_to_vulkan(mipmapmode: gf.SamplerFilter) c.VkSamplerMipmapMode {
    return switch (mipmapmode) {
        .Linear => c.VK_SAMPLER_MIPMAP_MODE_LINEAR,
        .Point => c.VK_SAMPLER_MIPMAP_MODE_NEAREST,
    };
}

pub fn samplerbordermode_to_vulkan(bordermode: gf.SamplerBorderMode) c.VkSamplerAddressMode {
    return switch (bordermode) {
        .BorderColour => c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER,
        .Clamp => c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .Mirror => c.VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT,
        .Wrap => c.VK_SAMPLER_ADDRESS_MODE_REPEAT,
    };
}

pub fn formatclearvalue_to_vulkan(format: gf.ImageFormat, clear_value: gf.ClearValue) c.VkClearValue {
    if (format.is_depth()) {
        return c.VkClearValue {
            .depthStencil = .{
                .depth = clear_value.depth_stencil.depth,
                .stencil = clear_value.depth_stencil.stencil,
            }
        };
    } else {
        return switch (format) {
            .Rgba8_Unorm_Srgb,
            .Rgba8_Unorm,
            .Bgra8_Unorm,
            .Bgra8_Srgb,
            .R24X8_Unorm_Uint,
            .D24S8_Unorm_Uint,
            .D16S8_Unorm_Uint,
            .R32_Uint => c.VkClearValue {
                .color = .{ .uint32 = clear_value.u32x4, }
            },
            .Unknown,
            .R32_Float,
            .Rg32_Float,
            .Rgb32_Float,
            .Rgba16_Float,
            .Rgba32_Float,
            .D32S8_Sfloat_Uint,
            .Rg11b10_Float =>  c.VkClearValue {
                .color = .{ .float32 = zm.vecToArr4(clear_value.f32x4), }
            },
        };
    }
}

pub fn textureformat_to_vulkan(format: gf.ImageFormat) c.VkFormat {
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

pub fn topology_to_vulkan(topology: gf.Topology) c.VkPrimitiveTopology {
    return switch (topology) {
        .LineList => c.VK_PRIMITIVE_TOPOLOGY_LINE_LIST,
        .LineStrip => c.VK_PRIMITIVE_TOPOLOGY_LINE_STRIP,
        .PointList => c.VK_PRIMITIVE_TOPOLOGY_POINT_LIST,
        .TriangleList => c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        .TriangleStrip => c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP,
    };
}

pub fn cullmode_to_vulkan(cullmode: gf.CullMode) c.VkCullModeFlags {
    return switch (cullmode) {
        .CullBack => c.VK_CULL_MODE_BACK_BIT,
        .CullFront => c.VK_CULL_MODE_FRONT_BIT,
        .CullFrontAndBack => c.VK_CULL_MODE_FRONT_AND_BACK,
        .CullNone => c.VK_CULL_MODE_NONE,
    };
}

pub fn frontface_to_vulkan(frontface: gf.FrontFace) c.VkFrontFace {
    return switch (frontface) {
        .Clockwise => c.VK_FRONT_FACE_CLOCKWISE,
        .CounterClockwise => c.VK_FRONT_FACE_COUNTER_CLOCKWISE,
    };
}

pub fn fillmode_to_vulkan(fillmode: gf.FillMode) c.VkPolygonMode {
    return switch (fillmode) {
        .Fill => c.VK_POLYGON_MODE_FILL,
        .Line => c.VK_POLYGON_MODE_LINE,
        .Point => c.VK_POLYGON_MODE_POINT,
    };
}

pub fn bool_to_vulkan(b: bool) c_uint {
    return if (b) c.VK_TRUE else c.VK_FALSE;
}

pub fn compareop_to_vulkan(compareop: gf.CompareOp) c.VkCompareOp {
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

pub fn blendtype_to_vulkan(blendtype: gf.BlendType) c.VkPipelineColorBlendAttachmentState {
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

pub fn loadop_to_vulkan(loadop: gf.AttachmentLoadOp) c.VkAttachmentLoadOp {
    return switch (loadop) {
        .Clear => c.VK_ATTACHMENT_LOAD_OP_CLEAR,
        .DontCare => c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .Load => c.VK_ATTACHMENT_LOAD_OP_LOAD,
    };
}

pub fn storeop_to_vulkan(storeop: gf.AttachmentStoreOp) c.VkAttachmentStoreOp {
    return switch (storeop) {
        .DontCare => c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .Store => c.VK_ATTACHMENT_STORE_OP_STORE,
    };
}

pub const FrameBufferAttachmentExtent = struct {
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

pub fn framebufferattachment_extent(framebuffer_attachment: gf.FrameBufferAttachmentInfo) FrameBufferAttachmentExtent {
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

pub fn bindingtype_to_vulkan(bindingtype: gf.BindingType) c.VkDescriptorType {
    return switch (bindingtype) {
        .ImageView => c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
        .ImageViewAndSampler => c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .Sampler => c.VK_DESCRIPTOR_TYPE_SAMPLER,
        .UniformBuffer => c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        .StorageBuffer => c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        .StorageImage => c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,
    };
}

pub fn shaderstageflags_to_vulkan(shaderstageflags: gf.ShaderStageFlags) c.VkShaderStageFlags {
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

pub fn poolflags_to_vulkan(info: gf.CommandPoolInfo) c.VkCommandPoolCreateFlags {
    var flags: c.VkCommandPoolCreateFlags = 0;
    if (info.transient_buffers) {
        flags |= c.VK_COMMAND_POOL_CREATE_TRANSIENT_BIT;
    }
    if (info.allow_reset_command_buffers) {
        flags |= c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    }
    return flags;
}

pub fn commandbufferlevel_to_vulkan(level: gf.CommandBufferLevel) c.VkCommandBufferLevel {
    return switch (level) {
        .Primary => c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .Secondary => c.VK_COMMAND_BUFFER_LEVEL_SECONDARY,
    };
}

pub fn commandbufferbeginflags_to_vulkan(f: gf.CommandBuffer.BeginInfo) c.VkCommandBufferUsageFlags {
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
