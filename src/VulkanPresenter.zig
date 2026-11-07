//! Presents VulkanRenderer canvases through a VK_KHR_swapchain on the
//! window's wl_surface.
//!
//! Each frame copies only the canvas regions a swapchain image missed since
//! it last held a frame (its age, as with Window's shm buffers) and passes the
//! frame's damage to the compositor with VK_KHR_incremental_present. The app
//! keeps pacing with its own frame callbacks: the swapchain uses a mailbox or
//! immediate present mode so vkQueuePresentKHR never blocks on the compositor.
//!
//! Direct scanout depends on the buffer modifiers. Mesa's WSI picks them
//! from the surface's dma-buf feedback and reports VK_SUBOPTIMAL_KHR when the
//! feedback changes, for example when the window becomes fullscreen and the
//! compositor adds a scanout tranche. The swapchain is recreated then: RADV's
//! default modifier is not scanout-capable, while the one Mesa picks from the
//! tranche is (still compressed).
//!
//! All functions run on the thread that dispatches the Wayland display.

const VulkanPresenter = @This();

const std = @import("std");
const vk = @import("vk");
const Dispatch = @import("VulkanDispatch.zig");
const Renderer = @import("Renderer.zig");
const VulkanRenderer = @import("VulkanRenderer.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.vulkan);
const check = Dispatch.check;
const max_images = 8;

renderer: *VulkanRenderer,
cmd_pool: vk.VkCommandPool = null,
swapchain: vk.VkSwapchainKHR = null,
image_count: u32 = 0,
images: [max_images]vk.VkImage = @splat(null),
/// Presentation counter value of each image's last frame; 0 if none.
image_frames: [max_images]u64 = @splat(0),
cmds: [max_images]vk.VkCommandBuffer = @splat(null),
cmd_values: [max_images]u64 = @splat(0),
present_semaphores: [max_images]vk.VkSemaphore = @splat(null),
acquire_semaphores: [max_images + 1]vk.VkSemaphore = @splat(null),
acquire_values: [max_images + 1]u64 = @splat(0),
acquire_index: usize = 0,
width: u32 = 0,
height: u32 = 0,
opaque_surface: bool = true,
frames: u64 = 0,
recreate: bool = false,
present_mode: vk.VkPresentModeKHR = vk.VK_PRESENT_MODE_MAILBOX_KHR,

pub const Acquired = struct {
    index: u32,
    /// Frames since this image last held a presented frame; 0 when it never
    /// did. Age 1 means it already shows the previous frame.
    age: usize,
};

/// `renderer` must have been created with a Wayland surface.
pub fn init(renderer: *VulkanRenderer) !VulkanPresenter {
    std.debug.assert(renderer.surface != null);
    var self: VulkanPresenter = .{ .renderer = renderer };
    const pool_info: vk.VkCommandPoolCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = vk.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = renderer.queue_family,
    };
    try check(renderer.d.vkCreateCommandPool(renderer.device, &pool_info, null, &self.cmd_pool));
    errdefer renderer.d.vkDestroyCommandPool(renderer.device, self.cmd_pool, null);
    const cmd_info: vk.VkCommandBufferAllocateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = self.cmd_pool,
        .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = max_images,
    };
    try check(renderer.d.vkAllocateCommandBuffers(renderer.device, &cmd_info, &self.cmds));
    const sem_info: vk.VkSemaphoreCreateInfo = .{ .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
    for (&self.acquire_semaphores) |*sem| try check(renderer.d.vkCreateSemaphore(renderer.device, &sem_info, null, sem));
    for (&self.present_semaphores) |*sem| try check(renderer.d.vkCreateSemaphore(renderer.device, &sem_info, null, sem));
    self.present_mode = try self.choosePresentMode();
    return self;
}

/// Wait for the GPU, then destroy the swapchain. The surface belongs to the
/// renderer.
pub fn deinit(self: *VulkanPresenter) void {
    const r = self.renderer;
    r.lockQueue();
    _ = r.d.vkDeviceWaitIdle(r.device);
    r.queue_mutex.unlock();
    if (self.swapchain != null) r.d.vkDestroySwapchainKHR(r.device, self.swapchain, null);
    for (self.acquire_semaphores ++ self.present_semaphores) |sem| {
        if (sem != null) r.d.vkDestroySemaphore(r.device, sem, null);
    }
    if (self.cmd_pool != null) r.d.vkDestroyCommandPool(r.device, self.cmd_pool, null);
    self.* = undefined;
}

fn choosePresentMode(self: *VulkanPresenter) !vk.VkPresentModeKHR {
    const r = self.renderer;
    var count: u32 = 0;
    try check(r.d.vkGetPhysicalDeviceSurfacePresentModesKHR(r.physical, r.surface, &count, null));
    var modes: [16]vk.VkPresentModeKHR = undefined;
    count = @min(count, modes.len);
    try check(r.d.vkGetPhysicalDeviceSurfacePresentModesKHR(r.physical, r.surface, &count, &modes));
    // Frame callbacks pace the app, so presenting must not block. FIFO is the
    // only mode every driver must offer.
    for ([_]vk.VkPresentModeKHR{ vk.VK_PRESENT_MODE_MAILBOX_KHR, vk.VK_PRESENT_MODE_IMMEDIATE_KHR }) |wanted| {
        for (modes[0..count]) |mode| if (mode == wanted) return mode;
    }
    return vk.VK_PRESENT_MODE_FIFO_KHR;
}

fn createSwapchain(self: *VulkanPresenter, width: u32, height: u32, opaque_surface: bool) !void {
    const r = self.renderer;
    const d = &r.d;
    var caps: vk.VkSurfaceCapabilitiesKHR = undefined;
    try check(d.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(r.physical, r.surface, &caps));
    var format_count: u32 = 0;
    try check(d.vkGetPhysicalDeviceSurfaceFormatsKHR(r.physical, r.surface, &format_count, null));
    var formats: [32]vk.VkSurfaceFormatKHR = undefined;
    format_count = @min(format_count, formats.len);
    try check(d.vkGetPhysicalDeviceSurfaceFormatsKHR(r.physical, r.surface, &format_count, &formats));
    // Frames are byte copies of the sRGB-encoded canvas; either view of the
    // BGRA format produces the same wl_buffer contents.
    const format = for (formats[0..format_count]) |f| {
        if (f.format == vk.VK_FORMAT_B8G8R8A8_UNORM or f.format == vk.VK_FORMAT_B8G8R8A8_SRGB) break f;
    } else return error.NoSwapchainFormat;

    const composite: vk.VkCompositeAlphaFlagBitsKHR = if (opaque_surface and caps.supportedCompositeAlpha & vk.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR != 0)
        vk.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR
    else if (caps.supportedCompositeAlpha & vk.VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR != 0)
        vk.VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR
    else
        vk.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    var min_images = @max(caps.minImageCount, 3);
    if (caps.maxImageCount != 0) min_images = @min(min_images, caps.maxImageCount);
    min_images = @min(min_images, max_images);

    const old = self.swapchain;
    const info: vk.VkSwapchainCreateInfoKHR = .{
        .sType = vk.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .surface = r.surface,
        .minImageCount = min_images,
        .imageFormat = format.format,
        .imageColorSpace = format.colorSpace,
        .imageExtent = .{ .width = width, .height = height },
        .imageArrayLayers = 1,
        .imageUsage = vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
        .imageSharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
        .preTransform = vk.VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR,
        .compositeAlpha = composite,
        .presentMode = self.present_mode,
        .clipped = vk.VK_TRUE,
        .oldSwapchain = old,
    };

    // Old images may still be read by copies in flight.
    r.lockQueue();
    _ = d.vkDeviceWaitIdle(r.device);
    r.queue_mutex.unlock();
    var swapchain: vk.VkSwapchainKHR = null;
    try check(d.vkCreateSwapchainKHR(r.device, &info, null, &swapchain));
    if (old != null) d.vkDestroySwapchainKHR(r.device, old, null);
    self.swapchain = swapchain;
    var count: u32 = 0;
    try check(d.vkGetSwapchainImagesKHR(r.device, swapchain, &count, null));
    if (count > max_images) return error.TooManySwapchainImages;
    try check(d.vkGetSwapchainImagesKHR(r.device, swapchain, &count, &self.images));
    self.image_count = count;
    self.image_frames = @splat(0);
    self.width = width;
    self.height = height;
    self.opaque_surface = opaque_surface;
    self.recreate = false;
    self.logModifier(count, format.format, composite);
}

fn logModifier(self: *VulkanPresenter, count: u32, format: vk.VkFormat, composite: vk.VkCompositeAlphaFlagBitsKHR) void {
    const r = self.renderer;
    var modifier: u64 = 0;
    if (r.drm_modifiers) {
        if (r.d.vkGetImageDrmFormatModifierPropertiesEXT) |get| {
            var props: vk.VkImageDrmFormatModifierPropertiesEXT = .{ .sType = vk.VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_PROPERTIES_EXT };
            if (get(r.device, self.images[0], &props) == vk.VK_SUCCESS) modifier = props.drmFormatModifier;
        }
    }
    log.info("swapchain {d}x{d}, {d} images, format {d}, alpha {d}, present mode {d}, modifier 0x{x:0>16}", .{
        self.width,
        self.height,
        count,
        format,
        composite,
        self.present_mode,
        modifier,
    });
}

/// Acquire the next swapchain image for a `width`×`height` frame, creating
/// or recreating the swapchain when needed.
pub fn acquire(self: *VulkanPresenter, width: u32, height: u32, opaque_surface: bool) !Acquired {
    const r = self.renderer;
    if (self.swapchain == null or self.recreate or self.width != width or self.height != height or
        self.opaque_surface != opaque_surface)
    {
        try self.createSwapchain(width, height, opaque_surface);
    }
    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        const slot = self.acquire_index % self.acquire_semaphores.len;
        // The semaphore is free once the copy that waited on it finished.
        try r.waitValue(self.acquire_values[slot]);
        var index: u32 = 0;
        const result = r.d.vkAcquireNextImageKHR(r.device, self.swapchain, std.math.maxInt(u64), self.acquire_semaphores[slot], null, &index);
        if (result == vk.VK_ERROR_OUT_OF_DATE_KHR and attempt == 0) {
            try self.createSwapchain(width, height, opaque_surface);
            continue;
        }
        try check(result);
        if (result == vk.VK_SUBOPTIMAL_KHR) self.recreate = true;
        self.acquire_index += 1;
        const last = self.image_frames[index];
        return .{ .index = index, .age = if (last == 0) 0 else @intCast(self.frames + 1 - last) };
    }
}

/// Copy `copy` (null: everything) from the latest canvas into the acquired
/// image, on the GPU. Follow with `present`.
pub fn copy(self: *VulkanPresenter, acquired: Acquired, rects_or_full: ?[]const Renderer.PixelRect) !void {
    const r = self.renderer;
    const d = &r.d;
    const index = acquired.index;
    const canvas = r.presentable();
    std.debug.assert(canvas.width == self.width and canvas.height == self.height);
    try r.waitValue(self.cmd_values[index]);
    const cmd = self.cmds[index];
    try check(d.vkResetCommandBuffer(cmd, 0));
    const begin: vk.VkCommandBufferBeginInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };
    try check(d.vkBeginCommandBuffer(cmd, &begin));
    const full = rects_or_full == null or acquired.age == 0;
    r.barrier(cmd, &.{.{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
        .srcStageMask = vk.VK_PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
        .srcAccessMask = 0,
        .dstStageMask = vk.VK_PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
        .dstAccessMask = vk.VK_ACCESS_2_TRANSFER_WRITE_BIT,
        .oldLayout = if (full) vk.VK_IMAGE_LAYOUT_UNDEFINED else vk.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
        .newLayout = vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
        .image = self.images[index],
        .subresourceRange = VulkanRenderer.color_range,
    }});
    var regions: [256]vk.VkImageCopy = undefined;
    var region_count: usize = 0;
    const whole: [1]Renderer.PixelRect = .{.{ .x = 0, .y = 0, .width = @intCast(self.width), .height = @intCast(self.height) }};
    const rects: []const Renderer.PixelRect = if (full) &whole else rects_or_full.?;
    for (rects) |rect| {
        if (region_count == regions.len) {
            d.vkCmdCopyImage(cmd, canvas.image, vk.VK_IMAGE_LAYOUT_GENERAL, self.images[index], vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, @intCast(region_count), &regions);
            region_count = 0;
        }
        regions[region_count] = .{
            .srcSubresource = VulkanRenderer.color_layers,
            .srcOffset = .{ .x = rect.x, .y = rect.y, .z = 0 },
            .dstSubresource = VulkanRenderer.color_layers,
            .dstOffset = .{ .x = rect.x, .y = rect.y, .z = 0 },
            .extent = .{ .width = rect.width, .height = rect.height, .depth = 1 },
        };
        region_count += 1;
    }
    if (region_count > 0) {
        d.vkCmdCopyImage(cmd, canvas.image, vk.VK_IMAGE_LAYOUT_GENERAL, self.images[index], vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, @intCast(region_count), &regions);
    }
    r.barrier(cmd, &.{.{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
        .srcStageMask = vk.VK_PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
        .srcAccessMask = vk.VK_ACCESS_2_TRANSFER_WRITE_BIT,
        .dstStageMask = vk.VK_PIPELINE_STAGE_2_NONE,
        .dstAccessMask = 0,
        .oldLayout = vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        .newLayout = vk.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
        .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
        .image = self.images[index],
        .subresourceRange = VulkanRenderer.color_range,
    }});
    try check(d.vkEndCommandBuffer(cmd));

    const acquire_slot = (self.acquire_index - 1) % self.acquire_semaphores.len;
    const waits = [_]vk.VkSemaphoreSubmitInfo{
        .{ .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO, .semaphore = self.acquire_semaphores[acquire_slot], .stageMask = vk.VK_PIPELINE_STAGE_2_ALL_TRANSFER_BIT },
        .{ .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO, .semaphore = r.timeline, .value = canvas.value, .stageMask = vk.VK_PIPELINE_STAGE_2_ALL_TRANSFER_BIT },
    };
    const value = try r.submit(cmd, waits[0..if (canvas.value != 0) 2 else 1], self.present_semaphores[index]);
    self.cmd_values[index] = value;
    self.acquire_values[acquire_slot] = value;
}

/// Present the acquired image, which `copy` filled, with `damage` (null:
/// everything) as the surface damage. This commits the surface. Returns
/// error.OutOfDate when the frame was not shown.
pub fn present(self: *VulkanPresenter, acquired: Acquired, damage: ?[]const Window.DamageRect) !void {
    const r = self.renderer;
    const d = &r.d;
    const index = acquired.index;

    var rect_storage: [256]vk.VkRectLayerKHR = undefined;
    var present_rects: []const vk.VkRectLayerKHR = &.{};
    if (damage) |damage_rects| {
        if (damage_rects.len <= rect_storage.len) {
            for (damage_rects, rect_storage[0..damage_rects.len]) |rect, *out| out.* = .{
                .offset = .{ .x = rect.x, .y = rect.y },
                .extent = .{ .width = rect.width, .height = rect.height },
                .layer = 0,
            };
            present_rects = rect_storage[0..damage_rects.len];
        }
    }
    const region: vk.VkPresentRegionKHR = .{ .rectangleCount = @intCast(present_rects.len), .pRectangles = present_rects.ptr };
    const regions_info: vk.VkPresentRegionsKHR = .{
        .sType = vk.VK_STRUCTURE_TYPE_PRESENT_REGIONS_KHR,
        .swapchainCount = 1,
        .pRegions = &region,
    };
    const info: vk.VkPresentInfoKHR = .{
        .sType = vk.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .pNext = if (r.incremental_present and present_rects.len > 0) &regions_info else null,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &self.present_semaphores[index],
        .swapchainCount = 1,
        .pSwapchains = &self.swapchain,
        .pImageIndices = &index,
    };
    r.lockQueue();
    const result = d.vkQueuePresentKHR(r.queue, &info);
    r.queue_mutex.unlock();
    switch (result) {
        vk.VK_SUCCESS => {},
        vk.VK_SUBOPTIMAL_KHR => self.recreate = true,
        vk.VK_ERROR_OUT_OF_DATE_KHR => {
            self.recreate = true;
            return error.OutOfDate;
        },
        else => try check(result),
    }
    self.frames += 1;
    self.image_frames[index] = self.frames;
}
