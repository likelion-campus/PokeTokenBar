// COM apartments, error text and the WIC codecs (see CPlazaD2D.h for the rules).
#include "CPlazaD2D.h"
#include "internal.h"

#include <windows.h>
#include <objbase.h>
#include <propidl.h>
#include <wincodec.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace {

using namespace ptb;

// Spelled out (not DEFINE_GUID / __uuidof), as CWinShim does: the link needs no uuid.lib.
const GUID kClsidImagingFactory = {0xcacaf262, 0x9370, 0x4615, {0xa1, 0x3b, 0x9f, 0x55, 0x39, 0xda, 0x4c, 0x0a}};
const GUID kIidImagingFactory = {0xec5ec8a9, 0xc395, 0x4314, {0x9c, 0x77, 0x54, 0xd7, 0xa9, 0x35, 0xff, 0x70}};
const GUID kPixelFormat32bppBGRA = {0x6fddc324, 0x4e03, 0x4bfe, {0xb1, 0x85, 0x3d, 0x77, 0x76, 0x8d, 0xc9, 0x0f}};
const GUID kContainerFormatPng = {0x1b7cfaf4, 0x713f, 0x473c, {0xbb, 0xcd, 0x61, 0x37, 0x42, 0x5f, 0xae, 0xaf}};
const GUID kContainerFormatGif = {0x1f8a5601, 0x7d4d, 0x4cbd, {0x9c, 0x82, 0x1b, 0xc8, 0xd4, 0xee, 0xb9, 0xa5}};

constexpr uint32_t kMaxSide = 16384;
constexpr uint64_t kMaxBytes = 512ull << 20;

int makeFactory(Com<IWICImagingFactory> &factory) {
    HRESULT hr = ensureCom();
    if (FAILED(hr)) return fail("COM init", hr);
    hr = CoCreateInstance(kClsidImagingFactory, nullptr, CLSCTX_INPROC_SERVER, kIidImagingFactory,
                          reinterpret_cast<void **>(factory.out()));
    if (FAILED(hr)) return fail("WIC factory", hr);
    return 0;
}

int openDecoder(IWICImagingFactory *factory, const uint8_t *data, size_t len, Com<IWICStream> &stream,
                Com<IWICBitmapDecoder> &decoder) {
    if (!data || len == 0 || len > 0x7fffffffu) return fail("input", E_INVALIDARG);
    HRESULT hr = factory->CreateStream(stream.out());
    if (FAILED(hr)) return fail("CreateStream", hr);
    hr = stream->InitializeFromMemory(const_cast<BYTE *>(data), static_cast<DWORD>(len));
    if (FAILED(hr)) return fail("InitializeFromMemory", hr);
    hr = factory->CreateDecoderFromStream(stream.p, nullptr, WICDecodeMetadataCacheOnLoad, decoder.out());
    if (FAILED(hr)) return fail("CreateDecoderFromStream", hr);
    return 0;
}

int decodeRGBA(const uint8_t *data, size_t len, uint32_t *w, uint32_t *h, uint8_t **rgba) {
    Com<IWICImagingFactory> factory;
    int code = makeFactory(factory);
    if (code != 0) return code;
    Com<IWICStream> stream;
    Com<IWICBitmapDecoder> decoder;
    code = openDecoder(factory.p, data, len, stream, decoder);
    if (code != 0) return code;
    Com<IWICBitmapFrameDecode> frame;
    HRESULT hr = decoder->GetFrame(0, frame.out());
    if (FAILED(hr)) return fail("GetFrame", hr);
    Com<IWICFormatConverter> converter;
    hr = factory->CreateFormatConverter(converter.out());
    if (FAILED(hr)) return fail("CreateFormatConverter", hr);
    hr = converter->Initialize(frame.p, kPixelFormat32bppBGRA, WICBitmapDitherTypeNone, nullptr, 0.0,
                               WICBitmapPaletteTypeCustom);
    if (FAILED(hr)) return fail("format converter", hr);
    UINT cw = 0, ch = 0;
    hr = converter->GetSize(&cw, &ch);
    if (FAILED(hr)) return fail("GetSize", hr);
    if (cw == 0 || ch == 0 || cw > kMaxSide || ch > kMaxSide || static_cast<uint64_t>(cw) * ch * 4 > kMaxBytes)
        return fail("size", E_INVALIDARG);
    const UINT stride = cw * 4;
    const UINT bytes = stride * ch;
    uint8_t *buffer = static_cast<uint8_t *>(std::malloc(bytes));
    if (!buffer) return fail("malloc", E_OUTOFMEMORY);
    hr = converter->CopyPixels(nullptr, stride, bytes, buffer);
    if (FAILED(hr)) {
        std::free(buffer);
        return fail("CopyPixels", hr);
    }
    for (size_t i = 0; i < bytes; i += 4) {  // BGRA -> RGBA, still straight alpha
        const uint8_t b = buffer[i];
        buffer[i] = buffer[i + 2];
        buffer[i + 2] = b;
    }
    *w = cw;
    *h = ch;
    *rgba = buffer;
    return 0;
}

int encodePng(const uint8_t *rgba, uint32_t w, uint32_t h, uint8_t **png, size_t *len) {
    Com<IWICImagingFactory> factory;
    int code = makeFactory(factory);
    if (code != 0) return code;
    const size_t bytes = static_cast<size_t>(w) * h * 4;
    uint8_t *bgra = static_cast<uint8_t *>(std::malloc(bytes));
    if (!bgra) return fail("malloc", E_OUTOFMEMORY);
    for (size_t i = 0; i < bytes; i += 4) {
        bgra[i] = rgba[i + 2];
        bgra[i + 1] = rgba[i + 1];
        bgra[i + 2] = rgba[i];
        bgra[i + 3] = rgba[i + 3];
    }
    struct Free { uint8_t *p; ~Free() { std::free(p); } } freeBgra{bgra};

    Com<IStream> stream;
    HRESULT hr = CreateStreamOnHGlobal(nullptr, TRUE, stream.out());  // TRUE: the stream frees the memory with itself
    if (FAILED(hr)) return fail("CreateStreamOnHGlobal", hr);
    Com<IWICBitmapEncoder> encoder;
    hr = factory->CreateEncoder(kContainerFormatPng, nullptr, encoder.out());
    if (FAILED(hr)) return fail("CreateEncoder", hr);
    hr = encoder->Initialize(stream.p, WICBitmapEncoderNoCache);
    if (FAILED(hr)) return fail("encoder Initialize", hr);
    Com<IWICBitmapFrameEncode> frame;
    hr = encoder->CreateNewFrame(frame.out(), nullptr);
    if (FAILED(hr)) return fail("CreateNewFrame", hr);
    hr = frame->Initialize(nullptr);
    if (FAILED(hr)) return fail("frame Initialize", hr);
    hr = frame->SetSize(w, h);
    if (FAILED(hr)) return fail("SetSize", hr);
    WICPixelFormatGUID format = kPixelFormat32bppBGRA;
    hr = frame->SetPixelFormat(&format);
    if (FAILED(hr)) return fail("SetPixelFormat", hr);
    if (!IsEqualGUID(format, kPixelFormat32bppBGRA)) return fail("PNG encoder pixel format", WINCODEC_ERR_UNSUPPORTEDPIXELFORMAT);
    hr = frame->WritePixels(h, w * 4, static_cast<UINT>(bytes), bgra);
    if (FAILED(hr)) return fail("WritePixels", hr);
    hr = frame->Commit();
    if (FAILED(hr)) return fail("frame Commit", hr);
    hr = encoder->Commit();
    if (FAILED(hr)) return fail("encoder Commit", hr);

    STATSTG stat = {};
    hr = stream->Stat(&stat, STATFLAG_NONAME);
    if (FAILED(hr)) return fail("Stat", hr);
    const size_t size = static_cast<size_t>(stat.cbSize.QuadPart);
    HGLOBAL memory = nullptr;
    hr = GetHGlobalFromStream(stream.p, &memory);
    if (FAILED(hr)) return fail("GetHGlobalFromStream", hr);
    const void *source = GlobalLock(memory);
    if (!source) return fail("GlobalLock", HRESULT_FROM_WIN32(GetLastError()));
    uint8_t *out = static_cast<uint8_t *>(std::malloc(size ? size : 1));
    if (out) std::memcpy(out, source, size);
    GlobalUnlock(memory);
    if (!out) return fail("malloc", E_OUTOFMEMORY);
    *png = out;
    *len = size;
    return 0;
}

int gifDelays(const uint8_t *data, size_t len, uint32_t *count, int32_t *delaysCs, uint32_t cap) {
    Com<IWICImagingFactory> factory;
    int code = makeFactory(factory);
    if (code != 0) return code;
    Com<IWICStream> stream;
    Com<IWICBitmapDecoder> decoder;
    code = openDecoder(factory.p, data, len, stream, decoder);
    if (code != 0) return code;
    GUID container = {};
    HRESULT hr = decoder->GetContainerFormat(&container);
    if (FAILED(hr)) return fail("GetContainerFormat", hr);
    if (!IsEqualGUID(container, kContainerFormatGif)) return fail("not a GIF", WINCODEC_ERR_BADIMAGE);
    UINT frames = 0;
    hr = decoder->GetFrameCount(&frames);
    if (FAILED(hr)) return fail("GetFrameCount", hr);
    for (UINT i = 0; i < frames && i < cap; i++) {
        delaysCs[i] = -1;
        Com<IWICBitmapFrameDecode> frame;
        if (FAILED(decoder->GetFrame(i, frame.out()))) continue;
        Com<IWICMetadataQueryReader> reader;
        if (FAILED(frame->GetMetadataQueryReader(reader.out()))) continue;
        PROPVARIANT value;
        PropVariantInit(&value);
        if (SUCCEEDED(reader->GetMetadataByName(L"/grctlext/Delay", &value)) && value.vt == VT_UI2) delaysCs[i] = value.uiVal;
        PropVariantClear(&value);
    }
    *count = frames;
    return 0;
}

}  // namespace

extern "C" const char *ptb_plaza_last_error(void) { return ptb::tlsError; }

extern "C" void ptb_plaza_free(void *p) { std::free(p); }

extern "C" int ptb_com_init_sta(void) {
    const HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    return FAILED(hr) ? fail("CoInitializeEx(STA)", hr) : static_cast<int>(hr);
}

extern "C" int ptb_com_apartment(int *type, int *qualifier) {
    if (!type || !qualifier) return fail("ptb_com_apartment", E_INVALIDARG);
    APTTYPE t = APTTYPE_CURRENT;
    APTTYPEQUALIFIER q = APTTYPEQUALIFIER_NONE;
    const HRESULT hr = CoGetApartmentType(&t, &q);
    if (FAILED(hr)) return fail("CoGetApartmentType", hr);
    *type = static_cast<int>(t);
    *qualifier = static_cast<int>(q);
    return 0;
}

extern "C" int ptb_wic_decode_straight_rgba(const uint8_t *data, size_t len, uint32_t *w, uint32_t *h, uint8_t **rgba) {
    if (!w || !h || !rgba) return fail("ptb_wic_decode_straight_rgba", E_INVALIDARG);
    *w = 0;
    *h = 0;
    *rgba = nullptr;
    return decodeRGBA(data, len, w, h, rgba);
}

extern "C" int ptb_wic_encode_png_straight_rgba(const uint8_t *rgba, uint32_t w, uint32_t h, uint8_t **png, size_t *len) {
    if (!png || !len) return fail("ptb_wic_encode_png_straight_rgba", E_INVALIDARG);
    *png = nullptr;
    *len = 0;
    if (!rgba || w == 0 || h == 0 || w > kMaxSide || h > kMaxSide || static_cast<uint64_t>(w) * h * 4 > kMaxBytes)
        return fail("size", E_INVALIDARG);
    return encodePng(rgba, w, h, png, len);
}

extern "C" int ptb_wic_gif_delays(const uint8_t *data, size_t len, uint32_t *count, int32_t *delaysCs, uint32_t cap) {
    if (!count || (cap > 0 && !delaysCs)) return fail("ptb_wic_gif_delays", E_INVALIDARG);
    *count = 0;
    return gifDelays(data, len, count, delaysCs, cap);
}
