#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

typedef union {
    max_align_t alignment;
    size_t size;
} AllocationHeader;

static _Thread_local size_t allocation_limit = SIZE_MAX;
static _Thread_local size_t allocated_bytes;
static _Thread_local int allocation_status;

static void *image_realloc(void *ptr, size_t size) {
    AllocationHeader *old = ptr ? (AllocationHeader *)ptr - 1 : NULL;
    size_t old_size = old ? old->size : 0;
    if (size > SIZE_MAX - sizeof(AllocationHeader)) {
        if (allocation_limit != SIZE_MAX) allocation_status = 1;
        return NULL;
    }
    if (allocation_limit != SIZE_MAX && size > allocation_limit - (allocated_bytes - old_size)) {
        allocation_status = 1;
        return NULL;
    }
    AllocationHeader *header = realloc(old, sizeof(AllocationHeader) + size);
    if (!header) {
        if (allocation_limit != SIZE_MAX) allocation_status = 2;
        return NULL;
    }
    header->size = size;
    if (allocation_limit != SIZE_MAX) allocated_bytes = allocated_bytes - old_size + size;
    return header + 1;
}

static void image_free(void *ptr) {
    if (!ptr) return;
    AllocationHeader *header = (AllocationHeader *)ptr - 1;
    if (allocation_limit != SIZE_MAX) allocated_bytes -= header->size;
    free(header);
}

#define STBI_MALLOC(size) image_realloc(NULL, size)
#define STBI_REALLOC(ptr, size) image_realloc(ptr, size)
#define STBI_FREE(ptr) image_free(ptr)
#define STBI_ONLY_PNG
// Kitty's graphics protocol limits both image dimensions to 10,000 pixels.
#define STBI_MAX_DIMENSIONS 10000
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

unsigned char *monstar_load_drag_png(const unsigned char *data, int len, int *width, int *height, int *status) {
    // Dimensions don't bound stb's IDAT allocations or expandable inflate buffer.
    // Allow 16-bit intermediates for a 16 MiB preview, with bounded scratch space.
    allocation_limit = 80 * 1024 * 1024;
    allocated_bytes = 0;
    allocation_status = 0;
    unsigned char *pixels = stbi_load_from_memory(data, len, width, height, NULL, 4);
    *status = allocation_status;
    allocation_limit = SIZE_MAX;
    return pixels;
}
