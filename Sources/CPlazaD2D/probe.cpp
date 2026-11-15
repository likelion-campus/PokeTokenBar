// Availability: can this machine make a Direct2D, DirectWrite and WIC factory? Also DirectWrite's reading of a font file.
// The graphics DLLs are delay-loaded (Package.swift), so a machine without one still starts the app; this file checks the
// DLLs with LoadLibraryEx first and calls into them only when they loaded.
#include "CPlazaD2D.h"
#include "internal.h"

#include <windows.h>
#include <d2d1.h>
#include <dwrite.h>
#include <objbase.h>
#include <wincodec.h>

#include <cstdint>
#include <cstdio>
#include <initializer_list>

namespace {

using namespace ptb;

// Spelled out (not DEFINE_GUID / __uuidof), as in codec.cpp.
const GUID kClsidImagingFactory = {0xcacaf262, 0x9370, 0x4615, {0xa1, 0x3b, 0x9f, 0x55, 0x39, 0xda, 0x4c, 0x0a}};
const GUID kIidImagingFactory = {0xec5ec8a9, 0xc395, 0x4314, {0x9c, 0x77, 0x54, 0xd7, 0xa9, 0x35, 0xff, 0x70}};
const GUID kIidD2D1Factory = {0x06152247, 0x6f50, 0x465a, {0x92, 0x45, 0x11, 0x8b, 0xfd, 0x3b, 0x60, 0x07}};
const GUID kIidDWriteFactory = {0xb859ee5a, 0xd838, 0x4b5b, {0xa2, 0xe8, 0x1a, 0xdc, 0x7d, 0x93, 0xdb, 0x48}};

// True when the DLL loads from System32 (it then stays loaded: the delay-load helper finds it by name).
bool loadable(const wchar_t *dll, HRESULT *hr) {
    if (LoadLibraryExW(dll, nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32)) return true;
    *hr = HRESULT_FROM_WIN32(GetLastError());
    return false;
}

}  // namespace

extern "C" int ptb_gfx_probe(PTBGfxProbe *out) {
    if (!out) return fail("ptb_gfx_probe", E_INVALIDARG);
    out->wic = out->d2d = out->dwrite = 0;
    out->missingDlls = 0;
    const wchar_t *dlls[6] = {L"d2d1.dll", L"dwrite.dll", L"d3d11.dll", L"dxgi.dll", L"dcomp.dll", L"windowscodecs.dll"};
    HRESULT dllHr[6] = {S_OK, S_OK, S_OK, S_OK, S_OK, S_OK};
    for (int i = 0; i < 6; i++) {
        if (!loadable(dlls[i], &dllHr[i])) out->missingDlls |= 1u << i;
    }

    if (out->missingDlls & (1u << 5)) {
        out->wic = static_cast<int32_t>(dllHr[5]);
    } else {
        HRESULT hr = ensureCom();
        Com<IWICImagingFactory> factory;
        if (SUCCEEDED(hr)) {
            hr = CoCreateInstance(kClsidImagingFactory, nullptr, CLSCTX_INPROC_SERVER, kIidImagingFactory,
                                  reinterpret_cast<void **>(factory.out()));
        }
        out->wic = static_cast<int32_t>(hr);
    }
    if (out->missingDlls & (1u << 0)) {
        out->d2d = static_cast<int32_t>(dllHr[0]);
    } else {
        Com<ID2D1Factory> factory;
        out->d2d = static_cast<int32_t>(D2D1CreateFactory(D2D1_FACTORY_TYPE_MULTI_THREADED, kIidD2D1Factory, nullptr,
                                                          reinterpret_cast<void **>(factory.out())));
    }
    if (out->missingDlls & (1u << 1)) {
        out->dwrite = static_cast<int32_t>(dllHr[1]);
    } else {
        Com<IDWriteFactory> factory;
        out->dwrite = static_cast<int32_t>(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, kIidDWriteFactory,
                                                               reinterpret_cast<IUnknown **>(factory.out())));
    }
    int first = 0;
    for (const int32_t code : {out->wic, out->d2d, out->dwrite}) {
        if (first == 0 && code < 0) first = code;
    }
    if (first != 0) {
        std::snprintf(tlsError, sizeof(tlsError), "graphics factories: wic=0x%08X d2d=0x%08X dwrite=0x%08X missing=0x%X",
                      static_cast<unsigned>(out->wic), static_cast<unsigned>(out->d2d), static_cast<unsigned>(out->dwrite),
                      out->missingDlls);
    }
    return first;
}

extern "C" int ptb_dwrite_analyze_font(const uint16_t *path, int *supported, uint32_t *faces) {
    if (!path || !supported || !faces) return fail("ptb_dwrite_analyze_font", E_INVALIDARG);
    *supported = 0;
    *faces = 0;
    HRESULT dllHr = S_OK;
    if (!loadable(L"dwrite.dll", &dllHr)) return fail("dwrite.dll", dllHr);
    Com<IDWriteFactory> factory;
    HRESULT hr = DWriteCreateFactory(DWRITE_FACTORY_TYPE_ISOLATED, kIidDWriteFactory, reinterpret_cast<IUnknown **>(factory.out()));
    if (FAILED(hr)) return fail("DWriteCreateFactory", hr);
    Com<IDWriteFontFile> file;
    hr = factory->CreateFontFileReference(reinterpret_cast<const WCHAR *>(path), nullptr, file.out());
    if (FAILED(hr)) return fail("CreateFontFileReference", hr);
    BOOL isSupported = FALSE;
    DWRITE_FONT_FILE_TYPE fileType = DWRITE_FONT_FILE_TYPE_UNKNOWN;
    DWRITE_FONT_FACE_TYPE faceType = DWRITE_FONT_FACE_TYPE_UNKNOWN;
    UINT32 count = 0;
    hr = file->Analyze(&isSupported, &fileType, &faceType, &count);
    if (FAILED(hr)) return fail("Analyze", hr);
    *supported = isSupported ? 1 : 0;
    *faces = count;
    return 0;
}
