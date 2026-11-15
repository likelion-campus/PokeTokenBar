#ifndef CPLAZAD2D_TEXT_API_H
#define CPLAZAD2D_TEXT_API_H

/*
 * The plaza's DirectWrite text engine (stage 6, Task 9). Included by CPlazaD2D.h; the same rules apply (HRESULT-like ints,
 * ptb_plaza_last_error, no COM pointer handed out, any thread). Swift owns the rules (line breaking, frames, truncation:
 * PlazaLineBreaker, PlazaTextFrame); this measures and draws.
 *
 * Fonts by number: 0 Galmuri11, 1 Galmuri14, 2 Pretendard (weights 400, 600, 700), 3 Segoe UI Emoji (the system's).
 * The bundled files form a private collection (nothing is installed). A font whose file is missing is replaced by Malgun
 * Gothic from the system (ptb_text_font_info reports found = 0). Characters a font lacks fall back to Segoe UI Emoji for the
 * emoji ranges, then to the system fallback (locale ko-KR).
 * Metrics are the font's hhea ascender / descender / line gap scaled as CoreText scales them (unitsPerEm ratio rounded to
 * 16.16), descent and leading positive. Measuring mode: 0 natural (the plaza's), 1 GDI classic, 2 GDI natural.
 */

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct PTBCanvas; /* CPlazaD2D.h's canvas */
typedef struct PTBTextEngine PTBTextEngine;
typedef struct PTBTextLine PTBTextLine;

typedef struct {
    uint32_t start, length; /* UTF-16 range of the line's text */
    int32_t font;           /* 0 Galmuri11, 1 Galmuri14, 2 Pretendard, 3 Segoe UI Emoji */
    int32_t weight;         /* 400, 600, 700 */
    double size;            /* points */
    int32_t ownColor;       /* 1: r, g, b, a is the run's colour; 0: the canvas's fill (stroke) colour */
    double r, g, b, a;      /* straight sRGB */
} PTBTextRun;

typedef struct {
    double width;           /* sum of the cluster advances, trailing white space included */
    double ascent, descent, leading;   /* the largest of the fonts that drew it (0 for an empty line) */
    uint32_t clusters, glyphRuns, colorRuns, pieces;
    int32_t captureCode;    /* not 0 when a colour glyph run could not be split (it is drawn plain) */
} PTBTextLineInfo;

/* flags: 1 white space, 2 newline, 4 a line may wrap after it, 8 soft hyphen, 16 right-to-left */
typedef struct {
    float width;
    uint32_t length;
    uint32_t flags;
} PTBTextCluster;

typedef struct {
    int32_t found;          /* 1: the bundled font; 0: the system font that stands in for a missing file */
    int32_t weight;
    uint32_t unitsPerEm;
    int32_t hheaAscender, hheaDescender, hheaLineGap;
    int32_t dwAscent, dwDescent, dwLineGap;      /* DirectWrite's own metrics (DWRITE_FONT_METRICS), design units */
    double ascent, descent, leading;             /* what the engine uses at `size` (CoreText's scaling of hhea) */
} PTBFontInfo;

int ptb_text_engine_create(int measuringMode, PTBTextEngine **out);
int ptb_text_engine_add_font(PTBTextEngine *e, const uint16_t *path);   /* before finish; UTF-16, NUL-terminated */
int ptb_text_engine_finish(PTBTextEngine *e);
void ptb_text_engine_release(PTBTextEngine *e);
/* family and face receive NUL-terminated UTF-16 names (cap units each) */
int ptb_text_font_info(PTBTextEngine *e, int font, int weight, double size, PTBFontInfo *out, uint16_t *family, uint32_t familyCap,
                       uint16_t *face, uint32_t faceCap);
/* *exists = whether the private (system = 0) or the system (system = 1) collection has a family of that name */
int ptb_text_has_family(PTBTextEngine *e, int system, const uint16_t *name, int *exists);

int ptb_text_line_create(PTBTextEngine *e, const uint16_t *utf16, uint32_t length, const PTBTextRun *runs, uint32_t runCount,
                         int rightToLeft, PTBTextLine **out);
void ptb_text_line_release(PTBTextLine *l);
int ptb_text_line_info(PTBTextLine *l, PTBTextLineInfo *out);
/* DirectWrite's clusters in text order; returns how many were written (at most cap), negative on failure */
int ptb_text_line_clusters(PTBTextLine *l, PTBTextCluster *out, uint32_t cap);
/* per UTF-16 unit: ascent, descent, leading of the font that drew it (3 doubles each, `units` units) */
int ptb_text_line_unit_metrics(PTBTextLine *l, double *out, uint32_t units);
/* the family name of glyph piece i, and whether it is a colour layer */
int ptb_text_line_piece_family(PTBTextLine *l, uint32_t piece, uint16_t *name, uint32_t cap, int *colorLayer);
/* the glyphs' ink relative to the origin, user space (y up): x, y, width, height; all 0 when nothing has ink */
int ptb_text_line_ink_bounds(PTBTextLine *l, double *out4);

/* Draws the line with its origin (first baseline, left end) at (x, y) in the canvas's user space, through the canvas's state
 * (fill or stroke mode, colours, line width and join, alpha, blend, shadow, clips, antialiasing). Marks the canvas as having text. */
int ptb_canvas_draw_text_line(struct PTBCanvas *c, PTBTextLine *l, double x, double y);

#ifdef __cplusplus
}
#endif

#endif
