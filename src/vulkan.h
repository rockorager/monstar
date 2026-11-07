// Vulkan types only: function pointers are resolved at runtime from a
// dlopen'd libvulkan, so the CPU renderer never loads the Vulkan loader.
#define VK_NO_PROTOTYPES
#define VK_USE_PLATFORM_WAYLAND_KHR
#include <vulkan/vulkan.h>
