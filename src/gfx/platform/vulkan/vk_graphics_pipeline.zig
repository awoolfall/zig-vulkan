const std = @import("std");
const eng = @import("self");
const gf = eng.gfx;
const c = @import("vk_import.zig").c;
const vkt = @import("vk_error.zig").vulkan_result_to_zig_error;
const vk = @import("../vulkan.zig");
const GfxStateVulkan = vk.GfxStateVulkan;

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
            .topology = vk.topology_to_vulkan(info.topology),
        };

        const viewport_info = c.VkPipelineViewportStateCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            .viewportCount = 1, // @TODO: attachment count?
            .scissorCount = 1,
        };

        const rasterizer_info = c.VkPipelineRasterizationStateCreateInfo {
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            .rasterizerDiscardEnable = c.VK_FALSE,
            .cullMode = vk.cullmode_to_vulkan(info.cull_mode),
            .depthBiasEnable = vk.bool_to_vulkan(info.depth_bias != null),
            .depthBiasClamp = if (info.depth_bias) |b| b.clamp else 0.0,
            .depthBiasConstantFactor = if (info.depth_bias) |b| b.constant_factor else 0.0,
            .depthBiasSlopeFactor = if (info.depth_bias) |b| b.slope_factor else 0.0,
            .depthClampEnable = vk.bool_to_vulkan(info.depth_clamp),
            .frontFace = vk.frontface_to_vulkan(info.front_face),
            .lineWidth = info.rasterization_line_width,
            .polygonMode = vk.fillmode_to_vulkan(info.rasterization_fill_mode),
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
            .depthTestEnable = vk.bool_to_vulkan(info.depth_test != null),
            .depthCompareOp = if (info.depth_test) |d| vk.compareop_to_vulkan(d.compare_op) else c.VK_COMPARE_OP_ALWAYS,
            .depthWriteEnable = if (info.depth_test) |d| vk.bool_to_vulkan(d.write) else c.VK_FALSE,
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
                color_blend_attachments[color_blend_attachments_len] = vk.blendtype_to_vulkan(attachment.blend_type); 
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