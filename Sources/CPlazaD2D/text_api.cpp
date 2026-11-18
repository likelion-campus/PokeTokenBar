// The C functions of the text engine (CPlazaD2DText.h). Thin: the engine is ptb::TextEngine, a line ptb::TextLine.
#include "CPlazaD2D.h"
#include "text.h"

#include <cstring>
#include <new>

using ptb::TextEngine;
using ptb::TextLine;

namespace {

TextEngine *E(PTBTextEngine *e) { return reinterpret_cast<TextEngine *>(e); }
TextLine *L(PTBTextLine *l) { return reinterpret_cast<TextLine *>(l); }
const wchar_t *W(const uint16_t *s) { return reinterpret_cast<const wchar_t *>(s); }

void copyName(const std::wstring &name, uint16_t *out, uint32_t cap) {
    if (!out || cap == 0) return;
    const size_t n = name.size() < cap - 1 ? name.size() : cap - 1;
    for (size_t i = 0; i < n; i++) out[i] = static_cast<uint16_t>(name[i]);
    out[n] = 0;
}

std::wstring stringAt(IDWriteLocalizedStrings *names) {
    UINT32 length = 0;
    if (!names || FAILED(names->GetStringLength(0, &length))) return L"";
    std::wstring s(length + 1, L'\0');
    if (FAILED(names->GetString(0, &s[0], length + 1))) return L"";
    s.resize(length);
    return s;
}

}  // namespace

extern "C" {

int ptb_text_engine_create(int measuringMode, PTBTextEngine **out) {
    if (!out) return ptb::fail("ptb_text_engine_create", E_INVALIDARG);
    *out = nullptr;
    TextEngine *e = new (std::nothrow) TextEngine();
    if (!e) return ptb::fail("text engine", E_OUTOFMEMORY);
    const int code = e->init(measuringMode);
    if (code != 0) { delete e; return code; }
    *out = reinterpret_cast<PTBTextEngine *>(e);
    return 0;
}

int ptb_text_engine_add_font(PTBTextEngine *e, const uint16_t *path) {
    if (!e || !path) return ptb::fail("ptb_text_engine_add_font", E_INVALIDARG);
    return E(e)->addFontFile(W(path));
}

int ptb_text_engine_finish(PTBTextEngine *e) {
    if (!e) return ptb::fail("ptb_text_engine_finish", E_INVALIDARG);
    return E(e)->finish();
}

void ptb_text_engine_release(PTBTextEngine *e) { delete E(e); }

int ptb_text_engine_set_locale(PTBTextEngine *e, const uint16_t *name) {
    if (!e || !name) return ptb::fail("ptb_text_engine_set_locale", E_INVALIDARG);
    E(e)->setLocale(W(name));
    return 0;
}

int ptb_text_font_info(PTBTextEngine *e, int font, int weight, double size, PTBFontInfo *out, uint16_t *family, uint32_t familyCap,
                       uint16_t *face, uint32_t faceCap) {
    if (!e || !out) return ptb::fail("ptb_text_font_info", E_INVALIDARG);
    std::memset(out, 0, sizeof(*out));
    TextEngine &engine = *E(e);
    ptb::Ref<IDWriteFontFace> f;
    const int code = engine.face(font, weight, f);
    if (code != 0) return code;
    const ptb::TextEngine::Family fam = engine.family(font);
    out->found = fam.privateFont || font == ptb::kFontEmoji ? 1 : 0;
    const ptb::Hhea h = TextEngine::hheaOf(f.get());
    DWRITE_FONT_METRICS m = {};
    f->GetMetrics(&m);
    out->unitsPerEm = m.designUnitsPerEm;
    out->hheaAscender = h.ascender;
    out->hheaDescender = h.descender;
    out->hheaLineGap = h.lineGap;
    out->dwAscent = m.ascent;
    out->dwDescent = m.descent;
    out->dwLineGap = m.lineGap;
    const ptb::TextMetrics t = engine.metrics(f.get(), size);
    out->ascent = t.ascent;
    out->descent = t.descent;
    out->leading = t.leading;
    ptb::Ref<IDWriteFontFace3> f3;
    if (SUCCEEDED(f->QueryInterface(__uuidof(IDWriteFontFace3), reinterpret_cast<void **>(f3.out())))) {
        out->weight = static_cast<int32_t>(f3->GetWeight());
        ptb::Ref<IDWriteLocalizedStrings> names, faces;
        if (SUCCEEDED(f3->GetFamilyNames(names.out()))) copyName(stringAt(names.get()), family, familyCap);
        if (SUCCEEDED(f3->GetFaceNames(faces.out()))) copyName(stringAt(faces.get()), face, faceCap);
    }
    return 0;
}

int ptb_text_has_family(PTBTextEngine *e, int system, const uint16_t *name, int *exists) {
    if (!e || !name || !exists) return ptb::fail("ptb_text_has_family", E_INVALIDARG);
    *exists = 0;
    IDWriteFontCollection *c = system ? E(e)->systemFonts.get() : static_cast<IDWriteFontCollection *>(E(e)->privateFonts.get());
    if (!c) return 0;
    UINT32 index = 0;
    BOOL found = FALSE;
    const HRESULT hr = c->FindFamilyName(W(name), &index, &found);
    if (FAILED(hr)) return ptb::fail("FindFamilyName", hr);
    *exists = found ? 1 : 0;
    return 0;
}

int ptb_text_line_create(PTBTextEngine *e, const uint16_t *utf16, uint32_t length, const PTBTextRun *runs, uint32_t runCount,
                         int rightToLeft, PTBTextLine **out) {
    if (!e || !out || !runs || runCount == 0 || (length > 0 && !utf16)) return ptb::fail("ptb_text_line_create", E_INVALIDARG);
    *out = nullptr;
    std::vector<ptb::TextRun> copied(runCount);
    for (uint32_t i = 0; i < runCount; i++) {
        ptb::TextRun &r = copied[i];
        r.start = runs[i].start;
        r.length = runs[i].length;
        r.font = runs[i].font;
        r.weight = runs[i].weight;
        r.size = runs[i].size;
        r.ownColor = runs[i].ownColor != 0;
        r.color = ptb::Rgba{runs[i].r, runs[i].g, runs[i].b, runs[i].a};
    }
    TextLine *line = nullptr;
    const int code = ptb::makeLine(*E(e), length ? W(utf16) : L"", length, copied.data(), runCount, rightToLeft != 0, line);
    if (code != 0) return code;
    *out = reinterpret_cast<PTBTextLine *>(line);
    return 0;
}

void ptb_text_line_release(PTBTextLine *l) { delete L(l); }

int ptb_text_line_info(PTBTextLine *l, PTBTextLineInfo *out) {
    if (!l || !out) return ptb::fail("ptb_text_line_info", E_INVALIDARG);
    const TextLine &line = *L(l);
    out->width = line.width;
    out->ascent = line.metrics.ascent;
    out->descent = line.metrics.descent;
    out->leading = line.metrics.leading;
    out->clusters = static_cast<uint32_t>(line.clusters.size());
    out->glyphRuns = line.glyphRuns;
    out->colorRuns = line.colorRuns;
    out->pieces = static_cast<uint32_t>(line.pieces.size());
    out->captureCode = line.captureCode;
    return 0;
}

int ptb_text_line_clusters(PTBTextLine *l, PTBTextCluster *out, uint32_t cap) {
    if (!l || (cap > 0 && !out)) return ptb::fail("ptb_text_line_clusters", E_INVALIDARG);
    const TextLine &line = *L(l);
    uint32_t n = 0;
    for (const DWRITE_CLUSTER_METRICS &c : line.clusters) {
        if (n >= cap) break;
        out[n].width = c.width;
        out[n].length = c.length;
        out[n].flags = (c.isWhitespace ? 1u : 0u) | (c.isNewline ? 2u : 0u) | (c.canWrapLineAfter ? 4u : 0u) | (c.isSoftHyphen ? 8u : 0u) |
                       (c.isRightToLeft ? 16u : 0u);
        n++;
    }
    return static_cast<int>(n);
}

int ptb_text_line_unit_metrics(PTBTextLine *l, double *out, uint32_t units) {
    if (!l || (units > 0 && !out)) return ptb::fail("ptb_text_line_unit_metrics", E_INVALIDARG);
    const TextLine &line = *L(l);
    if (units > line.unitMetrics.size()) return ptb::fail("ptb_text_line_unit_metrics: units", E_INVALIDARG);
    for (uint32_t k = 0; k < units; k++) {
        out[3 * k] = line.unitMetrics[k].ascent;
        out[3 * k + 1] = line.unitMetrics[k].descent;
        out[3 * k + 2] = line.unitMetrics[k].leading;
    }
    return 0;
}

int ptb_text_line_piece_family(PTBTextLine *l, uint32_t piece, uint16_t *name, uint32_t cap, int *colorLayer) {
    if (!l) return ptb::fail("ptb_text_line_piece_family", E_INVALIDARG);
    const TextLine &line = *L(l);
    if (piece >= line.pieces.size()) return ptb::fail("ptb_text_line_piece_family: index", E_INVALIDARG);
    copyName(piece < line.pieceFamilies.size() ? line.pieceFamilies[piece] : std::wstring(L"?"), name, cap);
    if (colorLayer) *colorLayer = line.pieces[piece].colorLayer ? 1 : 0;
    return 0;
}

int ptb_text_line_ink_bounds(PTBTextLine *l, double *out4) {
    if (!l || !out4) return ptb::fail("ptb_text_line_ink_bounds", E_INVALIDARG);
    TextLine &line = *L(l);
    const int code = line.ensureGeometry();
    for (int i = 0; i < 4; i++) out4[i] = line.ink[i];
    return code;
}

int ptb_canvas_draw_text_line(struct PTBCanvas *c, PTBTextLine *l, double x, double y) {
    if (!c || !l) return ptb::fail("ptb_canvas_draw_text_line", E_INVALIDARG);
    return ptb::drawLine(*reinterpret_cast<ptb::Canvas *>(c), *L(l), x, y);
}

}  // extern "C"
