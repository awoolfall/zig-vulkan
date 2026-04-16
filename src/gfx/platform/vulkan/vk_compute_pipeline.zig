const std = @import("std");
const eng = @import("self");
const gf = eng.gfx;
const c = @import("vk_import.zig").c;
const vkt = @import("vk_error.zig").vulkan_result_to_zig_error;
const vk = @import("vulkan.zig");
const GfxStateVulkan = vk.GfxStateVulkan;

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
                .stageFlags = vk.shaderstageflags_to_vulkan(p.shader_stages),
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