//! Vulkan entry points resolved at runtime from a dlopen'd libvulkan.
//!
//! Monstar does not link the Vulkan loader: the CPU renderer is the default,
//! and loading libvulkan plus a driver costs tens of milliseconds at startup.
//! Every function the backend calls is listed here and resolved once.

const VulkanDispatch = @This();

const std = @import("std");
const vk = @import("vk");

fn Fn(comptime name: []const u8) type {
    return @typeInfo(@field(vk, "PFN_" ++ name)).optional.child;
}

lib: std.DynLib,
vkGetInstanceProcAddr: Fn("vkGetInstanceProcAddr"),

// Global.
vkCreateInstance: Fn("vkCreateInstance") = undefined,
vkEnumerateInstanceLayerProperties: Fn("vkEnumerateInstanceLayerProperties") = undefined,

// Instance.
vkDestroyInstance: Fn("vkDestroyInstance") = undefined,
vkEnumeratePhysicalDevices: Fn("vkEnumeratePhysicalDevices") = undefined,
vkGetPhysicalDeviceProperties: Fn("vkGetPhysicalDeviceProperties") = undefined,
vkGetPhysicalDeviceFeatures2: Fn("vkGetPhysicalDeviceFeatures2") = undefined,
vkGetPhysicalDeviceQueueFamilyProperties: Fn("vkGetPhysicalDeviceQueueFamilyProperties") = undefined,
vkGetPhysicalDeviceMemoryProperties: Fn("vkGetPhysicalDeviceMemoryProperties") = undefined,
vkEnumerateDeviceExtensionProperties: Fn("vkEnumerateDeviceExtensionProperties") = undefined,
vkCreateDevice: Fn("vkCreateDevice") = undefined,
vkGetDeviceProcAddr: Fn("vkGetDeviceProcAddr") = undefined,
vkCreateWaylandSurfaceKHR: Fn("vkCreateWaylandSurfaceKHR") = undefined,
vkGetPhysicalDeviceWaylandPresentationSupportKHR: Fn("vkGetPhysicalDeviceWaylandPresentationSupportKHR") = undefined,
vkDestroySurfaceKHR: Fn("vkDestroySurfaceKHR") = undefined,
vkGetPhysicalDeviceSurfaceSupportKHR: Fn("vkGetPhysicalDeviceSurfaceSupportKHR") = undefined,
vkGetPhysicalDeviceSurfaceCapabilitiesKHR: Fn("vkGetPhysicalDeviceSurfaceCapabilitiesKHR") = undefined,
vkGetPhysicalDeviceSurfaceFormatsKHR: Fn("vkGetPhysicalDeviceSurfaceFormatsKHR") = undefined,
vkGetPhysicalDeviceSurfacePresentModesKHR: Fn("vkGetPhysicalDeviceSurfacePresentModesKHR") = undefined,

// Device.
vkDestroyDevice: Fn("vkDestroyDevice") = undefined,
vkGetDeviceQueue: Fn("vkGetDeviceQueue") = undefined,
vkDeviceWaitIdle: Fn("vkDeviceWaitIdle") = undefined,
vkCreateCommandPool: Fn("vkCreateCommandPool") = undefined,
vkDestroyCommandPool: Fn("vkDestroyCommandPool") = undefined,
vkAllocateCommandBuffers: Fn("vkAllocateCommandBuffers") = undefined,
vkResetCommandBuffer: Fn("vkResetCommandBuffer") = undefined,
vkBeginCommandBuffer: Fn("vkBeginCommandBuffer") = undefined,
vkEndCommandBuffer: Fn("vkEndCommandBuffer") = undefined,
vkQueueSubmit2: Fn("vkQueueSubmit2") = undefined,
vkCreateSemaphore: Fn("vkCreateSemaphore") = undefined,
vkDestroySemaphore: Fn("vkDestroySemaphore") = undefined,
vkWaitSemaphores: Fn("vkWaitSemaphores") = undefined,
vkCreateBuffer: Fn("vkCreateBuffer") = undefined,
vkDestroyBuffer: Fn("vkDestroyBuffer") = undefined,
vkGetBufferMemoryRequirements: Fn("vkGetBufferMemoryRequirements") = undefined,
vkAllocateMemory: Fn("vkAllocateMemory") = undefined,
vkFreeMemory: Fn("vkFreeMemory") = undefined,
vkBindBufferMemory: Fn("vkBindBufferMemory") = undefined,
vkBindImageMemory: Fn("vkBindImageMemory") = undefined,
vkMapMemory: Fn("vkMapMemory") = undefined,
vkCreateImage: Fn("vkCreateImage") = undefined,
vkDestroyImage: Fn("vkDestroyImage") = undefined,
vkGetImageMemoryRequirements: Fn("vkGetImageMemoryRequirements") = undefined,
vkCreateImageView: Fn("vkCreateImageView") = undefined,
vkDestroyImageView: Fn("vkDestroyImageView") = undefined,
vkCreateSampler: Fn("vkCreateSampler") = undefined,
vkDestroySampler: Fn("vkDestroySampler") = undefined,
vkCreateDescriptorSetLayout: Fn("vkCreateDescriptorSetLayout") = undefined,
vkDestroyDescriptorSetLayout: Fn("vkDestroyDescriptorSetLayout") = undefined,
vkCreateDescriptorPool: Fn("vkCreateDescriptorPool") = undefined,
vkDestroyDescriptorPool: Fn("vkDestroyDescriptorPool") = undefined,
vkAllocateDescriptorSets: Fn("vkAllocateDescriptorSets") = undefined,
vkUpdateDescriptorSets: Fn("vkUpdateDescriptorSets") = undefined,
vkCreatePipelineLayout: Fn("vkCreatePipelineLayout") = undefined,
vkDestroyPipelineLayout: Fn("vkDestroyPipelineLayout") = undefined,
vkCreateShaderModule: Fn("vkCreateShaderModule") = undefined,
vkDestroyShaderModule: Fn("vkDestroyShaderModule") = undefined,
vkCreateGraphicsPipelines: Fn("vkCreateGraphicsPipelines") = undefined,
vkDestroyPipeline: Fn("vkDestroyPipeline") = undefined,
vkCreateQueryPool: Fn("vkCreateQueryPool") = undefined,
vkDestroyQueryPool: Fn("vkDestroyQueryPool") = undefined,
vkGetQueryPoolResults: Fn("vkGetQueryPoolResults") = undefined,
vkCmdResetQueryPool: Fn("vkCmdResetQueryPool") = undefined,
vkCmdWriteTimestamp2: Fn("vkCmdWriteTimestamp2") = undefined,
vkCmdPipelineBarrier2: Fn("vkCmdPipelineBarrier2") = undefined,
vkCmdCopyImage: Fn("vkCmdCopyImage") = undefined,
vkCmdCopyBufferToImage: Fn("vkCmdCopyBufferToImage") = undefined,
vkCmdCopyImageToBuffer: Fn("vkCmdCopyImageToBuffer") = undefined,
vkCmdBeginRendering: Fn("vkCmdBeginRendering") = undefined,
vkCmdEndRendering: Fn("vkCmdEndRendering") = undefined,
vkCmdBindPipeline: Fn("vkCmdBindPipeline") = undefined,
vkCmdBindDescriptorSets: Fn("vkCmdBindDescriptorSets") = undefined,
vkCmdPushConstants: Fn("vkCmdPushConstants") = undefined,
vkCmdSetViewport: Fn("vkCmdSetViewport") = undefined,
vkCmdSetScissor: Fn("vkCmdSetScissor") = undefined,
vkCmdDraw: Fn("vkCmdDraw") = undefined,
vkCreateSwapchainKHR: Fn("vkCreateSwapchainKHR") = undefined,
vkDestroySwapchainKHR: Fn("vkDestroySwapchainKHR") = undefined,
vkGetSwapchainImagesKHR: Fn("vkGetSwapchainImagesKHR") = undefined,
vkAcquireNextImageKHR: Fn("vkAcquireNextImageKHR") = undefined,
vkQueuePresentKHR: Fn("vkQueuePresentKHR") = undefined,
/// VK_EXT_image_drm_format_modifier, used only to log swapchain modifiers.
vkGetImageDrmFormatModifierPropertiesEXT: @field(vk, "PFN_vkGetImageDrmFormatModifierPropertiesEXT") = null,

const global_names = [_][]const u8{ "vkCreateInstance", "vkEnumerateInstanceLayerProperties" };

pub fn open() !VulkanDispatch {
    var lib = std.DynLib.open("libvulkan.so.1") catch return error.VulkanUnavailable;
    errdefer lib.close();
    const get = lib.lookup(Fn("vkGetInstanceProcAddr"), "vkGetInstanceProcAddr") orelse
        return error.VulkanUnavailable;
    var self: VulkanDispatch = .{ .lib = lib, .vkGetInstanceProcAddr = get };
    inline for (global_names) |name| {
        @field(self, name) = @ptrCast(get(null, name ++ "") orelse return error.VulkanUnavailable);
    }
    return self;
}

/// Resolve every non-global entry point through `instance`; device-level
/// functions are re-resolved by `loadDevice` to skip the loader trampolines.
pub fn loadInstance(self: *VulkanDispatch, instance: vk.VkInstance) !void {
    const info = @typeInfo(VulkanDispatch).@"struct";
    inline for (info.field_names, info.field_types) |name, T| {
        comptime if (isSkipped(name)) continue;
        const proc = self.vkGetInstanceProcAddr(instance, name);
        if (@typeInfo(T) == .optional) {
            @field(self, name) = @ptrCast(proc);
        } else {
            @field(self, name) = @ptrCast(proc orelse {
                std.log.scoped(.vulkan).warn("missing Vulkan entry point {s}", .{name});
                return error.VulkanFunctionMissing;
            });
        }
    }
}

pub fn loadDevice(self: *VulkanDispatch, device: vk.VkDevice) void {
    inline for (@typeInfo(VulkanDispatch).@"struct".field_names) |name| {
        comptime if (isSkipped(name)) continue;
        if (self.vkGetDeviceProcAddr(device, name)) |proc| {
            @field(self, name) = @ptrCast(proc);
        }
    }
}

fn isSkipped(comptime name: []const u8) bool {
    if (std.mem.eql(u8, name, "lib") or std.mem.eql(u8, name, "vkGetInstanceProcAddr")) return true;
    for (global_names) |global| if (std.mem.eql(u8, name, global)) return true;
    return false;
}

pub fn close(self: *VulkanDispatch) void {
    self.lib.close();
}

/// Map a VkResult to an error, keeping success codes such as
/// VK_SUBOPTIMAL_KHR for callers that inspect them.
pub fn check(result: vk.VkResult) !void {
    if (result >= 0) return;
    return switch (result) {
        vk.VK_ERROR_OUT_OF_HOST_MEMORY => error.OutOfMemory,
        vk.VK_ERROR_OUT_OF_DEVICE_MEMORY => error.OutOfDeviceMemory,
        vk.VK_ERROR_DEVICE_LOST => error.DeviceLost,
        vk.VK_ERROR_SURFACE_LOST_KHR => error.SurfaceLost,
        vk.VK_ERROR_OUT_OF_DATE_KHR => error.OutOfDate,
        vk.VK_ERROR_EXTENSION_NOT_PRESENT => error.ExtensionNotPresent,
        vk.VK_ERROR_FEATURE_NOT_PRESENT => error.FeatureNotPresent,
        vk.VK_ERROR_INITIALIZATION_FAILED => error.InitializationFailed,
        vk.VK_ERROR_INCOMPATIBLE_DRIVER => error.IncompatibleDriver,
        else => error.VulkanFailed,
    };
}
