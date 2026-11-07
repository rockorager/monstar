// vkgrid: minimal Vulkan terminal-grid renderer used to measure what a GPU
// renderer would cost/save for Monstar. Not a terminal: it draws a cell grid
// (FreeType glyph atlas + one fullscreen fragment pass) on a Wayland surface
// through VK_KHR_wayland_surface.
//
// usage: vkgrid MODE [--font PATH] [--px N] [--overlap] [--full-damage]
//   MODE idle    draw once, then only on key presses (echo)
//        scroll  scroll one text row per frame, FIFO-paced (60 Hz)
//   --overlap      commit a CPU (wl_shm) first frame while Vulkan initializes
//                  on a thread, then switch the surface to the swapchain
//   --full-damage  do not pass VK_KHR_incremental_present rectangles
// Prints startup phase marks and a per-second CPU/GPU frame-time summary.
#define _GNU_SOURCE
#define VK_USE_PLATFORM_WAYLAND_KHR
#include <vulkan/vulkan.h>
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"
#include <ft2build.h>
#include FT_FREETYPE_H
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include "grid.vert.h"
#include "grid.frag.h"

#define CHECK(x) do { VkResult r_ = (x); if (r_ != VK_SUCCESS) { fprintf(stderr, "%s:%d %s = %d\n", __FILE__, __LINE__, #x, r_); exit(1); } } while (0)
#define MAXIMG 8

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + ts.tv_nsec;
}
static uint64_t t_start;
static void mark(const char *what) {
    fprintf(stderr, "mark %-24s %8.2f ms (mono %llu)\n", what, (now_ns() - t_start) / 1e6, (unsigned long long)now_ns());
}

// ---------------------------------------------------------------- Wayland
static struct wl_display *dpy;
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm_base;
static struct wl_seat *seat;
static struct wl_surface *surface;
static struct xdg_toplevel *toplevel;
static int win_w, win_h;
static bool configured, key_dirty, running = true;
static volatile int recreate_req;
#include <signal.h>
static void on_usr1(int sig) { (void)sig; recreate_req = 1; }
static uint64_t key_time;

static void wm_ping(void *d, struct xdg_wm_base *b, uint32_t s) { (void)d; xdg_wm_base_pong(b, s); }
static const struct xdg_wm_base_listener wm_listener = { wm_ping };
static void xs_configure(void *d, struct xdg_surface *s, uint32_t serial) { (void)d; xdg_surface_ack_configure(s, serial); configured = true; }
static const struct xdg_surface_listener xs_listener = { xs_configure };
static void tl_configure(void *d, struct xdg_toplevel *t, int32_t w, int32_t h, struct wl_array *st) {
    (void)d; (void)t; (void)st;
    if (w > 0 && h > 0) { win_w = w; win_h = h; }
}
static void tl_close(void *d, struct xdg_toplevel *t) { (void)d; (void)t; running = false; }
static void tl_bounds(void *d, struct xdg_toplevel *t, int32_t w, int32_t h) { (void)d; (void)t; (void)w; (void)h; }
static void tl_caps(void *d, struct xdg_toplevel *t, struct wl_array *c) { (void)d; (void)t; (void)c; }
static const struct xdg_toplevel_listener tl_listener = { tl_configure, tl_close, tl_bounds, tl_caps };

static void kb_keymap(void *d, struct wl_keyboard *k, uint32_t f, int32_t fd, uint32_t s) { (void)d; (void)k; (void)f; (void)s; close(fd); }
static void kb_enter(void *d, struct wl_keyboard *k, uint32_t s, struct wl_surface *sf, struct wl_array *a) { (void)d; (void)k; (void)s; (void)sf; (void)a; }
static void kb_leave(void *d, struct wl_keyboard *k, uint32_t s, struct wl_surface *sf) { (void)d; (void)k; (void)s; (void)sf; }
static void kb_key(void *d, struct wl_keyboard *k, uint32_t s, uint32_t t, uint32_t key, uint32_t state) {
    (void)d; (void)k; (void)s; (void)t; (void)key;
    if (state == WL_KEYBOARD_KEY_STATE_PRESSED) { key_dirty = true; key_time = now_ns(); }
}
static void kb_mods(void *d, struct wl_keyboard *k, uint32_t s, uint32_t a, uint32_t b, uint32_t c, uint32_t e) { (void)d; (void)k; (void)s; (void)a; (void)b; (void)c; (void)e; }
static void kb_repeat(void *d, struct wl_keyboard *k, int32_t r, int32_t de) { (void)d; (void)k; (void)r; (void)de; }
static const struct wl_keyboard_listener kb_listener = { kb_keymap, kb_enter, kb_leave, kb_key, kb_mods, kb_repeat };
static void seat_caps(void *d, struct wl_seat *s, uint32_t caps) {
    (void)d;
    static bool have;
    if ((caps & WL_SEAT_CAPABILITY_KEYBOARD) && !have) { have = true; wl_keyboard_add_listener(wl_seat_get_keyboard(s), &kb_listener, NULL); }
}
static void seat_name(void *d, struct wl_seat *s, const char *n) { (void)d; (void)s; (void)n; }
static const struct wl_seat_listener seat_listener = { seat_caps, seat_name };

static void reg_global(void *d, struct wl_registry *r, uint32_t name, const char *iface, uint32_t v) {
    (void)d; (void)v;
    if (!strcmp(iface, "wl_compositor")) compositor = wl_registry_bind(r, name, &wl_compositor_interface, 4);
    else if (!strcmp(iface, "wl_shm")) shm = wl_registry_bind(r, name, &wl_shm_interface, 1);
    else if (!strcmp(iface, "xdg_wm_base")) { wm_base = wl_registry_bind(r, name, &xdg_wm_base_interface, 1); xdg_wm_base_add_listener(wm_base, &wm_listener, NULL); }
    else if (!strcmp(iface, "wl_seat")) { seat = wl_registry_bind(r, name, &wl_seat_interface, 5); wl_seat_add_listener(seat, &seat_listener, NULL); }
}
static void reg_remove(void *d, struct wl_registry *r, uint32_t n) { (void)d; (void)r; (void)n; }
static const struct wl_registry_listener reg_listener = { reg_global, reg_remove };

// ---------------------------------------------------------------- grid data
typedef struct { uint32_t cols, rows, top, cw, ch, acols, bg_default, pad; } Header;
static FT_Face face;
static uint32_t cw, ch, acols = 16, arows = 6;
static uint8_t *atlas_px;
static char **lines; static size_t nlines, next_line;
static const uint32_t palette[] = { 0xd0d0d0, 0xe06c75, 0x98c379, 0xe5c07b, 0x61afef, 0xc678dd, 0x56b6c2, 0xdcdfe4, 0x808080 };
static const uint32_t BG = 0x282828;

static void load_font(const char *path, int px) {
    FT_Library lib;
    if (FT_Init_FreeType(&lib) || FT_New_Face(lib, path, 0, &face)) { fprintf(stderr, "font %s\n", path); exit(1); }
    FT_Set_Pixel_Sizes(face, 0, px);
    cw = (uint32_t)((face->size->metrics.max_advance + 63) >> 6);
    FT_Load_Char(face, 'M', FT_LOAD_DEFAULT);
    cw = (uint32_t)((face->glyph->advance.x + 63) >> 6);
    ch = (uint32_t)((face->size->metrics.height + 63) >> 6);
    int asc = (int)((face->size->metrics.ascender + 63) >> 6);
    atlas_px = calloc((size_t)acols * cw * arows * ch, 1);
    for (int c = 32; c < 127; c++) {
        if (FT_Load_Char(face, c, FT_LOAD_RENDER)) continue;
        FT_Bitmap *b = &face->glyph->bitmap;
        int g = c - 32, ox = (g % acols) * cw, oy = (g / acols) * ch;
        for (unsigned y = 0; y < b->rows; y++) for (unsigned x = 0; x < b->width; x++) {
            int px_ = face->glyph->bitmap_left + (int)x, py = asc - face->glyph->bitmap_top + (int)y;
            if (px_ < 0 || py < 0 || px_ >= (int)cw || py >= (int)ch) continue;
            atlas_px[(size_t)(oy + py) * acols * cw + ox + px_] = b->buffer[y * b->pitch + x];
        }
    }
}

static void load_text(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) { perror(path); exit(1); }
    size_t cap = 1024; lines = malloc(cap * sizeof *lines);
    char buf[8192];
    while (fgets(buf, sizeof buf, f)) {
        if (nlines == cap) lines = realloc(lines, (cap *= 2) * sizeof *lines);
        lines[nlines++] = strdup(buf);
    }
    fclose(f);
}

// Write one source line (with SGR color escapes) into a grid row.
static void fill_row(uint32_t (*cells)[2], uint32_t cols, const char *s) {
    uint32_t fg = palette[0], x = 0;
    for (const char *p = s; *p && *p != '\n' && x < cols; p++) {
        if (*p == 0x1b && p[1] == '[') {
            int n = atoi(p + 2);
            fg = n == 0 ? palette[0] : n == 2 || n == 90 ? palette[8] : (n >= 31 && n <= 37) ? palette[n - 30] : fg;
            while (*p && *p != 'm') p++;
            continue;
        }
        unsigned char c = (unsigned char)*p;
        uint32_t g = (c >= 32 && c < 127) ? c - 32 : 0;
        cells[x][0] = g | (fg << 8); cells[x][1] = BG; x++;
    }
    for (; x < cols; x++) { cells[x][0] = 0 | (palette[0] << 8); cells[x][1] = BG; }
}

// ---------------------------------------------------------------- Vulkan
static VkInstance inst; static VkPhysicalDevice phys; static VkDevice dev; static VkQueue queue;
static uint32_t qfam; static VkSurfaceKHR vsurf; static VkSwapchainKHR swapchain;
static VkFormat sc_format; static VkExtent2D extent; static uint32_t nimg;
static VkImage images[MAXIMG]; static VkImageView views[MAXIMG]; static VkFramebuffer fbs[MAXIMG];
static VkCommandBuffer cmds[MAXIMG]; static VkSemaphore render_done[MAXIMG];
static VkRenderPass rpass; static VkPipeline gpipe; static VkPipelineLayout playout;
static VkDescriptorSetLayout dsl; static VkDescriptorPool dpool; static VkDescriptorSet dset;
static VkCommandPool cpool; static VkBuffer cellbuf; static VkDeviceMemory cellmem; static void *cellmap;
static VkImage atlas_img; static VkImageView atlas_view; static VkSampler sampler; static VkDeviceMemory atlas_mem;
static VkQueryPool qpool; static VkSemaphore acquire_sem; static VkFence fence;
static float ts_period; static bool full_damage;
static Header *hdr; static uint32_t (*cells)[2];
static uint32_t grid_cols, grid_rows;

static uint32_t mem_type(uint32_t bits, VkMemoryPropertyFlags want) {
    VkPhysicalDeviceMemoryProperties mp; vkGetPhysicalDeviceMemoryProperties(phys, &mp);
    for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
        if ((bits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & want) == want) return i;
    fprintf(stderr, "no memory type\n"); exit(1);
}

static void vk_init_device(void) {
    const char *iext[] = { VK_KHR_SURFACE_EXTENSION_NAME, VK_KHR_WAYLAND_SURFACE_EXTENSION_NAME };
    VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_2, .pApplicationName = "vkgrid" };
    VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app, .enabledExtensionCount = 2, .ppEnabledExtensionNames = iext };
    CHECK(vkCreateInstance(&ici, NULL, &inst));
    mark("vkCreateInstance");
    uint32_t n = 1; VkPhysicalDevice pd[4]; n = 4;
    vkEnumeratePhysicalDevices(inst, &n, pd);
    phys = pd[0];
    VkPhysicalDeviceProperties props; vkGetPhysicalDeviceProperties(phys, &props);
    ts_period = props.limits.timestampPeriod;
    uint32_t nq = 8; VkQueueFamilyProperties qf[8];
    vkGetPhysicalDeviceQueueFamilyProperties(phys, &nq, qf);
    for (qfam = 0; qfam < nq && !(qf[qfam].queueFlags & VK_QUEUE_GRAPHICS_BIT); qfam++);
    mark("enumerate physical");
    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = qfam, .queueCount = 1, .pQueuePriorities = &prio };
    const char *dext[] = { VK_KHR_SWAPCHAIN_EXTENSION_NAME, VK_KHR_INCREMENTAL_PRESENT_EXTENSION_NAME };
    VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci, .enabledExtensionCount = 2, .ppEnabledExtensionNames = dext };
    CHECK(vkCreateDevice(phys, &dci, NULL, &dev));
    vkGetDeviceQueue(dev, qfam, 0, &queue);
    mark("vkCreateDevice");
}

static VkShaderModule shader(const uint32_t *code, size_t len) {
    VkShaderModuleCreateInfo ci = { .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = len, .pCode = code };
    VkShaderModule m; CHECK(vkCreateShaderModule(dev, &ci, NULL, &m)); return m;
}

// Everything that does not depend on the window size or swapchain.
static void vk_init_resources(void) {
    sc_format = VK_FORMAT_B8G8R8A8_UNORM;
    VkAttachmentDescription att = { .format = sc_format, .samples = 1, .loadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE, .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE, .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED, .finalLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR };
    VkAttachmentReference ref = { 0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
    VkSubpassDescription sub = { .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS, .colorAttachmentCount = 1, .pColorAttachments = &ref };
    VkSubpassDependency dep = { VK_SUBPASS_EXTERNAL, 0, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, 0, VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT, 0 };
    VkRenderPassCreateInfo rpci = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO, .attachmentCount = 1, .pAttachments = &att, .subpassCount = 1, .pSubpasses = &sub, .dependencyCount = 1, .pDependencies = &dep };
    CHECK(vkCreateRenderPass(dev, &rpci, NULL, &rpass));

    VkDescriptorSetLayoutBinding b[2] = {
        { 0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_FRAGMENT_BIT, NULL },
        { 1, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1, VK_SHADER_STAGE_FRAGMENT_BIT, NULL } };
    VkDescriptorSetLayoutCreateInfo dslci = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = 2, .pBindings = b };
    CHECK(vkCreateDescriptorSetLayout(dev, &dslci, NULL, &dsl));
    VkPipelineLayoutCreateInfo plci = { .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = 1, .pSetLayouts = &dsl };
    CHECK(vkCreatePipelineLayout(dev, &plci, NULL, &playout));

    VkShaderModule vs = shader(grid_vert, sizeof grid_vert), fs = shader(grid_frag, sizeof grid_frag);
    VkPipelineShaderStageCreateInfo st[2] = {
        { .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT, .module = vs, .pName = "main" },
        { .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = fs, .pName = "main" } };
    VkPipelineVertexInputStateCreateInfo vi = { .sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
    VkPipelineInputAssemblyStateCreateInfo ia = { .sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST };
    VkPipelineViewportStateCreateInfo vp = { .sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, .viewportCount = 1, .scissorCount = 1 };
    VkPipelineRasterizationStateCreateInfo rs = { .sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO, .cullMode = VK_CULL_MODE_NONE, .lineWidth = 1 };
    VkPipelineMultisampleStateCreateInfo ms = { .sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO, .rasterizationSamples = 1 };
    VkPipelineColorBlendAttachmentState cba = { .colorWriteMask = 0xf };
    VkPipelineColorBlendStateCreateInfo cb = { .sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, .attachmentCount = 1, .pAttachments = &cba };
    VkDynamicState dyn[2] = { VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR };
    VkPipelineDynamicStateCreateInfo ds = { .sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO, .dynamicStateCount = 2, .pDynamicStates = dyn };
    VkGraphicsPipelineCreateInfo gp = { .sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, .stageCount = 2, .pStages = st, .pVertexInputState = &vi,
        .pInputAssemblyState = &ia, .pViewportState = &vp, .pRasterizationState = &rs, .pMultisampleState = &ms, .pColorBlendState = &cb,
        .pDynamicState = &ds, .layout = playout, .renderPass = rpass };
    CHECK(vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &gp, NULL, &gpipe));
    mark("pipeline");

    VkCommandPoolCreateInfo cpci = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, .queueFamilyIndex = qfam };
    CHECK(vkCreateCommandPool(dev, &cpci, NULL, &cpool));

    // Atlas: staging buffer -> R8 image.
    uint32_t aw = acols * cw, ah = arows * ch;
    VkImageCreateInfo ii = { .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D, .format = VK_FORMAT_R8_UNORM,
        .extent = { aw, ah, 1 }, .mipLevels = 1, .arrayLayers = 1, .samples = 1, .tiling = VK_IMAGE_TILING_OPTIMAL,
        .usage = VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT };
    CHECK(vkCreateImage(dev, &ii, NULL, &atlas_img));
    VkMemoryRequirements mr; vkGetImageMemoryRequirements(dev, atlas_img, &mr);
    VkMemoryAllocateInfo mai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size, .memoryTypeIndex = mem_type(mr.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) };
    CHECK(vkAllocateMemory(dev, &mai, NULL, &atlas_mem)); vkBindImageMemory(dev, atlas_img, atlas_mem, 0);

    // Cell buffer, also used as the atlas staging source before the grid is laid out.
    size_t cellbytes = sizeof(Header) + 8 * 512 * 256 + (size_t)aw * ah;
    VkBufferCreateInfo bci = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = cellbytes, .usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_SRC_BIT };
    CHECK(vkCreateBuffer(dev, &bci, NULL, &cellbuf));
    vkGetBufferMemoryRequirements(dev, cellbuf, &mr);
    mai.allocationSize = mr.size;
    mai.memoryTypeIndex = mem_type(mr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT | VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    CHECK(vkAllocateMemory(dev, &mai, NULL, &cellmem)); vkBindBufferMemory(dev, cellbuf, cellmem, 0);
    CHECK(vkMapMemory(dev, cellmem, 0, VK_WHOLE_SIZE, 0, &cellmap));
    size_t staging_off = cellbytes - (size_t)aw * ah;
    memcpy((char *)cellmap + staging_off, atlas_px, (size_t)aw * ah);

    VkCommandBuffer c; VkCommandBufferAllocateInfo cai = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = cpool, .commandBufferCount = 1 };
    CHECK(vkAllocateCommandBuffers(dev, &cai, &c));
    VkCommandBufferBeginInfo cbi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
    vkBeginCommandBuffer(c, &cbi);
    VkImageMemoryBarrier ib = { .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
        .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = atlas_img, .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
    vkCmdPipelineBarrier(c, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &ib);
    VkBufferImageCopy reg = { .bufferOffset = staging_off, .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 }, .imageExtent = { aw, ah, 1 } };
    vkCmdCopyBufferToImage(c, cellbuf, atlas_img, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &reg);
    ib.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT; ib.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
    ib.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL; ib.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    vkCmdPipelineBarrier(c, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, NULL, 0, NULL, 1, &ib);
    vkEndCommandBuffer(c);
    VkSubmitInfo si = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &c };
    CHECK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
    CHECK(vkQueueWaitIdle(queue));

    VkImageViewCreateInfo vci = { .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = atlas_img, .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = VK_FORMAT_R8_UNORM,
        .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
    CHECK(vkCreateImageView(dev, &vci, NULL, &atlas_view));
    VkSamplerCreateInfo sci = { .sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO, .magFilter = VK_FILTER_NEAREST, .minFilter = VK_FILTER_NEAREST };
    CHECK(vkCreateSampler(dev, &sci, NULL, &sampler));
    VkDescriptorPoolSize ps[2] = { { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1 }, { VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1 } };
    VkDescriptorPoolCreateInfo dpci = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 1, .poolSizeCount = 2, .pPoolSizes = ps };
    CHECK(vkCreateDescriptorPool(dev, &dpci, NULL, &dpool));
    VkDescriptorSetAllocateInfo dsai = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = dpool, .descriptorSetCount = 1, .pSetLayouts = &dsl };
    CHECK(vkAllocateDescriptorSets(dev, &dsai, &dset));
    VkDescriptorBufferInfo dbi = { cellbuf, 0, staging_off };
    VkDescriptorImageInfo dii = { sampler, atlas_view, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
    VkWriteDescriptorSet w[2] = {
        { .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = dset, .dstBinding = 0, .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &dbi },
        { .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = dset, .dstBinding = 1, .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .pImageInfo = &dii } };
    vkUpdateDescriptorSets(dev, 2, w, 0, NULL);

    VkQueryPoolCreateInfo qpci = { .sType = VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO, .queryType = VK_QUERY_TYPE_TIMESTAMP, .queryCount = 2 * MAXIMG };
    CHECK(vkCreateQueryPool(dev, &qpci, NULL, &qpool));
    VkSemaphoreCreateInfo sem = { .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
    CHECK(vkCreateSemaphore(dev, &sem, NULL, &acquire_sem));
    VkFenceCreateInfo fci = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO, .flags = VK_FENCE_CREATE_SIGNALED_BIT };
    CHECK(vkCreateFence(dev, &fci, NULL, &fence));
    hdr = cellmap; cells = (void *)((char *)cellmap + sizeof(Header));
    mark("atlas+buffers");
}

static void vk_create_swapchain(void) {
    VkSurfaceCapabilitiesKHR caps;
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR(phys, vsurf, &caps);
    extent = (VkExtent2D){ (uint32_t)win_w, (uint32_t)win_h };
    VkSwapchainCreateInfoKHR sci = { .sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR, .surface = vsurf, .minImageCount = caps.minImageCount < 3 ? 3 : caps.minImageCount,
        .imageFormat = sc_format, .imageColorSpace = VK_COLOR_SPACE_SRGB_NONLINEAR_KHR, .imageExtent = extent, .imageArrayLayers = 1,
        .imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT, .preTransform = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR,
        .compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR, .presentMode = VK_PRESENT_MODE_FIFO_KHR, .clipped = VK_TRUE, .oldSwapchain = swapchain };
    VkSwapchainKHR old = swapchain;
    CHECK(vkCreateSwapchainKHR(dev, &sci, NULL, &swapchain));
    if (old) {
        vkDeviceWaitIdle(dev);
        for (uint32_t i = 0; i < nimg; i++) { vkDestroyFramebuffer(dev, fbs[i], NULL); vkDestroyImageView(dev, views[i], NULL); vkDestroySemaphore(dev, render_done[i], NULL); }
        vkFreeCommandBuffers(dev, cpool, nimg, cmds);
        vkDestroySwapchainKHR(dev, old, NULL);
    }
    nimg = MAXIMG; vkGetSwapchainImagesKHR(dev, swapchain, &nimg, images);
    VkCommandBufferAllocateInfo cai = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = cpool, .commandBufferCount = nimg };
    CHECK(vkAllocateCommandBuffers(dev, &cai, cmds));
    for (uint32_t i = 0; i < nimg; i++) {
        VkImageViewCreateInfo vci = { .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = images[i], .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = sc_format,
            .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
        CHECK(vkCreateImageView(dev, &vci, NULL, &views[i]));
        VkFramebufferCreateInfo fci = { .sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO, .renderPass = rpass, .attachmentCount = 1, .pAttachments = &views[i],
            .width = extent.width, .height = extent.height, .layers = 1 };
        CHECK(vkCreateFramebuffer(dev, &fci, NULL, &fbs[i]));
        VkSemaphoreCreateInfo sem = { .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
        CHECK(vkCreateSemaphore(dev, &sem, NULL, &render_done[i]));
        // Static command buffers: all per-frame state lives in the cell buffer.
        VkCommandBufferBeginInfo cbi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
        VkCommandBuffer c = cmds[i];
        vkBeginCommandBuffer(c, &cbi);
        vkCmdResetQueryPool(c, qpool, 2 * i, 2);
        vkCmdWriteTimestamp(c, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, qpool, 2 * i);
        VkRenderPassBeginInfo rbi = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO, .renderPass = rpass, .framebuffer = fbs[i], .renderArea = { { 0, 0 }, extent } };
        vkCmdBeginRenderPass(c, &rbi, VK_SUBPASS_CONTENTS_INLINE);
        vkCmdBindPipeline(c, VK_PIPELINE_BIND_POINT_GRAPHICS, gpipe);
        vkCmdBindDescriptorSets(c, VK_PIPELINE_BIND_POINT_GRAPHICS, playout, 0, 1, &dset, 0, NULL);
        VkViewport v = { 0, 0, (float)extent.width, (float)extent.height, 0, 1 };
        VkRect2D sc = { { 0, 0 }, extent };
        vkCmdSetViewport(c, 0, 1, &v); vkCmdSetScissor(c, 0, 1, &sc);
        vkCmdDraw(c, 3, 1, 0, 0);
        vkCmdEndRenderPass(c);
        vkCmdWriteTimestamp(c, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, qpool, 2 * i + 1);
        vkEndCommandBuffer(c);
    }
    grid_cols = extent.width / cw; grid_rows = extent.height / ch;
    if (grid_cols > 512) grid_cols = 512;
    if (grid_rows > 256) grid_rows = 256;
    *hdr = (Header){ grid_cols, grid_rows, 0, cw, ch, acols, BG, 0 };
    for (uint32_t r = 0; r < grid_rows; r++) fill_row(&cells[r * grid_cols], grid_cols, lines[next_line++ % nlines]);
}

// ---------------------------------------------------------------- frame loop
static double gpu_ms_sum, cpu_ms_sum, gpu_ms_max, cpu_ms_max; static int nframes_stat;
static uint64_t frames_total, stat_t0;
static int last_img = -1;

static void draw(int damage_row) {
    uint64_t t0 = now_ns();
    CHECK(vkWaitForFences(dev, 1, &fence, VK_TRUE, UINT64_MAX));
    if (recreate_req || (uint32_t)win_w != extent.width || (uint32_t)win_h != extent.height) { recreate_req = 0; fprintf(stderr, "recreate swapchain\n"); vk_create_swapchain(); damage_row = -1; last_img = -1; }
    if (last_img >= 0) {
        uint64_t ts[2];
        if (vkGetQueryPoolResults(dev, qpool, 2 * last_img, 2, sizeof ts, ts, 8, VK_QUERY_RESULT_64_BIT) == VK_SUCCESS) {
            double g = (ts[1] - ts[0]) * ts_period / 1e6;
            gpu_ms_sum += g; if (g > gpu_ms_max) gpu_ms_max = g;
        }
    }
    uint32_t idx;
    VkResult r = vkAcquireNextImageKHR(dev, swapchain, UINT64_MAX, acquire_sem, VK_NULL_HANDLE, &idx);
    if (r == VK_ERROR_OUT_OF_DATE_KHR) { vk_create_swapchain(); return; }
    uint64_t t1 = now_ns();
    vkResetFences(dev, 1, &fence);
    VkPipelineStageFlags ws = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    VkSubmitInfo si = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .waitSemaphoreCount = 1, .pWaitSemaphores = &acquire_sem, .pWaitDstStageMask = &ws,
        .commandBufferCount = 1, .pCommandBuffers = &cmds[idx], .signalSemaphoreCount = 1, .pSignalSemaphores = &render_done[idx] };
    CHECK(vkQueueSubmit(queue, 1, &si, fence));
    VkRectLayerKHR rect = { { 0, damage_row < 0 ? 0 : damage_row * (int)ch }, { extent.width, damage_row < 0 ? extent.height : ch }, 0 };
    VkPresentRegionKHR reg = { 1, &rect };
    VkPresentRegionsKHR regs = { .sType = VK_STRUCTURE_TYPE_PRESENT_REGIONS_KHR, .swapchainCount = 1, .pRegions = &reg };
    VkPresentInfoKHR pi = { .sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR, .pNext = full_damage ? NULL : &regs, .waitSemaphoreCount = 1, .pWaitSemaphores = &render_done[idx],
        .swapchainCount = 1, .pSwapchains = &swapchain, .pImageIndices = &idx };
    r = vkQueuePresentKHR(queue, &pi);
    uint64_t t2 = now_ns();
    if (r == VK_SUBOPTIMAL_KHR || r == VK_ERROR_OUT_OF_DATE_KHR) { fprintf(stderr, "swapchain suboptimal: recreate\n"); vk_create_swapchain(); }
    last_img = (int)idx;
    // Wall time from acquire to present return; FIFO pacing blocks inside
    // present, so process CPU must come from /proc, not from this number.
    (void)t0;
    double cpu = (t2 - t1) / 1e6;
    cpu_ms_sum += cpu; if (cpu > cpu_ms_max) cpu_ms_max = cpu;
    nframes_stat++; frames_total++;
    if (frames_total == 1) mark("first present queued");
    if (t2 - stat_t0 > 1000000000ull) {
        fprintf(stderr, "stat frames=%d acquire->present-return wall avg %.3f max %.3f ms | gpu avg %.3f max %.3f ms\n", nframes_stat,
                cpu_ms_sum / nframes_stat, cpu_ms_max, gpu_ms_sum / nframes_stat, gpu_ms_max);
        gpu_ms_sum = cpu_ms_sum = gpu_ms_max = cpu_ms_max = 0; nframes_stat = 0; stat_t0 = t2;
    }
}

static volatile int vk_ready;
static void *vk_thread(void *arg) { (void)arg; vk_init_device(); vk_init_resources(); __atomic_store_n(&vk_ready, 1, __ATOMIC_RELEASE); return NULL; }

// CPU first frame through wl_shm (stands in for Monstar's CPU renderer).
static void shm_first_frame(void) {
    int w = win_w, h = win_h, stride = w * 4; size_t size = (size_t)stride * h;
    int fd = memfd_create("vkgrid-shm", MFD_CLOEXEC);
    if (ftruncate(fd, (off_t)size) < 0) exit(1);
    uint32_t *px = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    for (size_t i = 0; i < size / 4; i++) px[i] = BG;
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int)size);
    struct wl_buffer *buf = wl_shm_pool_create_buffer(pool, 0, w, h, stride, WL_SHM_FORMAT_XRGB8888);
    wl_surface_attach(surface, buf, 0, 0);
    wl_surface_damage_buffer(surface, 0, 0, w, h);
    wl_surface_commit(surface);
    wl_display_flush(dpy);
}

int main(int argc, char **argv) {
    t_start = now_ns();
    const char *mode = argc > 1 ? argv[1] : "idle";
    const char *font = "/usr/share/fonts/Adwaita/AdwaitaMono-Regular.ttf";
    int px = 16; bool overlap = false;
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "--font")) font = argv[++i];
        else if (!strcmp(argv[i], "--px")) px = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--overlap")) overlap = true;
        else if (!strcmp(argv[i], "--full-damage")) full_damage = true;
    }
    mark("main");
    signal(SIGUSR1, on_usr1);
    pthread_t th;
    if (overlap) pthread_create(&th, NULL, vk_thread, NULL);
    load_font(font, px);
    load_text("/root/projects/monstar-vk-eval/text-short.txt");
    mark("font+text");

    dpy = wl_display_connect(NULL);
    if (!dpy) { fprintf(stderr, "no wayland\n"); return 1; }
    wl_registry_add_listener(wl_display_get_registry(dpy), &reg_listener, NULL);
    wl_display_roundtrip(dpy);
    surface = wl_compositor_create_surface(compositor);
    struct xdg_surface *xs = xdg_wm_base_get_xdg_surface(wm_base, surface);
    xdg_surface_add_listener(xs, &xs_listener, NULL);
    toplevel = xdg_surface_get_toplevel(xs);
    xdg_toplevel_add_listener(toplevel, &tl_listener, NULL);
    xdg_toplevel_set_app_id(toplevel, "vkgrid");
    wl_surface_commit(surface);
    while (!configured) wl_display_dispatch(dpy);
    if (!win_w) { win_w = 1280; win_h = 720; }
    mark("wayland configured");
    if (overlap) {
        // Keep answering configures with CPU frames until Vulkan is ready.
        int shm_w = win_w, shm_h = win_h;
        shm_first_frame();
        mark("shm first frame committed");
        struct pollfd pfd = { wl_display_get_fd(dpy), POLLIN, 0 };
        while (!__atomic_load_n(&vk_ready, __ATOMIC_ACQUIRE)) {
            while (wl_display_prepare_read(dpy) != 0) wl_display_dispatch_pending(dpy);
            wl_display_flush(dpy);
            if (poll(&pfd, 1, 1) > 0) wl_display_read_events(dpy); else wl_display_cancel_read(dpy);
            wl_display_dispatch_pending(dpy);
            if (win_w != shm_w || win_h != shm_h) { shm_w = win_w; shm_h = win_h; shm_first_frame(); mark("shm resized frame committed"); }
        }
        pthread_join(th, NULL);
        mark("vulkan thread joined");
    }
    else { vk_init_device(); vk_init_resources(); }

    VkWaylandSurfaceCreateInfoKHR wci = { .sType = VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR, .display = dpy, .surface = surface };
    CHECK(vkCreateWaylandSurfaceKHR(inst, &wci, NULL, &vsurf));
    VkBool32 ok; vkGetPhysicalDeviceSurfaceSupportKHR(phys, qfam, vsurf, &ok);
    vk_create_swapchain();
    mark("swapchain");
    stat_t0 = now_ns();
    draw(-1);
    CHECK(vkQueueWaitIdle(queue));
    mark("first frame GPU done");

    bool scroll = !strcmp(mode, "scroll");
    while (running) {
        if (scroll) {
            // Scroll by one row: GPU redraws everything, CPU writes one row.
            hdr->top = (hdr->top + 1) % grid_rows;
            uint32_t r = (hdr->top + grid_rows - 1) % grid_rows;
            fill_row(&cells[r * grid_cols], grid_cols, lines[next_line++ % nlines]);
            draw(-1);
            wl_display_dispatch_pending(dpy);
        } else {
            if (wl_display_dispatch(dpy) < 0) break;
            if ((uint32_t)win_w != extent.width || (uint32_t)win_h != extent.height) draw(-1);
            if (key_dirty) {
                key_dirty = false;
                // Echo: toggle a glyph at a fixed cursor cell on the last row.
                uint32_t row = grid_rows - 1, cell = ((hdr->top + row) % grid_rows) * grid_cols + 2;
                cells[cell][0] = ((cells[cell][0] & 0xff) == ('a' - 32) ? 0 : ('a' - 32)) | (palette[0] << 8);
                draw((int)row);
                fprintf(stderr, "echo key->present %.3f ms\n", (now_ns() - key_time) / 1e6);
            }
        }
    }
    return 0;
}
