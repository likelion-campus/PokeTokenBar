// The plaza's DirectWrite text engine (stage 6, Task 9). INTERNAL header: C++ only (CPlazaD2D.h has the C functions).
//
// What it does, and what it leaves to Swift:
//  - fonts: a private collection built from the bundled files (IDWriteFactory5 font set builder; nothing is installed), plus a
//    fallback chain: the asked font, then Segoe UI Emoji for the emoji ranges, then the system fallback (locale ko-KR);
//  - metrics: every font's hhea ascender / descender / line gap scaled the way CoreText does (the unitsPerEm ratio rounded to
//    16.16 fixed point: Galmuri11 descender 200/1200 at 12 pt is 2.00006103515625), never DirectWrite's own (OS/2 win) metrics;
//  - a line: one IDWriteTextLayout without wrapping, measured once (DirectWrite clusters, each UTF-16 unit's font metrics) and
//    captured as glyph pieces (colour emoji split into their COLR layers); the layout is not kept;
//  - drawing: each piece's glyph outline as a Direct2D path geometry, filled (or stroked) through ptb::Canvas::paint, so the
//    canvas's alpha, blend, shadow, clips and antialias flags apply to text as to any shape.
// Line breaking, frames and truncation are shared Swift (PlazaLineBreaker, PlazaTextFrame) fed these measurements.
#ifndef CPLAZAD2D_TEXT_H
#define CPLAZAD2D_TEXT_H

#include "canvas.h"

#include <dwrite_3.h>

#include <string>
#include <vector>

namespace ptb {

/// The process's multi-threaded Direct2D factory (canvas_core.cpp): text geometries must come from the factory the canvases use.
int sharedD2DFactory(Ref<ID2D1Factory> &out);

enum TextFont { kFontGalmuri11 = 0, kFontGalmuri14 = 1, kFontPretendard = 2, kFontEmoji = 3, kFontSymbol = 4, kFontMono = 5, kFontCount = 6 };
enum MeasuringMode { kMeasureNatural = 0, kMeasureGdiClassic = 1, kMeasureGdiNatural = 2 };

/// Line metrics as CoreText reports them: all three positive distances.
struct TextMetrics {
    double ascent = 0, descent = 0, leading = 0;
};

/// A font's hhea numbers in design units.
struct Hhea {
    int ascender = 0, descender = 0, lineGap = 0;
    uint32_t unitsPerEm = 0;
    bool found = false;
};

class TextEngine {
public:
    TextEngine() { InitializeSRWLock(&lock); }
    ~TextEngine();

    int init(int measuringMode);
    /// Adds one bundled file to the private font set (before finish).
    int addFontFile(const wchar_t *path);
    /// Builds the private collection and the fallback chain.
    int finish();

    /// The family a font number draws with: its private family, or (when the file was missing) the system font named in
    /// `fallbackFamily` from the system collection.
    struct Family {
        std::wstring name;
        IDWriteFontCollection *collection = nullptr;  // not AddRef'ed: owned by the engine
        bool privateFont = false;
    };
    Family family(int font) const;
    int face(int font, int weight, Ref<IDWriteFontFace> &out);
    static Hhea hheaOf(IDWriteFontFace *face);
    TextMetrics metrics(IDWriteFontFace *face, double size);
    int format(int font, int weight, float size, Ref<IDWriteTextFormat> &out);
    /// The locale the text formats are made with (the system fallback picks Han and kana glyph forms by it): the app language,
    /// "ko-kr" until set. Formats made before are kept under their own locale.
    void setLocale(const wchar_t *name);

    Ref<IDWriteFactory5> factory;
    Ref<IDWriteFontCollection1> privateFonts;
    Ref<IDWriteFontCollection> systemFonts;
    Ref<IDWriteFontFallback> fallback;
    int measuringMode = kMeasureNatural;
    uint32_t filesAdded = 0, filesFailed = 0;
    std::wstring families[kFontCount];   // the family names found in the private collection ("" = not there)

private:
    Ref<IDWriteFontSetBuilder1> builder;
    SRWLOCK lock;
    struct HheaEntry {
        Ref<IDWriteFontFace> face;
        Hhea hhea;
    };
    std::vector<HheaEntry> hheaCache;
    struct FormatEntry {
        int font, weight;
        float size;
        std::wstring locale;
        Ref<IDWriteTextFormat> format;
    };
    std::vector<FormatEntry> formats;
    std::wstring localeName = L"ko-kr";   // under `lock`
    std::wstring findPrivate(const wchar_t *expected);
};

/// What a run of a line is drawn in (CPlazaD2D.h's PTBTextRun, copied).
struct TextRun {
    uint32_t start = 0, length = 0;
    int font = kFontGalmuri14, weight = 400;
    double size = 15;
    bool ownColor = false;  // false: the canvas's fill (or stroke) colour, as a CoreText run taking its colour from the context
    Rgba color;
};

/// One glyph run (or one colour layer of one) as drawn, in line space: x right from the line's left edge, y down from the
/// first baseline.
struct GlyphPiece {
    Ref<IDWriteFontFace> face;
    float emSize = 0;
    std::vector<UINT16> glyphs;
    std::vector<FLOAT> advances;
    std::vector<DWRITE_GLYPH_OFFSET> offsets;
    UINT32 bidiLevel = 0;
    double x = 0, y = 0;
    int run = 0;              // the text run it belongs to (its colour)
    bool colorLayer = false;  // a layer of a colour glyph: drawn in its own colour, skipped when stroking
    bool layerUsesTextColor = false;
    Rgba layerColor;
    Ref<ID2D1PathGeometry> geometry;  // the outline, made on first draw or bounds query
};

struct TextLine {
    std::vector<TextRun> runs;
    std::vector<GlyphPiece> pieces;
    std::vector<DWRITE_CLUSTER_METRICS> clusters;
    std::vector<TextMetrics> unitMetrics;  // per UTF-16 unit: the metrics of the font that drew it
    std::vector<std::wstring> pieceFamilies;
    TextMetrics metrics;                   // largest over the units (0 for an empty line, as CoreText)
    double width = 0;                      // sum of the cluster advances, trailing white space included
    uint32_t glyphRuns = 0, colorRuns = 0;
    int captureCode = 0;

    SRWLOCK lock;
    bool geometryDone = false;
    int geometryCode = 0;
    double ink[4] = {0, 0, 0, 0};  // x, y (up), width, height relative to the origin

    TextLine() { InitializeSRWLock(&lock); }
    /// Makes every piece's outline geometry and the ink bounds (once; thread-safe).
    int ensureGeometry();
};

int makeLine(TextEngine &engine, const wchar_t *text, uint32_t length, const TextRun *runs, uint32_t runCount, bool rightToLeft,
             TextLine *&out);

/// Draws `line` with its origin (the first baseline's left end) at (x, y) in the canvas's user space (y up).
int drawLine(Canvas &canvas, TextLine &line, double x, double y);

}  // namespace ptb

#endif
