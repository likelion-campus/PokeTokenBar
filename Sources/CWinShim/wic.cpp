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

// ---- CI image dumps (`--dump-ui`): icon pixels, screen captures, PNG files ----

extern "C" int ptb_icon_to_bgra(void *hicon, uint32_t *w, uint32_t *h, uint8_t **bgra) {
    if (!hicon || !w || !h || !bgra) return static_cast<int>(E_INVALIDARG);
    ICONINFO info = {};
    if (!GetIconInfo(static_cast<HICON>(hicon), &info)) return static_cast<int>(E_FAIL);
    int result = static_cast<int>(E_FAIL);
    BITMAP bm = {};
    if (info.hbmColor && GetObjectW(info.hbmColor, sizeof(bm), &bm) > 0 && bm.bmWidth > 0 && bm.bmHeight > 0) {
        const LONG bw = bm.bmWidth, bh = bm.bmHeight;
        BITMAPINFO bi = {};
        bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
        bi.bmiHeader.biWidth = bw;
        bi.bmiHeader.biHeight = -bh;  // top-down
        bi.bmiHeader.biPlanes = 1;
        bi.bmiHeader.biBitCount = 32;
        bi.bmiHeader.biCompression = BI_RGB;
        const size_t bytes = static_cast<size_t>(bw) * bh * 4;
        uint8_t *buffer = static_cast<uint8_t *>(std::malloc(bytes));
        if (buffer) {
            HDC dc = GetDC(nullptr);
            const int lines = GetDIBits(dc, info.hbmColor, 0, static_cast<UINT>(bh), buffer, &bi, DIB_RGB_COLORS);
            ReleaseDC(nullptr, dc);
            if (lines == bh) {
                bool anyAlpha = false;
                for (size_t i = 3; i < bytes; i += 4) if (buffer[i]) { anyAlpha = true; break; }
                if (!anyAlpha) for (size_t i = 3; i < bytes; i += 4) buffer[i] = 255;
                *w = static_cast<uint32_t>(bw);
                *h = static_cast<uint32_t>(bh);
                *bgra = buffer;
                result = 0;
            } else {
                std::free(buffer);
            }
        } else {
            result = static_cast<int>(E_OUTOFMEMORY);
        }
    }
    if (info.hbmColor) DeleteObject(info.hbmColor);
    if (info.hbmMask) DeleteObject(info.hbmMask);
    return result;
}

extern "C" int ptb_capture_screen(int32_t x, int32_t y, uint32_t w, uint32_t h, uint8_t **bgra) {
    if (!bgra || w == 0 || h == 0 || w > 16384 || h > 16384) return static_cast<int>(E_INVALIDARG);
    HDC screen = GetDC(nullptr);
    if (!screen) return static_cast<int>(E_FAIL);
    HDC mem = CreateCompatibleDC(screen);
    BITMAPINFO bi = {};
    bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bi.bmiHeader.biWidth = static_cast<LONG>(w);
    bi.bmiHeader.biHeight = -static_cast<LONG>(h);
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;
    void *bits = nullptr;
    HBITMAP dib = mem ? CreateDIBSection(screen, &bi, DIB_RGB_COLORS, &bits, nullptr, 0) : nullptr;
    int result = static_cast<int>(E_FAIL);
    if (dib && bits) {
        HGDIOBJ old = SelectObject(mem, dib);
        if (BitBlt(mem, 0, 0, static_cast<int>(w), static_cast<int>(h), screen, x, y, SRCCOPY | CAPTUREBLT)) {
            const size_t bytes = static_cast<size_t>(w) * h * 4;
            uint8_t *buffer = static_cast<uint8_t *>(std::malloc(bytes));
            if (buffer) {
                std::memcpy(buffer, bits, bytes);
                for (size_t i = 3; i < bytes; i += 4) buffer[i] = 255;  // the screen has no alpha
                *bgra = buffer;
                result = 0;
            } else {
                result = static_cast<int>(E_OUTOFMEMORY);
            }
        }
        SelectObject(mem, old);
    }
    if (dib) DeleteObject(dib);
    if (mem) DeleteDC(mem);
    ReleaseDC(nullptr, screen);
    return result;
}

namespace {

const GUID kContainerFormatPng = {0x1b7cfaf4, 0x713f, 0x473c, {0xbb, 0xcd, 0x61, 0x37, 0x42, 0x5f, 0xae, 0xaf}};

int writePng(const wchar_t *path, const uint8_t *bgra, uint32_t w, uint32_t h) {
    Com<IWICImagingFactory> factory;
    HRESULT hr = CoCreateInstance(kClsidImagingFactory, nullptr, CLSCTX_INPROC_SERVER, kIidImagingFactory,
                                  reinterpret_cast<void **>(factory.out()));
    if (FAILED(hr)) return hr;
    Com<IWICStream> stream;
    hr = factory->CreateStream(stream.out());
    if (FAILED(hr)) return hr;
    hr = stream->InitializeFromFilename(path, GENERIC_WRITE);
    if (FAILED(hr)) return hr;
    Com<IWICBitmapEncoder> encoder;
    hr = factory->CreateEncoder(kContainerFormatPng, nullptr, encoder.out());
    if (FAILED(hr)) return hr;
    hr = encoder->Initialize(stream.p, WICBitmapEncoderNoCache);
    if (FAILED(hr)) return hr;
    Com<IWICBitmapFrameEncode> frame;
    hr = encoder->CreateNewFrame(frame.out(), nullptr);
    if (FAILED(hr)) return hr;
    hr = frame->Initialize(nullptr);
    if (FAILED(hr)) return hr;
    hr = frame->SetSize(w, h);
    if (FAILED(hr)) return hr;
    WICPixelFormatGUID format = kPixelFormat32bppBGRA;
    hr = frame->SetPixelFormat(&format);
    if (FAILED(hr)) return hr;
    hr = frame->WritePixels(h, w * 4, w * h * 4, const_cast<BYTE *>(bgra));
    if (FAILED(hr)) return hr;
    hr = frame->Commit();
    if (FAILED(hr)) return hr;
    return encoder->Commit();
}

}  // namespace

extern "C" int ptb_png_write_bgra(const uint16_t *path, const uint8_t *bgra, uint32_t w, uint32_t h) {
    if (!path || !bgra || w == 0 || h == 0 || w > 16384 || h > 16384) return static_cast<int>(E_INVALIDARG);
    const HRESULT init = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    const int result = writePng(reinterpret_cast<const wchar_t *>(path), bgra, w, h);
    if (SUCCEEDED(init)) CoUninitialize();
    return result;
}
