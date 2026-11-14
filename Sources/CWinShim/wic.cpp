// WIC is COM, which the Swift side cannot call: PNG decoding and HICON creation live here.
#include "CWinShim.h"

#include <windows.h>
#include <wincodec.h>

#include <cstdlib>
#include <cstring>
#include <vector>

namespace {

// Spelled out (not DEFINE_GUID / __uuidof) so the link needs no uuid.lib and no MS extensions.
const GUID kClsidImagingFactory = {0xcacaf262, 0x9370, 0x4615, {0xa1, 0x3b, 0x9f, 0x55, 0x39, 0xda, 0x4c, 0x0a}};
const GUID kIidImagingFactory = {0xec5ec8a9, 0xc395, 0x4314, {0x9c, 0x77, 0x54, 0xd7, 0xa9, 0x35, 0xff, 0x70}};
const GUID kPixelFormat32bppBGRA = {0x6fddc324, 0x4e03, 0x4bfe, {0xb1, 0x85, 0x3d, 0x77, 0x76, 0x8d, 0xc9, 0x0f}};

template <class T> struct Com {
    T *p = nullptr;
    ~Com() { if (p) p->Release(); }
    T **out() { return &p; }
    T *operator->() const { return p; }
};

int decode(const uint8_t *png, size_t len, uint32_t *w, uint32_t *h, uint8_t **bgra) {
    Com<IWICImagingFactory> factory;
    HRESULT hr = CoCreateInstance(kClsidImagingFactory, nullptr, CLSCTX_INPROC_SERVER, kIidImagingFactory,
                                  reinterpret_cast<void **>(factory.out()));
    if (FAILED(hr)) return hr;
    Com<IWICStream> stream;
    hr = factory->CreateStream(stream.out());
    if (FAILED(hr)) return hr;
    hr = stream->InitializeFromMemory(const_cast<BYTE *>(png), static_cast<DWORD>(len));
    if (FAILED(hr)) return hr;
    Com<IWICBitmapDecoder> decoder;
    hr = factory->CreateDecoderFromStream(stream.p, nullptr, WICDecodeMetadataCacheOnLoad, decoder.out());
    if (FAILED(hr)) return hr;
    Com<IWICBitmapFrameDecode> frame;
    hr = decoder->GetFrame(0, frame.out());
    if (FAILED(hr)) return hr;
    Com<IWICFormatConverter> converter;
    hr = factory->CreateFormatConverter(converter.out());
    if (FAILED(hr)) return hr;
    hr = converter->Initialize(frame.p, kPixelFormat32bppBGRA, WICBitmapDitherTypeNone, nullptr, 0.0,
                               WICBitmapPaletteTypeCustom);
    if (FAILED(hr)) return hr;
    UINT cw = 0, ch = 0;
    hr = converter->GetSize(&cw, &ch);
    if (FAILED(hr)) return hr;
    if (cw == 0 || ch == 0 || cw > 8192 || ch > 8192) return E_INVALIDARG;
    const UINT stride = cw * 4;
    const UINT bytes = stride * ch;
    uint8_t *buffer = static_cast<uint8_t *>(std::malloc(bytes));
    if (!buffer) return E_OUTOFMEMORY;
    hr = converter->CopyPixels(nullptr, stride, bytes, buffer);
    if (FAILED(hr)) {
        std::free(buffer);
        return hr;
    }
    *w = cw;
    *h = ch;
    *bgra = buffer;
    return 0;
}

}  // namespace

extern "C" int ptb_png_to_bgra(const uint8_t *png, size_t len, uint32_t *w, uint32_t *h, uint8_t **bgra) {
    if (!png || len == 0 || !w || !h || !bgra) return static_cast<int>(E_INVALIDARG);
    const HRESULT init = CoInitializeEx(nullptr, COINIT_MULTITHREADED);  // RPC_E_CHANGED_MODE: usable anyway
    const int result = decode(png, len, w, h, bgra);
    if (SUCCEEDED(init)) CoUninitialize();
    return result;
}

extern "C" void ptb_free(void *p) { std::free(p); }

extern "C" void *ptb_icon_from_bgra(const uint8_t *bgra, uint32_t w, uint32_t h, uint32_t size) {
    if (!bgra || w == 0 || h == 0 || size == 0 || size > 512) return nullptr;
    // The artwork's bounding box (alpha > 0), widened to a square: sprites carry a wide transparent margin that
    // would leave a 16 px icon mostly empty.
    uint32_t minX = w, minY = h, maxX = 0, maxY = 0;
    for (uint32_t y = 0; y < h; y++) {
        for (uint32_t x = 0; x < w; x++) {
            if (bgra[(static_cast<size_t>(y) * w + x) * 4 + 3] == 0) continue;
            if (x < minX) minX = x;
            if (x > maxX) maxX = x;
            if (y < minY) minY = y;
            if (y > maxY) maxY = y;
        }
    }
    if (minX > maxX) {  // fully transparent: the whole image
        minX = 0; minY = 0; maxX = w - 1; maxY = h - 1;
    }
    const uint32_t bw = maxX - minX + 1, bh = maxY - minY + 1;
    const uint32_t side = bw > bh ? bw : bh;
    const int64_t left = static_cast<int64_t>(minX) - (static_cast<int64_t>(side) - bw) / 2;
    const int64_t top = static_cast<int64_t>(minY) - (static_cast<int64_t>(side) - bh) / 2;

    BITMAPV5HEADER header = {};
    header.bV5Size = sizeof(header);
    header.bV5Width = static_cast<LONG>(size);
    header.bV5Height = -static_cast<LONG>(size);  // top-down
    header.bV5Planes = 1;
    header.bV5BitCount = 32;
    header.bV5Compression = BI_BITFIELDS;
    header.bV5RedMask = 0x00FF0000;
    header.bV5GreenMask = 0x0000FF00;
    header.bV5BlueMask = 0x000000FF;
    header.bV5AlphaMask = 0xFF000000;
    HDC dc = GetDC(nullptr);
    void *bits = nullptr;
    HBITMAP color = CreateDIBSection(dc, reinterpret_cast<BITMAPINFO *>(&header), DIB_RGB_COLORS, &bits, nullptr, 0);
    ReleaseDC(nullptr, dc);
    if (!color || !bits) {
        if (color) DeleteObject(color);
        return nullptr;
    }
    uint32_t *dst = static_cast<uint32_t *>(bits);
    const uint32_t *src = reinterpret_cast<const uint32_t *>(bgra);
    for (uint32_t y = 0; y < size; y++) {
        const int64_t sy = top + static_cast<int64_t>(y) * side / size;
        for (uint32_t x = 0; x < size; x++) {
            const int64_t sx = left + static_cast<int64_t>(x) * side / size;
            const bool inside = sx >= 0 && sy >= 0 && sx < w && sy < h;
            dst[static_cast<size_t>(y) * size + x] = inside ? src[static_cast<size_t>(sy) * w + sx] : 0;
        }
    }
    // The 1-bpp mask (word-aligned rows); all zero, the alpha channel does the shaping.
    std::vector<uint8_t> maskBits(static_cast<size_t>((size + 15) / 16) * 2 * size, 0);
    HBITMAP mask = CreateBitmap(static_cast<int>(size), static_cast<int>(size), 1, 1, maskBits.data());
    HICON icon = nullptr;
    if (mask) {
        ICONINFO info = {};
        info.fIcon = TRUE;
        info.hbmMask = mask;
        info.hbmColor = color;
        icon = CreateIconIndirect(&info);
        DeleteObject(mask);
    }
    DeleteObject(color);
    return icon;
}
