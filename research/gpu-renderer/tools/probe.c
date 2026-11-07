// Mirror Monstar's cell metrics and glyph rasterization for one font file and
// report glyphs whose rendered ink leaves the [baseline - ascender,
// baseline - descender) strip. usage: probe FONT PX [codepoint ranges...]
#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_MODULE_H
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    FT_Library lib; FT_Face face;
    if (FT_Init_FreeType(&lib)) return 1;
    FT_Bool no_dark = getenv("DARKEN") ? 0 : 1;
    FT_Property_Set(lib, "cff", "no-stem-darkening", &no_dark);
    if (FT_New_Face(lib, argv[1], 0, &face)) return 1;
    int px = atoi(argv[2]);
    FT_Set_Char_Size(face, 0, px * 64, 72, 72);
    FT_Size_Metrics m = face->size->metrics;
    int asc = (int)(m.ascender >> 6), height = (int)((m.ascender - m.descender) >> 6);
    printf("%s px=%d units/em=%d hhea asc=%d desc=%d | os2 typo %d/%d win %d/%d | size asc=%ld desc=%ld (26.6) cell_h=%d baseline=%d\n",
           face->family_name, px, face->units_per_EM, face->ascender, face->descender,
           0, 0, 0, 0, m.ascender, m.descender, height, asc);
    int lo = 32, hi = 126;
    if (argc > 3) { lo = (int)strtol(argv[3], 0, 0); hi = (int)strtol(argv[4], 0, 0); }
    int worst_up = 0, worst_down = 0, n_up = 0, n_down = 0;
    char up[4096] = "", down[4096] = "";
    for (int cp = lo; cp <= hi; cp++) {
        FT_UInt idx = FT_Get_Char_Index(face, cp);
        if (!idx) continue;
        if (FT_Load_Glyph(face, idx, FT_LOAD_NO_BITMAP | FT_LOAD_TARGET_LIGHT)) continue;
        if (FT_Render_Glyph(face->glyph, FT_RENDER_MODE_NORMAL)) continue;
        FT_Bitmap *b = &face->glyph->bitmap;
        if (!b->rows || !b->width) continue;
        int top = face->glyph->bitmap_top;            // rows above baseline
        int bottom = top - (int)b->rows;              // baseline-relative bottom
        int over_up = top - asc;                      // >0: ink above the strip
        int over_down = (asc - height) - bottom;      // >0: ink below the strip
        char buf[32];
        if (over_up > 0) {
            n_up++; if (over_up > worst_up) worst_up = over_up;
            snprintf(buf, sizeof buf, cp < 127 ? "%c(+%d) " : "U+%04X(+%d) ", cp, over_up);
            if (cp < 127) snprintf(buf, sizeof buf, "%c(+%d) ", cp, over_up);
            if (sizeof up - 40 > (size_t)snprintf(0, 0, "%s", up)) strcat(up, buf);
        }
        if (over_down > 0) {
            n_down++; if (over_down > worst_down) worst_down = over_down;
            if (cp < 127) snprintf(buf, sizeof buf, "%c(+%d) ", cp, over_down);
            else snprintf(buf, sizeof buf, "U+%04X(+%d) ", cp, over_down);
            if (sizeof down - 40 > (size_t)snprintf(0, 0, "%s", down)) strcat(down, buf);
        }
    }
    printf("  above strip: %d glyphs, worst %d px: %s\n", n_up, worst_up, up);
    printf("  below strip: %d glyphs, worst %d px: %s\n", n_down, worst_down, down);
    return 0;
}
