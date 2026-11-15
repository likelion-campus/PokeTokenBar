// A text line (text.h): one IDWriteTextLayout without wrapping, measured and captured once, then released.
#include "text.h"

#include <windows.h>

#include <algorithm>
#include <cmath>
#include <new>

namespace ptb {
namespace {

const HRESULT kNoColor = static_cast<HRESULT>(0x8898500CL);  // DWRITE_E_NOCOLOR: the run has no colour glyphs

/// A run's index, handed to DirectWrite as the drawing effect so glyph runs split where the colour changes.
class RunEffect final : public IUnknown {
public:
    explicit RunEffect(int run) : index(run) {}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **object) override {
        if (riid == __uuidof(IUnknown)) {
            *object = static_cast<IUnknown *>(this);
            AddRef();
            return S_OK;
        }
        *object = nullptr;
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return static_cast<ULONG>(InterlockedIncrement(&refs)); }
    ULONG STDMETHODCALLTYPE Release() override {
        const LONG left = InterlockedDecrement(&refs);
        if (left == 0) delete this;
        return static_cast<ULONG>(left);
    }
    const int index;

private:
    LONG refs = 1;
};

/// Records what the layout would draw: every glyph run with its origin, split into colour layers where the font has them.
class Capture final : public IDWriteTextRenderer {
public:
    Capture(TextEngine &e, TextLine &l, DWRITE_MEASURING_MODE m) : engine(e), line(l), mode(m) {}

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **object) override {
        if (riid == __uuidof(IUnknown) || riid == __uuidof(IDWritePixelSnapping) || riid == __uuidof(IDWriteTextRenderer)) {
            *object = static_cast<IDWriteTextRenderer *>(this);
            return S_OK;
        }
        *object = nullptr;
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return 1; }   // lives on the stack of makeLine
    ULONG STDMETHODCALLTYPE Release() override { return 1; }

    STDMETHOD(IsPixelSnappingDisabled)(void *, BOOL *disabled) override {
        *disabled = TRUE;
        return S_OK;
    }
    STDMETHOD(GetCurrentTransform)(void *, DWRITE_MATRIX *transform) override {
        *transform = DWRITE_MATRIX{1, 0, 0, 1, 0, 0};
        return S_OK;
    }
    STDMETHOD(GetPixelsPerDip)(void *, FLOAT *pixelsPerDip) override {
        *pixelsPerDip = 1;
        return S_OK;
    }

    STDMETHOD(DrawGlyphRun)(void *, FLOAT x, FLOAT y, DWRITE_MEASURING_MODE, const DWRITE_GLYPH_RUN *run,
                            const DWRITE_GLYPH_RUN_DESCRIPTION *description, IUnknown *effect) override {
        const int runIndex = effect ? static_cast<RunEffect *>(effect)->index : 0;
        line.glyphRuns++;
        if (description) {
            const TextMetrics m = engine.metrics(run->fontFace, run->fontEmSize);
            const uint32_t end = std::min<uint32_t>(description->textPosition + description->stringLength,
                                                    static_cast<uint32_t>(line.unitMetrics.size()));
            for (uint32_t k = description->textPosition; k < end; k++) line.unitMetrics[k] = m;
        }
        Ref<IDWriteColorGlyphRunEnumerator> layers;
        IDWriteFactory2 *factory2 = engine.factory.get();  // IDWriteFactory4 overloads TranslateColorGlyphRun
        const HRESULT hr = factory2->TranslateColorGlyphRun(x, y, run, description, mode, nullptr, 0, layers.out());
        if (SUCCEEDED(hr)) {
            bool any = false;
            BOOL more = FALSE;
            while (SUCCEEDED(layers->MoveNext(&more)) && more) {
                const DWRITE_COLOR_GLYPH_RUN *layer = nullptr;
                if (FAILED(layers->GetCurrentRun(&layer)) || !layer) break;
                GlyphPiece piece = make(layer->glyphRun, layer->baselineOriginX, layer->baselineOriginY, runIndex);
                piece.colorLayer = true;
                piece.layerUsesTextColor = layer->paletteIndex == 0xFFFF;
                piece.layerColor = Rgba{layer->runColor.r, layer->runColor.g, layer->runColor.b, layer->runColor.a};
                line.pieces.push_back(std::move(piece));
                any = true;
            }
            if (any) line.colorRuns++;
            return S_OK;
        }
        if (hr != kNoColor) line.captureCode = fail("TranslateColorGlyphRun", hr);  // drawn plain, the failure counted
        line.pieces.push_back(make(*run, x, y, runIndex));
        return S_OK;
    }
    STDMETHOD(DrawUnderline)(void *, FLOAT, FLOAT, const DWRITE_UNDERLINE *, IUnknown *) override { return S_OK; }
    STDMETHOD(DrawStrikethrough)(void *, FLOAT, FLOAT, const DWRITE_STRIKETHROUGH *, IUnknown *) override { return S_OK; }
    STDMETHOD(DrawInlineObject)(void *, FLOAT, FLOAT, IDWriteInlineObject *, BOOL, BOOL, IUnknown *) override { return S_OK; }

private:
    TextEngine &engine;
    TextLine &line;
    DWRITE_MEASURING_MODE mode;

    static GlyphPiece make(const DWRITE_GLYPH_RUN &run, FLOAT x, FLOAT y, int runIndex) {
        GlyphPiece p;
        p.face.p = run.fontFace;
        run.fontFace->AddRef();
        p.emSize = run.fontEmSize;
        p.glyphs.assign(run.glyphIndices, run.glyphIndices + run.glyphCount);
        if (run.glyphAdvances) p.advances.assign(run.glyphAdvances, run.glyphAdvances + run.glyphCount);
        else p.advances.assign(run.glyphCount, 0.0f);
        if (run.glyphOffsets) p.offsets.assign(run.glyphOffsets, run.glyphOffsets + run.glyphCount);
        else p.offsets.assign(run.glyphCount, DWRITE_GLYPH_OFFSET{0, 0});
        p.bidiLevel = run.bidiLevel;
        p.x = x;
        p.y = y;
        p.run = runIndex;
        return p;
    }
};

std::wstring familyName(IDWriteFontFace *face) {
    Ref<IDWriteFontFace3> face3;
    if (FAILED(face->QueryInterface(__uuidof(IDWriteFontFace3), reinterpret_cast<void **>(face3.out())))) return L"?";
    Ref<IDWriteLocalizedStrings> names;
    if (FAILED(face3->GetFamilyNames(names.out()))) return L"?";
    UINT32 length = 0;
    if (FAILED(names->GetStringLength(0, &length))) return L"?";
    std::wstring name(length + 1, L'\0');
    if (FAILED(names->GetString(0, &name[0], length + 1))) return L"?";
    name.resize(length);
    return name;
}

}  // namespace

int makeLine(TextEngine &engine, const wchar_t *text, uint32_t length, const TextRun *runs, uint32_t runCount, bool rightToLeft,
             TextLine *&out) {
    out = nullptr;
    if (runCount == 0 || !runs) return fail("makeLine: no runs", E_INVALIDARG);
    TextLine *line = new (std::nothrow) TextLine();
    if (!line) return fail("makeLine", E_OUTOFMEMORY);
    line->runs.assign(runs, runs + runCount);

    Ref<IDWriteTextFormat> format;
    int code = engine.format(runs[0].font, runs[0].weight, static_cast<float>(runs[0].size), format);
    if (code != 0) { delete line; return code; }

    // Every unit starts with the metrics of the font its run asks for; units the glyph runs hold get the font that drew them.
    line->unitMetrics.assign(length, TextMetrics{});
    for (uint32_t r = 0; r < runCount; r++) {
        Ref<IDWriteFontFace> face;
        if (engine.face(runs[r].font, runs[r].weight, face) != 0) continue;
        const TextMetrics m = engine.metrics(face.get(), runs[r].size);
        const uint32_t end = std::min<uint32_t>(runs[r].start + runs[r].length, length);
        for (uint32_t k = runs[r].start; k < end; k++) line->unitMetrics[k] = m;
    }

    Ref<IDWriteTextLayout> layout;
    HRESULT hr;
    // Width 0, no wrapping: left-to-right text starts at 0, right-to-left text ends there (small coordinates, full precision).
    if (engine.measuringMode == kMeasureNatural) {
        hr = engine.factory->CreateTextLayout(text, length, format.get(), 0.0f, 0.0f, layout.out());
    } else {
        hr = engine.factory->CreateGdiCompatibleTextLayout(text, length, format.get(), 0.0f, 0.0f, 1.0f, nullptr,
                                                           engine.measuringMode == kMeasureGdiNatural ? TRUE : FALSE, layout.out());
    }
    if (FAILED(hr)) { delete line; return fail("CreateTextLayout", hr); }
    layout->SetReadingDirection(rightToLeft ? DWRITE_READING_DIRECTION_RIGHT_TO_LEFT : DWRITE_READING_DIRECTION_LEFT_TO_RIGHT);
    for (uint32_t r = 0; r < runCount; r++) {
        const DWRITE_TEXT_RANGE range = {runs[r].start, runs[r].length};
        const TextEngine::Family f = engine.family(runs[r].font);
        layout->SetFontCollection(f.collection, range);
        layout->SetFontFamilyName(f.name.c_str(), range);
        layout->SetFontWeight(static_cast<DWRITE_FONT_WEIGHT>(runs[r].weight), range);
        layout->SetFontSize(static_cast<FLOAT>(runs[r].size), range);
        RunEffect *effect = new (std::nothrow) RunEffect(static_cast<int>(r));
        if (effect) {
            layout->SetDrawingEffect(effect, range);
            effect->Release();  // the layout holds it
        }
    }

    UINT32 clusterCount = 0;
    hr = layout->GetClusterMetrics(nullptr, 0, &clusterCount);
    if (hr == E_NOT_SUFFICIENT_BUFFER || SUCCEEDED(hr)) {
        line->clusters.resize(clusterCount);
        hr = clusterCount ? layout->GetClusterMetrics(line->clusters.data(), clusterCount, &clusterCount) : S_OK;
    }
    if (FAILED(hr)) { delete line; return fail("GetClusterMetrics", hr); }
    for (const DWRITE_CLUSTER_METRICS &c : line->clusters) line->width += c.width;

    UINT32 lineCount = 0;
    std::vector<DWRITE_LINE_METRICS> lines;
    hr = layout->GetLineMetrics(nullptr, 0, &lineCount);
    if (hr == E_NOT_SUFFICIENT_BUFFER || SUCCEEDED(hr)) {
        lines.resize(lineCount);
        hr = lineCount ? layout->GetLineMetrics(lines.data(), lineCount, &lineCount) : S_OK;
    }
    if (FAILED(hr)) { delete line; return fail("GetLineMetrics", hr); }

    const DWRITE_MEASURING_MODE mode = engine.measuringMode == kMeasureGdiClassic ? DWRITE_MEASURING_MODE_GDI_CLASSIC
                                      : engine.measuringMode == kMeasureGdiNatural ? DWRITE_MEASURING_MODE_GDI_NATURAL
                                                                                    : DWRITE_MEASURING_MODE_NATURAL;
    Capture capture(engine, *line, mode);
    hr = layout->Draw(nullptr, &capture, 0.0f, 0.0f);
    if (FAILED(hr)) { delete line; return fail("IDWriteTextLayout::Draw", hr); }

    // Line space: the first baseline at y = 0, the left edge of the leftmost run at x = 0 (right-to-left runs end at their origin).
    const double baseline = lines.empty() ? 0.0 : lines[0].baseline;
    double left = 0;
    bool first = true;
    for (const GlyphPiece &p : line->pieces) {
        double advance = 0;
        for (FLOAT a : p.advances) advance += a;
        const double start = (p.bidiLevel & 1) ? p.x - advance : p.x;
        if (first || start < left) left = start;
        first = false;
    }
    for (GlyphPiece &p : line->pieces) {
        p.x -= left;
        p.y -= baseline;
        line->pieceFamilies.push_back(familyName(p.face.get()));
    }
    for (const TextMetrics &m : line->unitMetrics) {
        line->metrics.ascent = std::max(line->metrics.ascent, m.ascent);
        line->metrics.descent = std::max(line->metrics.descent, m.descent);
        line->metrics.leading = std::max(line->metrics.leading, m.leading);
    }
    out = line;
    return 0;
}

}  // namespace ptb
