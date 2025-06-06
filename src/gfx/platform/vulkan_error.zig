const c = @import("vulkan_import.zig").c;
const std = @import("std");

pub inline fn vulkan_result_to_zig_error(result: c.VkResult) !void {
    switch (result) {
        c.VK_SUCCESS => {},
        c.VK_INCOMPLETE => return error.VK_INCOMPLETE,
        c.VK_NOT_READY => return error.VK_NOT_READY,
        c.VK_TIMEOUT => return error.VK_TIMEOUT,
        c.VK_EVENT_SET => return error.VK_EVENT_SET,
        c.VK_EVENT_RESET => return error.VK_EVENT_RESET,
        c.VK_ERROR_OUT_OF_HOST_MEMORY => return error.VK_ERROR_OUT_OF_HOST_MEMORY,
        c.VK_ERROR_OUT_OF_DEVICE_MEMORY => return error.VK_ERROR_OUT_OF_DEVICE_MEMORY,
        c.VK_ERROR_INITIALIZATION_FAILED => return error.VK_ERROR_INITIALIZATION_FAILED,
        c.VK_ERROR_DEVICE_LOST => return error.VK_ERROR_DEVICE_LOST,
        c.VK_ERROR_MEMORY_MAP_FAILED => return error.VK_ERROR_MEMORY_MAP_FAILED,
        c.VK_ERROR_LAYER_NOT_PRESENT => return error.VK_ERROR_LAYER_NOT_PRESENT,
        c.VK_ERROR_EXTENSION_NOT_PRESENT => return error.VK_ERROR_EXTENSION_NOT_PRESENT,
        c.VK_ERROR_FEATURE_NOT_PRESENT => return error.VK_ERROR_FEATURE_NOT_PRESENT,
        c.VK_ERROR_INCOMPATIBLE_DRIVER => return error.VK_ERROR_INCOMPATIBLE_DRIVER,
        c.VK_ERROR_TOO_MANY_OBJECTS => return error.VK_ERROR_TOO_MANY_OBJECTS,
        c.VK_ERROR_FORMAT_NOT_SUPPORTED => return error.VK_ERROR_FORMAT_NOT_SUPPORTED,
        c.VK_ERROR_FRAGMENTED_POOL => return error.VK_ERROR_FRAGMENTED_POOL,
        c.VK_ERROR_UNKNOWN => return error.VK_ERROR_UNKNOWN,
        // Provided by VK_VERSION_1_1
        c.VK_ERROR_OUT_OF_POOL_MEMORY => return error.VK_ERROR_OUT_OF_POOL_MEMORY,
        // Provided by VK_VERSION_1_1
        c.VK_ERROR_INVALID_EXTERNAL_HANDLE => return error.VK_ERROR_INVALID_EXTERNAL_HANDLE,
        // Provided by VK_VERSION_1_2
        c.VK_ERROR_FRAGMENTATION => return error.VK_ERROR_FRAGMENTATION,
        // Provided by VK_VERSION_1_2
        c.VK_ERROR_INVALID_OPAQUE_CAPTURE_ADDRESS => return error.VK_ERROR_INVALID_OPAQUE_CAPTURE_ADDRESS,
        // Provided by VK_VERSION_1_3
        c.VK_PIPELINE_COMPILE_REQUIRED => return error.VK_PIPELINE_COMPILE_REQUIRED,
        // Provided by VK_VERSION_1_4
        c.VK_ERROR_NOT_PERMITTED => return error.VK_ERROR_NOT_PERMITTED,
        // Provided by VK_KHR_surface
        c.VK_ERROR_SURFACE_LOST_KHR => return error.VK_ERROR_SURFACE_LOST_KHR,
        // Provided by VK_KHR_surface
        c.VK_ERROR_NATIVE_WINDOW_IN_USE_KHR => return error.VK_ERROR_NATIVE_WINDOW_IN_USE_KHR,
        // Provided by VK_KHR_swapchain
        c.VK_SUBOPTIMAL_KHR => return error.VK_SUBOPTIMAL_KHR,
        // Provided by VK_KHR_swapchain
        c.VK_ERROR_OUT_OF_DATE_KHR => return error.VK_ERROR_OUT_OF_DATE_KHR,
        // Provided by VK_KHR_display_swapchain
        c.VK_ERROR_INCOMPATIBLE_DISPLAY_KHR => return error.VK_ERROR_INCOMPATIBLE_DISPLAY_KHR,
        // Provided by VK_EXT_debug_report
        c.VK_ERROR_VALIDATION_FAILED_EXT => return error.VK_ERROR_VALIDATION_FAILED_EXT,
        // Provided by VK_NV_glsl_shader
        c.VK_ERROR_INVALID_SHADER_NV => return error.VK_ERROR_INVALID_SHADER_NV,
        // Provided by VK_KHR_video_queue
        c.VK_ERROR_IMAGE_USAGE_NOT_SUPPORTED_KHR => return error.VK_ERROR_IMAGE_USAGE_NOT_SUPPORTED_KHR,
        // Provided by VK_KHR_video_queue
        c.VK_ERROR_VIDEO_PICTURE_LAYOUT_NOT_SUPPORTED_KHR => return error.VK_ERROR_VIDEO_PICTURE_LAYOUT_NOT_SUPPORTED_KHR,
        // Provided by VK_KHR_video_queue
        c.VK_ERROR_VIDEO_PROFILE_OPERATION_NOT_SUPPORTED_KHR => return error.VK_ERROR_VIDEO_PROFILE_OPERATION_NOT_SUPPORTED_KHR,
        // Provided by VK_KHR_video_queue
        c.VK_ERROR_VIDEO_PROFILE_FORMAT_NOT_SUPPORTED_KHR => return error.VK_ERROR_VIDEO_PROFILE_FORMAT_NOT_SUPPORTED_KHR,
        // Provided by VK_KHR_video_queue
        c.VK_ERROR_VIDEO_PROFILE_CODEC_NOT_SUPPORTED_KHR => return error.VK_ERROR_VIDEO_PROFILE_CODEC_NOT_SUPPORTED_KHR,
        // Provided by VK_KHR_video_queue
        c.VK_ERROR_VIDEO_STD_VERSION_NOT_SUPPORTED_KHR => return error.VK_ERROR_VIDEO_STD_VERSION_NOT_SUPPORTED_KHR,
        // Provided by VK_EXT_image_drm_format_modifier
        c.VK_ERROR_INVALID_DRM_FORMAT_MODIFIER_PLANE_LAYOUT_EXT => return error.VK_ERROR_INVALID_DRM_FORMAT_MODIFIER_PLANE_LAYOUT_EXT,
        // Provided by VK_EXT_full_screen_exclusive
        c.VK_ERROR_FULL_SCREEN_EXCLUSIVE_MODE_LOST_EXT => return error.VK_ERROR_FULL_SCREEN_EXCLUSIVE_MODE_LOST_EXT,
        // Provided by VK_KHR_deferred_host_operations
        c.VK_THREAD_IDLE_KHR => return error.VK_THREAD_IDLE_KHR,
        // Provided by VK_KHR_deferred_host_operations
        c.VK_THREAD_DONE_KHR => return error.VK_THREAD_DONE_KHR,
        // Provided by VK_KHR_deferred_host_operations
        c.VK_OPERATION_DEFERRED_KHR => return error.VK_OPERATION_DEFERRED_KHR,
        // Provided by VK_KHR_deferred_host_operations
        c.VK_OPERATION_NOT_DEFERRED_KHR => return error.VK_OPERATION_NOT_DEFERRED_KHR,
        // Provided by VK_KHR_video_encode_queue
        c.VK_ERROR_INVALID_VIDEO_STD_PARAMETERS_KHR => return error.VK_ERROR_INVALID_VIDEO_STD_PARAMETERS_KHR,
        // Provided by VK_EXT_image_compression_control
        c.VK_ERROR_COMPRESSION_EXHAUSTED_EXT => return error.VK_ERROR_COMPRESSION_EXHAUSTED_EXT,
        // Provided by VK_EXT_shader_object
        c.VK_INCOMPATIBLE_SHADER_BINARY_EXT => return error.VK_INCOMPATIBLE_SHADER_BINARY_EXT,
        // Provided by VK_KHR_pipeline_binary
        c.VK_PIPELINE_BINARY_MISSING_KHR => return error.VK_PIPELINE_BINARY_MISSING_KHR,
        // Provided by VK_KHR_pipeline_binary
        c.VK_ERROR_NOT_ENOUGH_SPACE_KHR => return error.VK_ERROR_NOT_ENOUGH_SPACE_KHR,
        // Provided by VK_KHR_maintenance1
        //(commented due to duplicate underlying value)
        //c.VK_ERROR_OUT_OF_POOL_MEMORY_KHR => return error.VK_ERROR_OUT_OF_POOL_MEMORY_KHR,
        // Provided by VK_KHR_external_memory
        //(commented due to duplicate underlying value)
        //c.VK_ERROR_INVALID_EXTERNAL_HANDLE_KHR => return error.VK_ERROR_INVALID_EXTERNAL_HANDLE_KHR,
        // Provided by VK_EXT_descriptor_indexing
        //(commented due to duplicate underlying value)
        //c.VK_ERROR_FRAGMENTATION_EXT => return error.VK_ERROR_FRAGMENTATION_EXT,
        // Provided by VK_EXT_global_priority
        //(commented due to duplicate underlying value)
        //c.VK_ERROR_NOT_PERMITTED_EXT => return error.VK_ERROR_NOT_PERMITTED_EXT,
        // Provided by VK_KHR_global_priority
        //(commented due to duplicate underlying value)
        //c.VK_ERROR_NOT_PERMITTED_KHR => return error.VK_ERROR_NOT_PERMITTED_KHR,
        // Provided by VK_EXT_buffer_device_address
        //(commented due to duplicate underlying value)
        //c.VK_ERROR_INVALID_DEVICE_ADDRESS_EXT => return error.VK_ERROR_INVALID_DEVICE_ADDRESS_EXT,
        // Provided by VK_KHR_buffer_device_address
        //(commented due to duplicate underlying value)
        //c.VK_ERROR_INVALID_OPAQUE_CAPTURE_ADDRESS_KHR => return error.VK_ERROR_INVALID_OPAQUE_CAPTURE_ADDRESS_KHR,
        // Provided by VK_EXT_pipeline_creation_cache_control
        //(commented due to duplicate underlying value)
        //c.VK_PIPELINE_COMPILE_REQUIRED_EXT => return error.VK_PIPELINE_COMPILE_REQUIRED_EXT,
        // Provided by VK_EXT_pipeline_creation_cache_control
        //(commented due to duplicate underlying value)
        //c.VK_ERROR_PIPELINE_COMPILE_REQUIRED_EXT => return error.VK_ERROR_PIPELINE_COMPILE_REQUIRED_EXT,
        // Provided by VK_EXT_shader_object
        // VK_ERROR_INCOMPATIBLE_SHADER_BINARY_EXT is a deprecated alias
        //(commented due to duplicate underlying value)
        //c.VK_ERROR_INCOMPATIBLE_SHADER_BINARY_EXT => return error.VK_ERROR_INCOMPATIBLE_SHADER_BINARY_EXT,
        else => {
            std.log.err("Vulkan Error: {}", .{result});
            return error.VkError;
        },
    }
}
