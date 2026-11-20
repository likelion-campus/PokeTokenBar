// Drawing a text line into a canvas (text.h): each glyph piece's outline as a path geometry, filled or stroked inside
// Canvas::paint, so shadow, blend, alpha, clips and the antialias flags apply to text exactly as to shapes.
//
// Conventions, as CTLineDraw: the origin is the first baseline's left end in user space (y up); glyphs are upright there, so
// each piece gets a local flip about the baseline (glyph space is y down) before the CTM and the canvas's own flip.
// Fill mode paints with the canvas's fill colour (a run with its own colour uses that); a colour glyph's layers paint in the
// font's palette colours ("text colour" layers in the fill colour). Stroke mode strokes the outlines with the canvas's stroke
// colour, line width and join, and skips colour glyphs (Apple's bitmap emoji draw no stroke either).
#include "text.h"

#include <windows.h>

#include <algorithm>
#include <cfloat>

namespace ptb {

int TextLine::ensureGeometry() {
    AcquireSRWLockExclusive(&lock);
    if (geometryDone) {
        ReleaseSRWLockExclusive(&lock);
        return geometryCode;
    }
    Ref<ID2D1Factory> factory;
    int code = sharedD2DFactory(factory);
    double minX = DBL_MAX, minY = DBL_MAX, maxX = -DBL_MAX, maxY = -DBL_MAX;
    for (GlyphPiece &p : pieces) {
        if (code != 0) break;
        if (p.glyphs.empty()) continue;
        HRESULT hr = factory->CreatePathGeometry(p.geometry.out());
        Ref<ID2D1GeometrySink> sink;
        if (SUCCEEDED(hr)) hr = p.geometry->Open(sink.out());
        if (SUCCEEDED(hr)) {
            sink->SetFillMode(D2D1_FILL_MODE_WINDING);  // TrueType and CFF outlines are non-zero winding
            hr = p.face->GetGlyphRunOutline(p.emSize, p.glyphs.data(), p.advances.data(), p.offsets.data(),
                                            static_cast<UINT32>(p.glyphs.size()), FALSE, (p.bidiLevel & 1) ? TRUE : FALSE, sink.get());
            const HRESULT closed = sink->Close();
            if (SUCCEEDED(hr)) hr = closed;
        }
        if (FAILED(hr)) {
            code = fail("glyph outline", hr);
            p.geometry.reset();
            break;
        }
        D2D1_RECT_F b = {};
        if (SUCCEEDED(p.geometry->GetBounds(nullptr, &b)) && b.left <= b.right && b.top <= b.bottom) {
            // glyph space (y down, origin at the piece) -> line space -> y up
            minX = std::min(minX, p.x + b.left);
            maxX = std::max(maxX, p.x + b.right);
            minY = std::min(minY, -(p.y + b.bottom));
            maxY = std::max(maxY, -(p.y + b.top));
        }
    }
    if (code == 0 && minX <= maxX) {
        ink[0] = minX;
        ink[1] = minY;
        ink[2] = maxX - minX;
        ink[3] = maxY - minY;
    }
    geometryCode = code;
    geometryDone = true;
    ReleaseSRWLockExclusive(&lock);
    return code;
}

int drawLine(Canvas &canvas, TextLine &line, double x, double y) {
    const int code = line.ensureGeometry();
    if (code != 0) {
        canvas.failures++;
        return code;
    }
    canvas.drewText = true;
    const bool stroke = canvas.st.textStroke;
    const Rgba fill = canvas.st.fill, strokeColor = canvas.st.stroke;
    const double lineWidth = canvas.st.lineWidth;
    ID2D1StrokeStyle *style = stroke ? canvas.strokeStyle(canvas.st.join, kCapButt) : nullptr;
    const Affine device = canvas.device();
    canvas.paint([&](Surface &s, float opacity) {
        for (const GlyphPiece &p : line.pieces) {
            if (!p.geometry) continue;
            if (stroke && p.colorLayer) continue;
            Rgba color = stroke ? strokeColor : fill;
            const TextRun &run = line.runs[static_cast<size_t>(p.run) < line.runs.size() ? p.run : 0];
            if (run.ownColor) color = run.color;
            if (p.colorLayer && !p.layerUsesTextColor) color = p.layerColor;
            // piece (glyph space, y down) -> user space (y up) at the text position -> device
            const Affine local = {1, 0, 0, -1, x + p.x, y - p.y};
            const D2D1_MATRIX_3X2_F m = Canvas::matrix(concat(local, device));
            s.rt->SetTransform(&m);
            Canvas::setBrush(s, color, opacity);
            if (stroke) s.rt->DrawGeometry(p.geometry.get(), s.brush.get(), static_cast<float>(lineWidth), style);
            else s.rt->FillGeometry(p.geometry.get(), s.brush.get(), nullptr);
        }
    });
    return 0;
}

}  // namespace ptb
