const std = @import("std");
const eng = @import("self");
const gf = eng.gfx;
const c = @import("vk_import.zig").c;
const vkt = @import("vk_error.zig").vulkan_result_to_zig_error;
const vk = @import("../vulkan.zig");
const GfxStateVulkan = vk.GfxStateVulkan;

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