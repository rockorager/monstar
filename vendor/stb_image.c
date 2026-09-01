#define STBI_ONLY_PNG
// Kitty's graphics protocol limits both image dimensions to 10,000 pixels.
#define STBI_MAX_DIMENSIONS 10000
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
