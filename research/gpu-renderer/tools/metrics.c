#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_TRUETYPE_TABLES_H
#include FT_MODULE_H
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    FT_Library lib; FT_Face f; FT_Init_FreeType(&lib);
    FT_Bool no_dark = 0; FT_Property_Set(lib, "cff", "no-stem-darkening", &no_dark);
    FT_New_Face(lib, argv[1], 0, &f);
    TT_OS2 *os2 = FT_Get_Sfnt_Table(f, FT_SFNT_OS2); TT_HoriHeader *hh = FT_Get_Sfnt_Table(f, FT_SFNT_HHEA);
    printf("%s upem=%d hhea %d/%d gap %d typo %d/%d gap %d win %d/%d capH %d xH %d bbox yMax %ld yMin %ld useTypo=%d\n", f->family_name, f->units_per_EM,
        hh->Ascender, hh->Descender, hh->Line_Gap, os2->sTypoAscender, os2->sTypoDescender, os2->sTypoLineGap, os2->usWinAscent, os2->usWinDescent,
        os2->version >= 2 ? os2->sCapHeight : -1, os2->version >= 2 ? os2->sxHeight : -1, f->bbox.yMax, f->bbox.yMin, (os2->fsSelection >> 7) & 1);
    const char *chars = argc > 2 ? argv[2] : "il14j|(dbM";
    FT_Set_Char_Size(f, 0, 16 * 64, 72, 72);
    int asc = f->size->metrics.ascender >> 6;
    for (const char *p = chars; *p; p++) {
        FT_Load_Char(f, *p, FT_LOAD_NO_SCALE);
        long ymax = f->glyph->metrics.horiBearingY;
        FT_Load_Char(f, *p, FT_LOAD_NO_BITMAP | FT_LOAD_TARGET_LIGHT); FT_Render_Glyph(f->glyph, FT_RENDER_MODE_NORMAL);
        FT_Bitmap *b = &f->glyph->bitmap; int top = f->glyph->bitmap_top, over = top - asc, mx = 0;
        for (int r = 0; r < over && r < (int)b->rows; r++) for (unsigned x = 0; x < b->width; x++) if (b->buffer[r * b->pitch + x] > mx) mx = b->buffer[r * b->pitch + x];
        printf("  '%c' yMax=%ld units  16px top=%d asc=%d over=%d max-alpha-in-overhang=%d\n", *p, ymax, top, asc, over, mx);
    }
}
