//! Vulkan rasterizer for frames recorded by Renderer into a GpuDrawList.
//!
//! The backend keeps a persistent canvas image that always holds the latest
//! frame, like the CPU renderer's newest buffer. A frame draws only what the
//! shared Renderer recorded: damaged rows and cells, overlays and kitty
//! placements, each op already clipped. Scrolls copy retained rows into a
//! second canvas image (images cannot copy onto themselves), so the two
//! canvases alternate.
//!
//! Each canvas has a background companion image ("bgmap") holding only the
//! ops below the text layer. Text reads its background from there for
//! coverage correction, matching the CPU renderer, which reads the pixel it
//! blends over. Presentation copies damaged canvas regions into swapchain
//! images; see VulkanPresenter.
//!
//! Threading: `init` may run on any thread. Afterwards the raster worker owns
//! `beginFrame`/`submitFrame`/`cancelFrame`, and the main thread owns the
//! presenter. Queue access and the timeline counter are guarded by
//! `queue_mutex`; the app never presents while a frame is being recorded.

const VulkanRenderer = @This();

const std = @import("std");
const vk = @import("vk");
const Dispatch = @import("VulkanDispatch.zig");
const GpuDrawList = @import("GpuDrawList.zig");
const pixel_raster = @import("pixel_raster.zig");

const log = std.log.scoped(.vulkan);
const check = Dispatch.check;

pub const canvas_format = vk.VK_FORMAT_B8G8R8A8_SRGB;
const canvas_unorm_format = vk.VK_FORMAT_B8G8R8A8_UNORM;
const slot_count = 2;
/// Frames whose GPU timestamps stay readable: telemetry reads a frame's
/// queries when the compositor reports it presented, a few frames later.
const timed_frames = 16;
const vert_spv align(4) = @embedFile("shaders/canvas.vert.spv").*;
const frag_spv align(4) = @embedFile("shaders/canvas.frag.spv").*;

pub const Options = struct {
    /// Wayland objects for the presentation surface (`wl_display*`,
    /// `wl_surface*`), or null for offscreen use.
    wl_display: ?*anyopaque = null,
    wl_surface: ?*anyopaque = null,
    validation: bool = false,
};

pub const Image = struct {
    image: vk.VkImage = null,
    memory: vk.VkDeviceMemory = null,
    view: vk.VkImageView = null,
    /// UNORM view of an sRGB image, for reading stored bytes.
    raw_view: vk.VkImageView = null,
    width: u32 = 0,
    height: u32 = 0,
    /// Moved from UNDEFINED to GENERAL by a submitted command buffer.
    ready: bool = false,
};

const Buffer = struct {
    buffer: vk.VkBuffer = null,
    memory: vk.VkDeviceMemory = null,
    mapped: [*]u8 = undefined,
    size: usize = 0,
};

const Garbage = struct {
    /// Destroy once the timeline reaches this value.
    after: u64,
    object: union(enum) { image: Image, buffer: Buffer },
};

const Slot = struct {
    cmd: vk.VkCommandBuffer = null,
    set: vk.VkDescriptorSet = null,
    ops: Buffer = .{},
    staging: Buffer = .{},
    done_value: u64 = 0,
    /// Frame whose render timestamps this slot wrote and has not read; 0 if
    /// none.
    timed_seq: u64 = 0,
};

pub const Stats = struct {
    frames: u64 = 0,
    gpu_ns: u64 = 0,
    gpu_max_ns: u64 = 0,
    ops: u64 = 0,
};

alloc: std.mem.Allocator,
d: Dispatch,
instance: vk.VkInstance = null,
physical: vk.VkPhysicalDevice = null,
device: vk.VkDevice = null,
queue: vk.VkQueue = null,
queue_family: u32 = 0,
memory_properties: vk.VkPhysicalDeviceMemoryProperties = undefined,
timestamp_period: f64 = 1,
timestamps_supported: bool = false,
incremental_present: bool = false,
drm_modifiers: bool = false,
surface: vk.VkSurfaceKHR = null,
wl_display: ?*anyopaque = null,

queue_mutex: std.atomic.Mutex = .unlocked,
timeline: vk.VkSemaphore = null,
/// Last value a submission signals; guarded by queue_mutex.
timeline_value: u64 = 0,
garbage: std.ArrayList(Garbage) = .empty,

cmd_pool: vk.VkCommandPool = null,
set_layout: vk.VkDescriptorSetLayout = null,
pipeline_layout: vk.VkPipelineLayout = null,
pipeline: vk.VkPipeline = null,
sampler: vk.VkSampler = null,
descriptor_pool: vk.VkDescriptorPool = null,
query_pool: vk.VkQueryPool = null,
tables: Buffer = .{},
dummy: Image = .{},
alpha_atlas: Image = .{},
color_atlas: Image = .{},
images: [GpuDrawList.max_images]Image = @splat(.{}),
canvases: [2]Image = @splat(.{}),
bgmaps: [2]Image = @splat(.{}),
current: u1 = 0,
canvas_valid: bool = false,
font_id: u64 = 0,
slots: [slot_count]Slot = @splat(.{}),
slot_index: usize = 0,
list: GpuDrawList,
/// Timeline value of the latest submitted frame; presentation waits on it.
last_frame_value: u64 = 0,
/// Number of the latest submitted frame, counting from 1.
frame_seq: u64 = 0,
stats: Stats = .{},

/// Load Vulkan and build every size-independent resource. This takes tens of
/// milliseconds (driver load, shader compile), so callers run it off the
/// main thread.
pub fn create(alloc: std.mem.Allocator, options: Options) !*VulkanRenderer {
    const self = try alloc.create(VulkanRenderer);
    errdefer alloc.destroy(self);
    self.* = .{ .alloc = alloc, .d = try Dispatch.open(), .list = .init(alloc), .wl_display = options.wl_display };
    errdefer self.destroy();
    try self.createInstance(options.validation);
    if (options.wl_surface) |wl_surface| {
        const info: vk.VkWaylandSurfaceCreateInfoKHR = .{
            .sType = vk.VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR,
            .display = @ptrCast(options.wl_display),
            .surface = @ptrCast(wl_surface),
        };
        try check(self.d.vkCreateWaylandSurfaceKHR(self.instance, &info, null, &self.surface));
    }
    try self.createDevice();
    try self.createPipeline();
    try self.createStaticResources();
    return self;
}

/// Wait for the GPU and release everything. Safe on a partially created
/// renderer.
pub fn destroy(self: *VulkanRenderer) void {
    const d = &self.d;
    if (self.device != null) {
        _ = d.vkDeviceWaitIdle(self.device);
        for (self.garbage.items) |item| self.destroyObject(item.object);
        for (&self.slots) |*slot| {
            self.destroyBuffer(slot.ops);
            self.destroyBuffer(slot.staging);
        }
        for (self.images) |image| self.destroyImage(image);
        for (self.canvases ++ self.bgmaps) |image| self.destroyImage(image);
        self.destroyImage(self.alpha_atlas);
        self.destroyImage(self.color_atlas);
        self.destroyImage(self.dummy);
        self.destroyBuffer(self.tables);
        if (self.query_pool != null) d.vkDestroyQueryPool(self.device, self.query_pool, null);
        if (self.descriptor_pool != null) d.vkDestroyDescriptorPool(self.device, self.descriptor_pool, null);
        if (self.sampler != null) d.vkDestroySampler(self.device, self.sampler, null);
        if (self.pipeline != null) d.vkDestroyPipeline(self.device, self.pipeline, null);
        if (self.pipeline_layout != null) d.vkDestroyPipelineLayout(self.device, self.pipeline_layout, null);
        if (self.set_layout != null) d.vkDestroyDescriptorSetLayout(self.device, self.set_layout, null);
        if (self.cmd_pool != null) d.vkDestroyCommandPool(self.device, self.cmd_pool, null);
        if (self.timeline != null) d.vkDestroySemaphore(self.device, self.timeline, null);
        d.vkDestroyDevice(self.device, null);
    }
    if (self.surface != null) d.vkDestroySurfaceKHR(self.instance, self.surface, null);
    if (self.instance != null) d.vkDestroyInstance(self.instance, null);
    self.garbage.deinit(self.alloc);
    self.list.deinit();
    d.close();
    const alloc = self.alloc;
    alloc.destroy(self);
}

fn createInstance(self: *VulkanRenderer, validation: bool) !void {
    const app: vk.VkApplicationInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "monstar",
        .pEngineName = "monstar",
        .apiVersion = vk.VK_API_VERSION_1_3,
    };
    const extensions = [_][*:0]const u8{ "VK_KHR_surface", "VK_KHR_wayland_surface" };
    const layers = [_][*:0]const u8{"VK_LAYER_KHRONOS_validation"};
    const info: vk.VkInstanceCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &app,
        .enabledExtensionCount = extensions.len,
        .ppEnabledExtensionNames = @ptrCast(&extensions),
        .enabledLayerCount = if (validation) layers.len else 0,
        .ppEnabledLayerNames = @ptrCast(&layers),
    };
    try check(self.d.vkCreateInstance(&info, null, &self.instance));
    try self.d.loadInstance(self.instance);
}

fn createDevice(self: *VulkanRenderer) !void {
    const d = &self.d;
    var count: u32 = 0;
    try check(d.vkEnumeratePhysicalDevices(self.instance, &count, null));
    var devices: [8]vk.VkPhysicalDevice = undefined;
    count = @min(count, devices.len);
    try check(d.vkEnumeratePhysicalDevices(self.instance, &count, &devices));

    // The first device that can draw and present. Monstar does not yet match
    // the compositor's main device from dma-buf feedback on multi-GPU systems.
    for (devices[0..count]) |physical| {
        var props: vk.VkPhysicalDeviceProperties = undefined;
        d.vkGetPhysicalDeviceProperties(physical, &props);
        if (props.apiVersion < vk.VK_API_VERSION_1_3) continue;
        var family_count: u32 = 0;
        d.vkGetPhysicalDeviceQueueFamilyProperties(physical, &family_count, null);
        var families: [16]vk.VkQueueFamilyProperties = undefined;
        family_count = @min(family_count, families.len);
        d.vkGetPhysicalDeviceQueueFamilyProperties(physical, &family_count, &families);
        for (families[0..family_count], 0..) |family, index| {
            if (family.queueFlags & vk.VK_QUEUE_GRAPHICS_BIT == 0) continue;
            if (self.surface != null) {
                var supported: vk.VkBool32 = vk.VK_FALSE;
                try check(d.vkGetPhysicalDeviceSurfaceSupportKHR(physical, @intCast(index), self.surface, &supported));
                if (supported == vk.VK_FALSE) continue;
            }
            self.physical = physical;
            self.queue_family = @intCast(index);
            self.timestamp_period = props.limits.timestampPeriod;
            self.timestamps_supported = family.timestampValidBits > 0;
            log.info("using {s} (driver {x})", .{ std.mem.sliceTo(&props.deviceName, 0), props.driverVersion });
            break;
        } else continue;
        break;
    } else return error.NoVulkanDevice;
    d.vkGetPhysicalDeviceMemoryProperties(self.physical, &self.memory_properties);

    var ext_count: u32 = 0;
    try check(d.vkEnumerateDeviceExtensionProperties(self.physical, null, &ext_count, null));
    const available = try self.alloc.alloc(vk.VkExtensionProperties, ext_count);
    defer self.alloc.free(available);
    try check(d.vkEnumerateDeviceExtensionProperties(self.physical, null, &ext_count, available.ptr));
    const has = struct {
        fn f(list: []const vk.VkExtensionProperties, name: []const u8) bool {
            for (list) |ext| if (std.mem.eql(u8, std.mem.sliceTo(&ext.extensionName, 0), name)) return true;
            return false;
        }
    }.f;

    var extensions: std.ArrayList([*:0]const u8) = .empty;
    defer extensions.deinit(self.alloc);
    if (self.surface != null) try extensions.append(self.alloc, "VK_KHR_swapchain");
    if (self.surface != null and has(available, "VK_KHR_incremental_present")) {
        try extensions.append(self.alloc, "VK_KHR_incremental_present");
        self.incremental_present = true;
    }
    if (has(available, "VK_EXT_image_drm_format_modifier")) {
        try extensions.append(self.alloc, "VK_EXT_image_drm_format_modifier");
        self.drm_modifiers = true;
    }
    var features13: vk.VkPhysicalDeviceVulkan13Features = .{
        .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
        .synchronization2 = vk.VK_TRUE,
        .dynamicRendering = vk.VK_TRUE,
    };
    var features12: vk.VkPhysicalDeviceVulkan12Features = .{
        .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
        .pNext = &features13,
        .timelineSemaphore = vk.VK_TRUE,
        .shaderSampledImageArrayNonUniformIndexing = vk.VK_TRUE,
    };
    var features: vk.VkPhysicalDeviceFeatures2 = .{
        .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
        .pNext = &features12,
    };
    features.features.dualSrcBlend = vk.VK_TRUE;
    const priority: f32 = 1;
    const queue_info: vk.VkDeviceQueueCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = self.queue_family,
        .queueCount = 1,
        .pQueuePriorities = &priority,
    };
    const info: vk.VkDeviceCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pNext = &features,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &queue_info,
        .enabledExtensionCount = @intCast(extensions.items.len),
        .ppEnabledExtensionNames = extensions.items.ptr,
    };
    try check(d.vkCreateDevice(self.physical, &info, null, &self.device));
    d.loadDevice(self.device);
    d.vkGetDeviceQueue(self.device, self.queue_family, 0, &self.queue);

    var timeline_type: vk.VkSemaphoreTypeCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO,
        .semaphoreType = vk.VK_SEMAPHORE_TYPE_TIMELINE,
        .initialValue = 0,
    };
    const sem_info: vk.VkSemaphoreCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        .pNext = &timeline_type,
    };
    try check(d.vkCreateSemaphore(self.device, &sem_info, null, &self.timeline));
}

fn createPipeline(self: *VulkanRenderer) !void {
    const d = &self.d;
    const frag = vk.VK_SHADER_STAGE_FRAGMENT_BIT;
    const bindings = [_]vk.VkDescriptorSetLayoutBinding{
        .{ .binding = 0, .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT },
        .{ .binding = 1, .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = frag },
        .{ .binding = 2, .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = frag },
        .{ .binding = 3, .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = frag },
        .{ .binding = 4, .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = frag },
        .{ .binding = 5, .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = GpuDrawList.max_images, .stageFlags = frag },
    };
    const layout_info: vk.VkDescriptorSetLayoutCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = bindings.len,
        .pBindings = &bindings,
    };
    try check(d.vkCreateDescriptorSetLayout(self.device, &layout_info, null, &self.set_layout));
    const push: vk.VkPushConstantRange = .{ .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT, .offset = 0, .size = 12 };
    const pipeline_layout_info: vk.VkPipelineLayoutCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 1,
        .pSetLayouts = &self.set_layout,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &push,
    };
    try check(d.vkCreatePipelineLayout(self.device, &pipeline_layout_info, null, &self.pipeline_layout));

    const vert_module = try self.shaderModule(&vert_spv);
    defer d.vkDestroyShaderModule(self.device, vert_module, null);
    const frag_module = try self.shaderModule(&frag_spv);
    defer d.vkDestroyShaderModule(self.device, frag_module, null);
    const stages = [_]vk.VkPipelineShaderStageCreateInfo{
        .{ .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = vk.VK_SHADER_STAGE_VERTEX_BIT, .module = vert_module, .pName = "main" },
        .{ .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = frag, .module = frag_module, .pName = "main" },
    };
    const vertex_input: vk.VkPipelineVertexInputStateCreateInfo = .{ .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
    const input_assembly: vk.VkPipelineInputAssemblyStateCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .topology = vk.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP,
    };
    const viewport: vk.VkPipelineViewportStateCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .viewportCount = 1,
        .scissorCount = 1,
    };
    const raster: vk.VkPipelineRasterizationStateCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .polygonMode = vk.VK_POLYGON_MODE_FILL,
        .cullMode = vk.VK_CULL_MODE_NONE,
        .frontFace = vk.VK_FRONT_FACE_COUNTER_CLOCKWISE,
        .lineWidth = 1,
    };
    const multisample: vk.VkPipelineMultisampleStateCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .rasterizationSamples = vk.VK_SAMPLE_COUNT_1_BIT,
    };
    // result = src0 + dst * (1 - src1.a); see canvas.frag.
    const blend_attachment: vk.VkPipelineColorBlendAttachmentState = .{
        .blendEnable = vk.VK_TRUE,
        .srcColorBlendFactor = vk.VK_BLEND_FACTOR_ONE,
        .dstColorBlendFactor = vk.VK_BLEND_FACTOR_ONE_MINUS_SRC1_ALPHA,
        .colorBlendOp = vk.VK_BLEND_OP_ADD,
        .srcAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE,
        .dstAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE_MINUS_SRC1_ALPHA,
        .alphaBlendOp = vk.VK_BLEND_OP_ADD,
        .colorWriteMask = vk.VK_COLOR_COMPONENT_R_BIT | vk.VK_COLOR_COMPONENT_G_BIT | vk.VK_COLOR_COMPONENT_B_BIT | vk.VK_COLOR_COMPONENT_A_BIT,
    };
    const blend: vk.VkPipelineColorBlendStateCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .attachmentCount = 1,
        .pAttachments = &blend_attachment,
    };
    const dynamic_states = [_]vk.VkDynamicState{ vk.VK_DYNAMIC_STATE_VIEWPORT, vk.VK_DYNAMIC_STATE_SCISSOR };
    const dynamic: vk.VkPipelineDynamicStateCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        .dynamicStateCount = dynamic_states.len,
        .pDynamicStates = &dynamic_states,
    };
    const color_format: vk.VkFormat = canvas_format;
    const rendering: vk.VkPipelineRenderingCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
        .colorAttachmentCount = 1,
        .pColorAttachmentFormats = &color_format,
    };
    const info: vk.VkGraphicsPipelineCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .pNext = &rendering,
        .stageCount = stages.len,
        .pStages = &stages,
        .pVertexInputState = &vertex_input,
        .pInputAssemblyState = &input_assembly,
        .pViewportState = &viewport,
        .pRasterizationState = &raster,
        .pMultisampleState = &multisample,
        .pColorBlendState = &blend,
        .pDynamicState = &dynamic,
        .layout = self.pipeline_layout,
    };
    try check(d.vkCreateGraphicsPipelines(self.device, null, 1, &info, null, &self.pipeline));
}

fn shaderModule(self: *VulkanRenderer, code: []align(4) const u8) !vk.VkShaderModule {
    const info: vk.VkShaderModuleCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = code.len,
        .pCode = @ptrCast(code.ptr),
    };
    var module: vk.VkShaderModule = null;
    try check(self.d.vkCreateShaderModule(self.device, &info, null, &module));
    return module;
}

fn createStaticResources(self: *VulkanRenderer) !void {
    const d = &self.d;
    const pool_info: vk.VkCommandPoolCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = vk.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = self.queue_family,
    };
    try check(d.vkCreateCommandPool(self.device, &pool_info, null, &self.cmd_pool));
    var cmds: [slot_count]vk.VkCommandBuffer = undefined;
    const cmd_info: vk.VkCommandBufferAllocateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = self.cmd_pool,
        .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = slot_count,
    };
    try check(d.vkAllocateCommandBuffers(self.device, &cmd_info, &cmds));

    const sizes = [_]vk.VkDescriptorPoolSize{
        .{ .type = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 2 * slot_count },
        .{ .type = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = (3 + GpuDrawList.max_images) * slot_count },
    };
    const desc_pool_info: vk.VkDescriptorPoolCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .maxSets = slot_count,
        .poolSizeCount = sizes.len,
        .pPoolSizes = &sizes,
    };
    try check(d.vkCreateDescriptorPool(self.device, &desc_pool_info, null, &self.descriptor_pool));
    const layouts: [slot_count]vk.VkDescriptorSetLayout = @splat(self.set_layout);
    var sets: [slot_count]vk.VkDescriptorSet = undefined;
    const set_info: vk.VkDescriptorSetAllocateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = self.descriptor_pool,
        .descriptorSetCount = slot_count,
        .pSetLayouts = &layouts,
    };
    try check(d.vkAllocateDescriptorSets(self.device, &set_info, &sets));
    for (&self.slots, cmds, sets) |*slot, cmd, set| {
        slot.cmd = cmd;
        slot.set = set;
    }

    if (self.timestamps_supported) {
        const query_info: vk.VkQueryPoolCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO,
            .queryType = vk.VK_QUERY_TYPE_TIMESTAMP,
            .queryCount = 4 * timed_frames,
        };
        try check(d.vkCreateQueryPool(self.device, &query_info, null, &self.query_pool));
    }

    const sampler_info: vk.VkSamplerCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        .magFilter = vk.VK_FILTER_NEAREST,
        .minFilter = vk.VK_FILTER_NEAREST,
        .mipmapMode = vk.VK_SAMPLER_MIPMAP_MODE_NEAREST,
        .addressModeU = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeV = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeW = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
    };
    try check(d.vkCreateSampler(self.device, &sampler_info, null, &self.sampler));

    // The CPU renderer's sRGB tables, so both backends quantize identically.
    var tables: [256 + 16384]u32 = undefined;
    for (tables[0..256], pixel_raster.decode) |*word, value| word.* = value;
    for (tables[256..], 0..) |*word, i| word.* = std.mem.readInt(u32, pixel_raster.encode[i * 4 ..][0..4], .little);
    self.tables = try self.createBuffer(@sizeOf(@TypeOf(tables)), vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
    @memcpy(self.tables.mapped[0..@sizeOf(@TypeOf(tables))], std.mem.asBytes(&tables));

    const sampled = vk.VK_IMAGE_USAGE_SAMPLED_BIT | vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT | vk.VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
    self.dummy = try self.createImage(1, 1, vk.VK_FORMAT_R8G8B8A8_UNORM, sampled, false);
    self.alpha_atlas = try self.createImage(GpuDrawList.atlas_width, self.list.atlasHeight(.alpha), vk.VK_FORMAT_R8_UNORM, sampled, false);
    self.color_atlas = try self.createImage(GpuDrawList.atlas_width, self.list.atlasHeight(.color), vk.VK_FORMAT_B8G8R8A8_UNORM, sampled, false);
}

fn memoryType(self: *const VulkanRenderer, bits: u32, want: vk.VkMemoryPropertyFlags, prefer: vk.VkMemoryPropertyFlags) !u32 {
    const props = &self.memory_properties;
    var fallback: ?u32 = null;
    for (0..props.memoryTypeCount) |i| {
        if (bits & (@as(u32, 1) << @intCast(i)) == 0) continue;
        const flags = props.memoryTypes[i].propertyFlags;
        if (flags & want != want) continue;
        if (flags & prefer == prefer) return @intCast(i);
        if (fallback == null) fallback = @intCast(i);
    }
    return fallback orelse error.NoVulkanMemoryType;
}

/// A persistently mapped, host-coherent buffer, in device-local memory when
/// the device offers host-visible VRAM (always on APUs).
fn createBuffer(self: *VulkanRenderer, size: usize, usage: vk.VkBufferUsageFlags) !Buffer {
    const d = &self.d;
    var buffer: Buffer = .{ .size = size };
    errdefer self.destroyBuffer(buffer);
    const info: vk.VkBufferCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = size,
        .usage = usage,
        .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
    };
    try check(d.vkCreateBuffer(self.device, &info, null, &buffer.buffer));
    var reqs: vk.VkMemoryRequirements = undefined;
    d.vkGetBufferMemoryRequirements(self.device, buffer.buffer, &reqs);
    const alloc_info: vk.VkMemoryAllocateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = reqs.size,
        .memoryTypeIndex = try self.memoryType(
            reqs.memoryTypeBits,
            vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        ),
    };
    try check(d.vkAllocateMemory(self.device, &alloc_info, null, &buffer.memory));
    try check(d.vkBindBufferMemory(self.device, buffer.buffer, buffer.memory, 0));
    var mapped: ?*anyopaque = null;
    try check(d.vkMapMemory(self.device, buffer.memory, 0, vk.VK_WHOLE_SIZE, 0, &mapped));
    buffer.mapped = @ptrCast(mapped.?);
    return buffer;
}

fn createImage(self: *VulkanRenderer, width: u32, height: u32, format: vk.VkFormat, usage: vk.VkImageUsageFlags, raw_view: bool) !Image {
    const d = &self.d;
    var image: Image = .{ .width = width, .height = height };
    errdefer self.destroyImage(image);
    const formats = [_]vk.VkFormat{ canvas_format, canvas_unorm_format };
    const format_list: vk.VkImageFormatListCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_FORMAT_LIST_CREATE_INFO,
        .viewFormatCount = formats.len,
        .pViewFormats = &formats,
    };
    const info: vk.VkImageCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .pNext = if (raw_view) &format_list else null,
        .flags = if (raw_view) vk.VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT else 0,
        .imageType = vk.VK_IMAGE_TYPE_2D,
        .format = format,
        .extent = .{ .width = width, .height = height, .depth = 1 },
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = vk.VK_SAMPLE_COUNT_1_BIT,
        .tiling = vk.VK_IMAGE_TILING_OPTIMAL,
        .usage = usage,
        .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
        .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
    };
    try check(d.vkCreateImage(self.device, &info, null, &image.image));
    var reqs: vk.VkMemoryRequirements = undefined;
    d.vkGetImageMemoryRequirements(self.device, image.image, &reqs);
    const alloc_info: vk.VkMemoryAllocateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = reqs.size,
        .memoryTypeIndex = try self.memoryType(reqs.memoryTypeBits, vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, 0),
    };
    try check(d.vkAllocateMemory(self.device, &alloc_info, null, &image.memory));
    try check(d.vkBindImageMemory(self.device, image.image, image.memory, 0));
    image.view = try self.imageView(image.image, format);
    if (raw_view) image.raw_view = try self.imageView(image.image, canvas_unorm_format);
    return image;
}

fn imageView(self: *VulkanRenderer, image: vk.VkImage, format: vk.VkFormat) !vk.VkImageView {
    const info: vk.VkImageViewCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image = image,
        .viewType = vk.VK_IMAGE_VIEW_TYPE_2D,
        .format = format,
        .subresourceRange = color_range,
    };
    var view: vk.VkImageView = null;
    try check(self.d.vkCreateImageView(self.device, &info, null, &view));
    return view;
}

pub const color_range: vk.VkImageSubresourceRange = .{
    .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
    .baseMipLevel = 0,
    .levelCount = 1,
    .baseArrayLayer = 0,
    .layerCount = 1,
};

pub const color_layers: vk.VkImageSubresourceLayers = .{
    .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
    .mipLevel = 0,
    .baseArrayLayer = 0,
    .layerCount = 1,
};

fn destroyImage(self: *VulkanRenderer, image: Image) void {
    const d = &self.d;
    if (image.raw_view != null) d.vkDestroyImageView(self.device, image.raw_view, null);
    if (image.view != null) d.vkDestroyImageView(self.device, image.view, null);
    if (image.image != null) d.vkDestroyImage(self.device, image.image, null);
    if (image.memory != null) d.vkFreeMemory(self.device, image.memory, null);
}

fn destroyBuffer(self: *VulkanRenderer, buffer: Buffer) void {
    const d = &self.d;
    if (buffer.buffer != null) d.vkDestroyBuffer(self.device, buffer.buffer, null);
    if (buffer.memory != null) d.vkFreeMemory(self.device, buffer.memory, null);
}

fn destroyObject(self: *VulkanRenderer, object: @FieldType(Garbage, "object")) void {
    switch (object) {
        .image => |image| self.destroyImage(image),
        .buffer => |buffer| self.destroyBuffer(buffer),
    }
}

/// Destroy `object` once the next frame submission has completed. The frame
/// being prepared may still read it (atlas growth copies the old atlas).
fn retire(self: *VulkanRenderer, object: @FieldType(Garbage, "object")) !void {
    try self.garbage.append(self.alloc, .{ .after = pending_retire, .object = object });
}

const pending_retire = std.math.maxInt(u64);

fn collectGarbage(self: *VulkanRenderer) void {
    var kept: usize = 0;
    for (self.garbage.items) |item| {
        if (self.reached(item.after)) {
            self.destroyObject(item.object);
        } else {
            self.garbage.items[kept] = item;
            kept += 1;
        }
    }
    self.garbage.items.len = kept;
}

fn reached(self: *VulkanRenderer, value: u64) bool {
    if (value == 0) return true;
    if (value == pending_retire) return false;
    const info: vk.VkSemaphoreWaitInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO,
        .semaphoreCount = 1,
        .pSemaphores = &self.timeline,
        .pValues = &value,
    };
    return self.d.vkWaitSemaphores(self.device, &info, 0) == vk.VK_SUCCESS;
}

/// Block until the timeline reaches `value`.
pub fn waitValue(self: *VulkanRenderer, value: u64) !void {
    if (value == 0) return;
    const info: vk.VkSemaphoreWaitInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO,
        .semaphoreCount = 1,
        .pSemaphores = &self.timeline,
        .pValues = &value,
    };
    try check(self.d.vkWaitSemaphores(self.device, &info, std.math.maxInt(u64)));
}

pub fn lockQueue(self: *VulkanRenderer) void {
    while (!self.queue_mutex.tryLock()) std.Thread.yield() catch {};
}

/// Submit `cmd` waiting on `waits` and signaling the next timeline value
/// plus `signal` (a binary semaphore, or null). Returns the timeline value.
pub fn submit(
    self: *VulkanRenderer,
    cmd: vk.VkCommandBuffer,
    waits: []const vk.VkSemaphoreSubmitInfo,
    signal: vk.VkSemaphore,
) !u64 {
    self.lockQueue();
    defer self.queue_mutex.unlock();
    const value = self.timeline_value + 1;
    const signals = [_]vk.VkSemaphoreSubmitInfo{
        .{ .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO, .semaphore = self.timeline, .value = value, .stageMask = vk.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT },
        .{ .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO, .semaphore = signal, .stageMask = vk.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT },
    };
    const cmd_info: vk.VkCommandBufferSubmitInfo = .{ .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO, .commandBuffer = cmd };
    const info: vk.VkSubmitInfo2 = .{
        .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
        .waitSemaphoreInfoCount = @intCast(waits.len),
        .pWaitSemaphoreInfos = waits.ptr,
        .commandBufferInfoCount = 1,
        .pCommandBufferInfos = &cmd_info,
        .signalSemaphoreInfoCount = if (signal != null) 2 else 1,
        .pSignalSemaphoreInfos = &signals,
    };
    try check(self.d.vkQueueSubmit2(self.queue, 1, &info, null));
    self.timeline_value = value;
    return value;
}

/// Begin recording a frame of `width`×`height` surface pixels. Recreates the
/// canvases when the size changed, in which case the list reports no
/// previous frame and the Renderer draws everything.
/// `font_id` identifies the Font whose glyphs the frame draws; the atlas is
/// emptied when it changes.
pub fn beginFrame(self: *VulkanRenderer, width: u31, height: u31, font_id: u64) !*GpuDrawList {
    std.debug.assert(width > 0 and height > 0);
    if (font_id != self.font_id) {
        self.list.resetGlyphs();
        self.font_id = font_id;
    }
    self.list.begin();
    if (self.canvases[0].width != width or self.canvases[0].height != height) {
        for (&self.canvases, &self.bgmaps) |*canvas, *bgmap| {
            if (canvas.image != null) try self.retire(.{ .image = canvas.* });
            if (bgmap.image != null) try self.retire(.{ .image = bgmap.* });
            canvas.* = .{};
            bgmap.* = .{};
        }
        const usage = vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | vk.VK_IMAGE_USAGE_TRANSFER_SRC_BIT | vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT;
        for (&self.canvases, &self.bgmaps) |*canvas, *bgmap| {
            canvas.* = try self.createImage(width, height, canvas_format, usage, false);
            bgmap.* = try self.createImage(width, height, canvas_format, usage | vk.VK_IMAGE_USAGE_SAMPLED_BIT, true);
        }
        self.canvas_valid = false;
    }
    self.list.previous_frame = self.canvas_valid;
    return &self.list;
}

/// Abandon the frame being recorded. Its uploads were never submitted.
pub fn cancelFrame(self: *VulkanRenderer) void {
    self.list.abortFrame();
}

/// The canvas holding the latest submitted frame, the timeline value after
/// which it is complete, and its frame number (see `frameGpuNs`).
pub fn presentable(self: *const VulkanRenderer) struct { image: vk.VkImage, width: u32, height: u32, value: u64, seq: u64 } {
    const canvas = self.canvases[self.current];
    return .{ .image = canvas.image, .width = canvas.width, .height = canvas.height, .value = self.last_frame_value, .seq = self.frame_seq };
}

/// First of the four timestamp queries of frame `seq`: render begin and end,
/// then presentation copy begin and end.
fn frameQueries(seq: u64) u32 {
    return @intCast((seq % timed_frames) * 4);
}

/// Record the presentation copy's timestamps for frame `seq` into `cmd`;
/// `end` false writes the start, true the end.
pub fn writeCopyTimestamp(self: *VulkanRenderer, cmd: vk.VkCommandBuffer, seq: u64, end: bool) void {
    if (self.query_pool == null or seq == 0) return;
    const base = frameQueries(seq) + 2;
    if (!end) {
        self.d.vkCmdResetQueryPool(cmd, self.query_pool, base, 2);
        self.d.vkCmdWriteTimestamp2(cmd, vk.VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT, self.query_pool, base);
    } else {
        self.d.vkCmdWriteTimestamp2(cmd, vk.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, self.query_pool, base + 1);
    }
}

/// GPU time of frame `seq` (rasterization plus its presentation copy) in
/// ns, or null when unavailable. Valid only for a frame whose copy was
/// submitted, within `timed_frames` frames. Waits for that GPU work: some
/// compositors (headless wlroots) report a frame presented before it
/// finished. Safe on the main thread while the worker records later frames.
pub fn frameGpuNs(self: *VulkanRenderer, seq: u64) ?u64 {
    if (self.query_pool == null or seq == 0 or seq + timed_frames <= @atomicLoad(u64, &self.frame_seq, .acquire)) return null;
    // Value and availability for each of the four queries.
    var results: [8]u64 = undefined;
    const flags = vk.VK_QUERY_RESULT_64_BIT | vk.VK_QUERY_RESULT_WAIT_BIT | vk.VK_QUERY_RESULT_WITH_AVAILABILITY_BIT;
    const rc = self.d.vkGetQueryPoolResults(self.device, self.query_pool, frameQueries(seq), 4, @sizeOf(@TypeOf(results)), &results, 16, flags);
    if (rc != vk.VK_SUCCESS and rc != vk.VK_NOT_READY) return null;
    for (0..4) |i| if (results[2 * i + 1] == 0) return null;
    const ticks = (results[2] -% results[0]) +% (results[6] -% results[4]);
    return @intFromFloat(@as(f64, @floatFromInt(ticks)) * self.timestamp_period);
}

/// Rasterize the recorded frame into the canvas.
pub fn submitFrame(self: *VulkanRenderer) !void {
    const list = &self.list;
    if (list.ops.items.len == 0 and list.scroll == null and list.glyph_uploads.items.len == 0 and
        list.image_uploads.items.len == 0) return;
    errdefer list.abortFrame();
    const d = &self.d;
    const slot = &self.slots[self.slot_index];
    try self.waitValue(slot.done_value);
    self.readTimestamps(slot);
    self.collectGarbage();

    var new_images: std.ArrayList(vk.VkImage) = .empty;
    defer new_images.deinit(self.alloc);
    var atlas_copies: [2]?struct { old: Image, new: Image } = .{ null, null };
    for ([_]GpuDrawList.AtlasFormat{ .alpha, .color }, 0..) |format, i| {
        const atlas = switch (format) {
            .alpha => &self.alpha_atlas,
            .color => &self.color_atlas,
        };
        const height = list.atlasHeight(format);
        if (atlas.height >= height) continue;
        const sampled = vk.VK_IMAGE_USAGE_SAMPLED_BIT | vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT | vk.VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
        const grown = try self.createImage(GpuDrawList.atlas_width, height, switch (format) {
            .alpha => vk.VK_FORMAT_R8_UNORM,
            .color => vk.VK_FORMAT_B8G8R8A8_UNORM,
        }, sampled, false);
        atlas_copies[i] = .{ .old = atlas.*, .new = grown };
        try self.retire(.{ .image = atlas.* });
        atlas.* = grown;
    }
    for (list.image_uploads.items) |upload| {
        const image = &self.images[upload.slot];
        if (image.image != null and image.width == upload.width and image.height == upload.height) continue;
        if (image.image != null) try self.retire(.{ .image = image.* });
        image.* = .{};
        image.* = try self.createImage(upload.width, upload.height, vk.VK_FORMAT_R8G8B8A8_UNORM, vk.VK_IMAGE_USAGE_SAMPLED_BIT | vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT, false);
    }

    const op_bytes = (list.bg_ops.items.len + list.ops.items.len) * @sizeOf(GpuDrawList.Op);
    if (slot.ops.size < op_bytes or slot.ops.buffer == null) {
        if (slot.ops.buffer != null) try self.retire(.{ .buffer = slot.ops });
        slot.ops = .{};
        slot.ops = try self.createBuffer(std.math.ceilPowerOfTwoAssert(usize, @max(op_bytes, 64 * 1024)), vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
    }
    const bg_bytes = std.mem.sliceAsBytes(list.bg_ops.items);
    @memcpy(slot.ops.mapped[0..bg_bytes.len], bg_bytes);
    const all_bytes = std.mem.sliceAsBytes(list.ops.items);
    @memcpy(slot.ops.mapped[bg_bytes.len..][0..all_bytes.len], all_bytes);
    const upload_bytes = list.upload_bytes.items;
    if (upload_bytes.len > 0 and (slot.staging.buffer == null or slot.staging.size < upload_bytes.len)) {
        if (slot.staging.buffer != null) try self.retire(.{ .buffer = slot.staging });
        slot.staging = .{};
        slot.staging = try self.createBuffer(std.math.ceilPowerOfTwoAssert(usize, @max(upload_bytes.len, 256 * 1024)), vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
    }
    if (upload_bytes.len > 0) @memcpy(slot.staging.mapped[0..upload_bytes.len], upload_bytes);

    if (list.scroll != null) self.current ^= 1;
    self.updateDescriptors(slot);

    const cmd = slot.cmd;
    try check(d.vkResetCommandBuffer(cmd, 0));
    const begin: vk.VkCommandBufferBeginInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };
    try check(d.vkBeginCommandBuffer(cmd, &begin));
    const seq = self.frame_seq + 1;
    const query_base = frameQueries(seq);
    if (self.query_pool != null) {
        d.vkCmdResetQueryPool(cmd, self.query_pool, query_base, 2);
        d.vkCmdWriteTimestamp2(cmd, vk.VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT, self.query_pool, query_base);
    }

    // Images used for the first time leave UNDEFINED; everything lives in
    // GENERAL afterwards, ordered by full memory barriers below.
    var transitions: std.ArrayList(vk.VkImageMemoryBarrier2) = .empty;
    defer transitions.deinit(self.alloc);
    const all_images = [_]*Image{ &self.alpha_atlas, &self.color_atlas, &self.dummy } ++ ptrs(&self.canvases) ++ ptrs(&self.bgmaps);
    for (all_images) |image| try self.noteNewImage(&transitions, image);
    for (&self.images) |*image| try self.noteNewImage(&transitions, image);
    self.barrier(cmd, transitions.items);

    for (atlas_copies) |maybe| {
        const copy = maybe orelse continue;
        const region: vk.VkImageCopy = .{
            .srcSubresource = color_layers,
            .dstSubresource = color_layers,
            .extent = .{ .width = copy.old.width, .height = copy.old.height, .depth = 1 },
        };
        d.vkCmdCopyImage(cmd, copy.old.image, vk.VK_IMAGE_LAYOUT_GENERAL, copy.new.image, vk.VK_IMAGE_LAYOUT_GENERAL, 1, &region);
    }
    if (atlas_copies[0] != null or atlas_copies[1] != null) self.barrier(cmd, &.{});
    for (list.glyph_uploads.items) |upload| {
        const region: vk.VkBufferImageCopy = .{
            .bufferOffset = upload.offset,
            .imageSubresource = color_layers,
            .imageOffset = .{ .x = upload.x, .y = upload.y, .z = 0 },
            .imageExtent = .{ .width = upload.width, .height = upload.height, .depth = 1 },
        };
        const atlas = switch (upload.format) {
            .alpha => self.alpha_atlas.image,
            .color => self.color_atlas.image,
        };
        d.vkCmdCopyBufferToImage(cmd, slot.staging.buffer, atlas, vk.VK_IMAGE_LAYOUT_GENERAL, 1, &region);
    }
    for (list.image_uploads.items) |upload| {
        const region: vk.VkBufferImageCopy = .{
            .bufferOffset = upload.offset,
            .imageSubresource = color_layers,
            .imageExtent = .{ .width = upload.width, .height = upload.height, .depth = 1 },
        };
        d.vkCmdCopyBufferToImage(cmd, slot.staging.buffer, self.images[upload.slot].image, vk.VK_IMAGE_LAYOUT_GENERAL, 1, &region);
    }
    if (list.scroll) |scroll| {
        const previous = self.current ^ 1;
        const region: vk.VkImageCopy = .{
            .srcSubresource = color_layers,
            .srcOffset = .{ .x = scroll.x, .y = scroll.src_y, .z = 0 },
            .dstSubresource = color_layers,
            .dstOffset = .{ .x = scroll.x, .y = scroll.dst_y, .z = 0 },
            .extent = .{ .width = scroll.width, .height = scroll.height, .depth = 1 },
        };
        d.vkCmdCopyImage(cmd, self.canvases[previous].image, vk.VK_IMAGE_LAYOUT_GENERAL, self.canvases[self.current].image, vk.VK_IMAGE_LAYOUT_GENERAL, 1, &region);
        d.vkCmdCopyImage(cmd, self.bgmaps[previous].image, vk.VK_IMAGE_LAYOUT_GENERAL, self.bgmaps[self.current].image, vk.VK_IMAGE_LAYOUT_GENERAL, 1, &region);
    }
    self.barrier(cmd, &.{});

    const bounds = (list.bounds orelse GpuDrawList.Rect{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 }).intersect(.{
        .x0 = 0,
        .y0 = 0,
        .x1 = @intCast(self.canvases[0].width),
        .y1 = @intCast(self.canvases[0].height),
    });
    if (!bounds.isEmpty()) {
        if (list.bg_ops.items.len > 0) {
            self.draw(cmd, slot, self.bgmaps[self.current].view, bounds, 0, list.bg_ops.items.len);
            self.barrier(cmd, &.{});
        }
        if (list.ops.items.len > 0) {
            self.draw(cmd, slot, self.canvases[self.current].view, bounds, list.bg_ops.items.len, list.ops.items.len);
        }
    }
    if (self.query_pool != null) {
        d.vkCmdWriteTimestamp2(cmd, vk.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, self.query_pool, query_base + 1);
        slot.timed_seq = seq;
    }
    try check(d.vkEndCommandBuffer(cmd));

    const value = try self.submit(cmd, &.{}, null);
    for (self.garbage.items) |*item| {
        if (item.after == pending_retire) item.after = value;
    }
    for (all_images) |image| {
        if (image.image != null) image.ready = true;
    }
    for (&self.images) |*image| {
        if (image.image != null) image.ready = true;
    }
    slot.done_value = value;
    self.last_frame_value = value;
    @atomicStore(u64, &self.frame_seq, seq, .release);
    self.slot_index = (self.slot_index + 1) % slot_count;
    self.canvas_valid = true;
    self.stats.ops += list.ops.items.len;
}

fn ptrs(images: *[2]Image) [2]*Image {
    return .{ &images[0], &images[1] };
}

fn noteNewImage(self: *VulkanRenderer, transitions: *std.ArrayList(vk.VkImageMemoryBarrier2), image: *const Image) !void {
    if (image.image == null or image.ready) return;
    try transitions.append(self.alloc, .{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
        .srcStageMask = vk.VK_PIPELINE_STAGE_2_NONE,
        .srcAccessMask = 0,
        .dstStageMask = vk.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
        .dstAccessMask = vk.VK_ACCESS_2_MEMORY_READ_BIT | vk.VK_ACCESS_2_MEMORY_WRITE_BIT,
        .oldLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
        .newLayout = vk.VK_IMAGE_LAYOUT_GENERAL,
        .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
        .image = image.image,
        .subresourceRange = color_range,
    });
}

/// A full memory barrier plus `images` layout transitions.
pub fn barrier(self: *VulkanRenderer, cmd: vk.VkCommandBuffer, images: []const vk.VkImageMemoryBarrier2) void {
    const memory: vk.VkMemoryBarrier2 = .{
        .sType = vk.VK_STRUCTURE_TYPE_MEMORY_BARRIER_2,
        .srcStageMask = vk.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
        .srcAccessMask = vk.VK_ACCESS_2_MEMORY_WRITE_BIT,
        .dstStageMask = vk.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
        .dstAccessMask = vk.VK_ACCESS_2_MEMORY_READ_BIT | vk.VK_ACCESS_2_MEMORY_WRITE_BIT,
    };
    const info: vk.VkDependencyInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
        .memoryBarrierCount = 1,
        .pMemoryBarriers = &memory,
        .imageMemoryBarrierCount = @intCast(images.len),
        .pImageMemoryBarriers = images.ptr,
    };
    self.d.vkCmdPipelineBarrier2(cmd, &info);
}

fn draw(
    self: *VulkanRenderer,
    cmd: vk.VkCommandBuffer,
    slot: *const Slot,
    target: vk.VkImageView,
    bounds: GpuDrawList.Rect,
    base: usize,
    count: usize,
) void {
    const d = &self.d;
    const width = self.canvases[0].width;
    const height = self.canvases[0].height;
    const area: vk.VkRect2D = .{
        .offset = .{ .x = bounds.x0, .y = bounds.y0 },
        .extent = .{ .width = @intCast(bounds.x1 - bounds.x0), .height = @intCast(bounds.y1 - bounds.y0) },
    };
    const attachment: vk.VkRenderingAttachmentInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
        .imageView = target,
        .imageLayout = vk.VK_IMAGE_LAYOUT_GENERAL,
        .loadOp = vk.VK_ATTACHMENT_LOAD_OP_LOAD,
        .storeOp = vk.VK_ATTACHMENT_STORE_OP_STORE,
    };
    const rendering: vk.VkRenderingInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_RENDERING_INFO,
        .renderArea = area,
        .layerCount = 1,
        .colorAttachmentCount = 1,
        .pColorAttachments = &attachment,
    };
    d.vkCmdBeginRendering(cmd, &rendering);
    d.vkCmdBindPipeline(cmd, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline);
    d.vkCmdBindDescriptorSets(cmd, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline_layout, 0, 1, &slot.set, 0, null);
    const viewport: vk.VkViewport = .{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(width),
        .height = @floatFromInt(height),
        .minDepth = 0,
        .maxDepth = 1,
    };
    d.vkCmdSetViewport(cmd, 0, 1, &viewport);
    d.vkCmdSetScissor(cmd, 0, 1, &area);
    const push = extern struct { scale: [2]f32, base: u32 }{
        .scale = .{ 2.0 / @as(f32, @floatFromInt(width)), 2.0 / @as(f32, @floatFromInt(height)) },
        .base = @intCast(base),
    };
    d.vkCmdPushConstants(cmd, self.pipeline_layout, vk.VK_SHADER_STAGE_VERTEX_BIT, 0, 12, &push);
    d.vkCmdDraw(cmd, 4, @intCast(count), 0, 0);
    d.vkCmdEndRendering(cmd);
}

fn updateDescriptors(self: *VulkanRenderer, slot: *const Slot) void {
    const ops_info: vk.VkDescriptorBufferInfo = .{ .buffer = slot.ops.buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE };
    const tables_info: vk.VkDescriptorBufferInfo = .{ .buffer = self.tables.buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE };
    const image_info = struct {
        fn f(sampler: vk.VkSampler, view: vk.VkImageView) vk.VkDescriptorImageInfo {
            return .{ .sampler = sampler, .imageView = view, .imageLayout = vk.VK_IMAGE_LAYOUT_GENERAL };
        }
    }.f;
    const alpha = image_info(self.sampler, self.alpha_atlas.view);
    const color = image_info(self.sampler, self.color_atlas.view);
    const bgmap = image_info(self.sampler, self.bgmaps[self.current].raw_view);
    var images: [GpuDrawList.max_images]vk.VkDescriptorImageInfo = undefined;
    for (&images, self.images) |*info, image| {
        info.* = image_info(self.sampler, if (image.view != null) image.view else self.dummy.view);
    }
    const base: vk.VkWriteDescriptorSet = .{ .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = slot.set, .descriptorCount = 1 };
    var writes: [6]vk.VkWriteDescriptorSet = @splat(base);
    writes[0].dstBinding = 0;
    writes[0].descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    writes[0].pBufferInfo = &ops_info;
    writes[1].dstBinding = 1;
    writes[1].descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    writes[1].pBufferInfo = &tables_info;
    for ([_]*const vk.VkDescriptorImageInfo{ &alpha, &color, &bgmap }, 2..) |info, binding| {
        writes[binding].dstBinding = @intCast(binding);
        writes[binding].descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        writes[binding].pImageInfo = info;
    }
    writes[5].dstBinding = 5;
    writes[5].descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    writes[5].descriptorCount = GpuDrawList.max_images;
    writes[5].pImageInfo = &images;
    self.d.vkUpdateDescriptorSets(self.device, writes.len, &writes, 0, null);
}

fn readTimestamps(self: *VulkanRenderer, slot: *Slot) void {
    if (slot.timed_seq == 0) return;
    const seq = slot.timed_seq;
    slot.timed_seq = 0;
    var values: [2]u64 = undefined;
    if (self.d.vkGetQueryPoolResults(self.device, self.query_pool, frameQueries(seq), 2, @sizeOf(@TypeOf(values)), &values, 8, vk.VK_QUERY_RESULT_64_BIT) != vk.VK_SUCCESS) return;
    const ns: u64 = @intFromFloat(@as(f64, @floatFromInt(values[1] -% values[0])) * self.timestamp_period);
    self.stats.frames += 1;
    self.stats.gpu_ns += ns;
    self.stats.gpu_max_ns = @max(self.stats.gpu_max_ns, ns);
}

/// Take and reset GPU statistics for frames completed so far.
pub fn takeStats(self: *VulkanRenderer) Stats {
    const stats = self.stats;
    self.stats = .{};
    return stats;
}

/// Read back the canvas into `pixels` (ARGB8888 rows, `width` stride) for
/// tests and parity checks. Waits for the GPU.
pub fn readCanvas(self: *VulkanRenderer, pixels: []u32) !void {
    const canvas = self.canvases[self.current];
    std.debug.assert(pixels.len == @as(usize, canvas.width) * canvas.height);
    const d = &self.d;
    const bytes = pixels.len * 4;
    const buffer = try self.createBuffer(bytes, vk.VK_BUFFER_USAGE_TRANSFER_DST_BIT);
    defer self.destroyBuffer(buffer);
    const slot = &self.slots[self.slot_index];
    try self.waitValue(slot.done_value);
    self.readTimestamps(slot);
    const cmd = slot.cmd;
    try check(d.vkResetCommandBuffer(cmd, 0));
    const begin: vk.VkCommandBufferBeginInfo = .{ .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    try check(d.vkBeginCommandBuffer(cmd, &begin));
    self.barrier(cmd, &.{});
    const region: vk.VkBufferImageCopy = .{
        .imageSubresource = color_layers,
        .imageExtent = .{ .width = canvas.width, .height = canvas.height, .depth = 1 },
    };
    d.vkCmdCopyImageToBuffer(cmd, canvas.image, vk.VK_IMAGE_LAYOUT_GENERAL, buffer.buffer, 1, &region);
    self.barrier(cmd, &.{});
    try check(d.vkEndCommandBuffer(cmd));
    const value = try self.submit(cmd, &.{}, null);
    slot.done_value = value;
    try self.waitValue(value);
    @memcpy(std.mem.sliceAsBytes(pixels), buffer.mapped[0..bytes]);
}

/// Creates a renderer on its own thread so Vulkan's driver load and shader
/// compile overlap font loading and the first frames. The controlling thread
/// polls `complete_fd` and must eventually call `deinit`.
pub const Loader = struct {
    alloc: std.mem.Allocator,
    options: Options,
    thread: ?std.Thread = null,
    result: ?anyerror!*VulkanRenderer = null,
    done: std.atomic.Value(bool) = .init(false),
    complete_fd: std.posix.fd_t,

    pub fn init(alloc: std.mem.Allocator, options: Options) !Loader {
        const linux = std.os.linux;
        const rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (linux.errno(rc) != .SUCCESS) return error.EventFdFailed;
        return .{ .alloc = alloc, .options = options, .complete_fd = @intCast(rc) };
    }

    /// `self` must not move until the thread is joined.
    pub fn start(self: *Loader) !void {
        self.thread = try std.Thread.spawn(.{}, loadMain, .{self});
    }

    fn loadMain(self: *Loader) void {
        const start_ns = monotonicNs();
        self.result = create(self.alloc, self.options);
        log.info("initialized in {d:.1} ms", .{@as(f64, @floatFromInt(monotonicNs() - start_ns)) / std.time.ns_per_ms});
        self.done.store(true, .release);
        const one: u64 = 1;
        _ = std.os.linux.write(self.complete_fd, @ptrCast(&one), @sizeOf(u64));
    }

    /// Null while loading; afterwards the renderer (owned by the caller) or
    /// the load error, exactly once.
    pub fn takeResult(self: *Loader) ?anyerror!*VulkanRenderer {
        if (!self.done.load(.acquire)) return null;
        if (self.thread) |thread| thread.join();
        self.thread = null;
        const result = self.result orelse return null;
        self.result = null;
        return result;
    }

    /// Joins the thread and destroys a renderer nobody took.
    pub fn deinit(self: *Loader) void {
        if (self.thread) |thread| thread.join();
        if (self.result) |result| {
            if (result) |renderer| renderer.destroy() else |_| {}
        }
        _ = std.os.linux.close(self.complete_fd);
        self.* = undefined;
    }
};

fn monotonicNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}
