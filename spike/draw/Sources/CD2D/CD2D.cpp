#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <d3d11.h>
#include <d2d1_3.h>
#include <d2d1effects.h>
#include <dwrite_3.h>
#include <wincodec.h>
#include <wrl/client.h>
#include <string>
#include <vector>
#include "CD2D.h"

using Microsoft::WRL::ComPtr;

static std::string g_error;
static void fail(const char *what, HRESULT hr) {
    char buf[200]; snprintf(buf, sizeof buf, "%s failed: 0x%08lx", what, (unsigned long)hr); g_error = buf;
}
static std::wstring wide(const char *utf8) {
    int n = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, nullptr, 0);
    std::wstring w(n > 0 ? n - 1 : 0, L'\0');
    if (n > 0) MultiByteToWideChar(CP_UTF8, 0, utf8, -1, &w[0], n);
    return w;
}

struct PTBCanvas {
    int width = 0, height = 0;
    ComPtr<ID2D1Factory1> d2d;
    ComPtr<ID2D1DeviceContext> ctx;
    ComPtr<IDWriteFactory5> dwrite;
    ComPtr<IWICImagingFactory> wic;
    ComPtr<ID2D1Bitmap1> scene, result;
    ComPtr<IDWriteFontSetBuilder1> fontBuilder;
    ComPtr<IDWriteFontCollection1> fonts;
    std::vector<ComPtr<ID2D1Bitmap1>> bitmaps;
};

extern "C" const char *ptb_last_error(void) { return g_error.c_str(); }

extern "C" PTBCanvas *ptb_canvas_create(int width, int height, int hardware) {
    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) { fail("CoInitializeEx", hr); return nullptr; }
    auto c = new PTBCanvas(); c->width = width; c->height = height;
    ComPtr<ID3D11Device> d3d;
    hr = D3D11CreateDevice(nullptr, hardware ? D3D_DRIVER_TYPE_HARDWARE : D3D_DRIVER_TYPE_WARP, nullptr,
                           D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0, D3D11_SDK_VERSION, &d3d, nullptr, nullptr);
    if (FAILED(hr)) { fail("D3D11CreateDevice", hr); delete c; return nullptr; }
    ComPtr<IDXGIDevice> dxgi; d3d.As(&dxgi);
    D2D1_FACTORY_OPTIONS options = {};
    hr = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, __uuidof(ID2D1Factory1), &options, (void **)c->d2d.GetAddressOf());
    if (FAILED(hr)) { fail("D2D1CreateFactory", hr); delete c; return nullptr; }
    ComPtr<ID2D1Device> device;
    hr = c->d2d->CreateDevice(dxgi.Get(), &device);
    if (FAILED(hr)) { fail("CreateDevice", hr); delete c; return nullptr; }
    hr = device->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE, &c->ctx);
    if (FAILED(hr)) { fail("CreateDeviceContext", hr); delete c; return nullptr; }
    D2D1_BITMAP_PROPERTIES1 props = D2D1::BitmapProperties1(
        D2D1_BITMAP_OPTIONS_TARGET, D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), 96, 96);
    hr = c->ctx->CreateBitmap(D2D1::SizeU(width, height), nullptr, 0, &props, &c->scene);
    if (SUCCEEDED(hr)) hr = c->ctx->CreateBitmap(D2D1::SizeU(width, height), nullptr, 0, &props, &c->result);
    if (FAILED(hr)) { fail("CreateBitmap(target)", hr); delete c; return nullptr; }
    hr = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory5), (IUnknown **)c->dwrite.GetAddressOf());
    if (FAILED(hr)) { fail("DWriteCreateFactory", hr); delete c; return nullptr; }
    hr = c->dwrite->CreateFontSetBuilder(&c->fontBuilder);
    if (FAILED(hr)) { fail("CreateFontSetBuilder", hr); delete c; return nullptr; }
    hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&c->wic));
    if (FAILED(hr)) { fail("CoCreateInstance(WIC)", hr); delete c; return nullptr; }
    c->ctx->SetUnitMode(D2D1_UNIT_MODE_PIXELS);
    return c;
}

extern "C" int ptb_add_font(PTBCanvas *c, const char *utf8Path) {
    ComPtr<IDWriteFontFile> file;
    HRESULT hr = c->dwrite->CreateFontFileReference(wide(utf8Path).c_str(), nullptr, &file);
    if (SUCCEEDED(hr)) hr = c->fontBuilder->AddFontFile(file.Get());
    if (FAILED(hr)) { fail("AddFontFile", hr); return 0; }
    ComPtr<IDWriteFontSet> set;
    hr = c->fontBuilder->CreateFontSet(&set);
    if (SUCCEEDED(hr)) { c->fonts.Reset(); hr = c->dwrite->CreateFontCollectionFromFontSet(set.Get(), &c->fonts); }
    if (FAILED(hr)) { fail("CreateFontCollectionFromFontSet", hr); return 0; }
    return 1;
}

extern "C" int ptb_load_png(PTBCanvas *c, const char *utf8Path) {
    ComPtr<IWICBitmapDecoder> decoder;
    HRESULT hr = c->wic->CreateDecoderFromFilename(wide(utf8Path).c_str(), nullptr, GENERIC_READ, WICDecodeMetadataCacheOnLoad, &decoder);
    if (FAILED(hr)) { fail("CreateDecoderFromFilename", hr); return -1; }
    ComPtr<IWICBitmapFrameDecode> frame; decoder->GetFrame(0, &frame);
    ComPtr<IWICFormatConverter> converter; c->wic->CreateFormatConverter(&converter);
    hr = converter->Initialize(frame.Get(), GUID_WICPixelFormat32bppPBGRA, WICBitmapDitherTypeNone, nullptr, 0, WICBitmapPaletteTypeCustom);
    if (FAILED(hr)) { fail("WIC convert", hr); return -1; }
    ComPtr<ID2D1Bitmap1> bitmap;
    hr = c->ctx->CreateBitmapFromWicBitmap(converter.Get(), nullptr, &bitmap);
    if (FAILED(hr)) { fail("CreateBitmapFromWicBitmap", hr); return -1; }
    c->bitmaps.push_back(bitmap);
    return (int)c->bitmaps.size() - 1;
}

extern "C" void ptb_begin(PTBCanvas *c, float r, float g, float b) {
    c->ctx->SetTarget(c->scene.Get());
    c->ctx->BeginDraw();
    c->ctx->SetAntialiasMode(D2D1_ANTIALIAS_MODE_ALIASED);
    c->ctx->Clear(D2D1::ColorF(r, g, b, 1));
}

extern "C" void ptb_draw_bitmap(PTBCanvas *c, int bitmap, float sx, float sy, float sw, float sh,
                                float dx, float dy, float dw, float dh, float alpha, int flipX) {
    if (bitmap < 0 || bitmap >= (int)c->bitmaps.size()) return;
    D2D1_RECT_F src = D2D1::RectF(sx, sy, sx + sw, sy + sh), dst = D2D1::RectF(dx, dy, dx + dw, dy + dh);
    if (flipX) c->ctx->SetTransform(D2D1::Matrix3x2F::Scale(-1, 1, D2D1::Point2F(dx + dw / 2, dy + dh / 2)));
    c->ctx->DrawBitmap(c->bitmaps[bitmap].Get(), &dst, alpha, D2D1_INTERPOLATION_MODE_NEAREST_NEIGHBOR, &src);
    if (flipX) c->ctx->SetTransform(D2D1::Matrix3x2F::Identity());
}

extern "C" void ptb_fill_round_rect(PTBCanvas *c, float x, float y, float w, float h, float radius, float r, float g, float b, float a) {
    ComPtr<ID2D1SolidColorBrush> brush; c->ctx->CreateSolidColorBrush(D2D1::ColorF(r, g, b, a), &brush);
    c->ctx->FillRoundedRectangle(D2D1::RoundedRect(D2D1::RectF(x, y, x + w, y + h), radius, radius), brush.Get());
}

extern "C" void ptb_draw_text(PTBCanvas *c, const char *utf8Text, const char *utf8Family, float size, int bold,
                              float x, float y, float r, float g, float b, int aliased, int colour) {
    std::wstring text = wide(utf8Text), family = wide(utf8Family);
    ComPtr<IDWriteTextFormat> format;
    DWRITE_FONT_WEIGHT weight = bold ? DWRITE_FONT_WEIGHT_BOLD : DWRITE_FONT_WEIGHT_NORMAL;
    HRESULT hr = E_FAIL;
    BOOL exists = FALSE; UINT32 index = 0;
    if (c->fonts) c->fonts->FindFamilyName(family.c_str(), &index, &exists);
    hr = c->dwrite->CreateTextFormat(family.c_str(), exists ? c->fonts.Get() : nullptr, weight, DWRITE_FONT_STYLE_NORMAL,
                                     DWRITE_FONT_STRETCH_NORMAL, size, L"ko-kr", &format);
    if (FAILED(hr)) { fail("CreateTextFormat", hr); return; }
    if (!exists) g_error = "font family not in the private collection, used the system: " + std::string(utf8Family);
    ComPtr<ID2D1SolidColorBrush> brush; c->ctx->CreateSolidColorBrush(D2D1::ColorF(r, g, b, 1), &brush);
    c->ctx->SetTextAntialiasMode(aliased ? D2D1_TEXT_ANTIALIAS_MODE_ALIASED : D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
    c->ctx->DrawText(text.c_str(), (UINT32)text.size(), format.Get(), D2D1::RectF(x, y, (float)c->width, (float)c->height), brush.Get(),
                     colour ? D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT : D2D1_DRAW_TEXT_OPTIONS_NONE);
}

extern "C" int ptb_end_with_multiply(PTBCanvas *c, float x, float y, float w, float h, float r, float g, float b) {
    HRESULT hr = c->ctx->EndDraw();
    if (FAILED(hr)) { fail("EndDraw(scene)", hr); return 0; }
    ComPtr<ID2D1Effect> flood, crop, blend;
    hr = c->ctx->CreateEffect(CLSID_D2D1Flood, &flood);
    if (SUCCEEDED(hr)) hr = c->ctx->CreateEffect(CLSID_D2D1Crop, &crop);
    if (SUCCEEDED(hr)) hr = c->ctx->CreateEffect(CLSID_D2D1Blend, &blend);
    if (FAILED(hr)) { fail("CreateEffect", hr); return 0; }
    flood->SetValue(D2D1_FLOOD_PROP_COLOR, D2D1::Vector4F(r, g, b, 1));
    crop->SetInputEffect(0, flood.Get());
    crop->SetValue(D2D1_CROP_PROP_RECT, D2D1::Vector4F(x, y, x + w, y + h));
    blend->SetInput(0, c->scene.Get());
    blend->SetInputEffect(1, crop.Get());
    blend->SetValue(D2D1_BLEND_PROP_MODE, D2D1_BLEND_MODE_MULTIPLY);
    c->ctx->SetTarget(c->result.Get());
    c->ctx->BeginDraw();
    c->ctx->Clear(D2D1::ColorF(0, 0, 0, 1));
    c->ctx->DrawImage(c->scene.Get());
    c->ctx->PushAxisAlignedClip(D2D1::RectF(x, y, x + w, y + h), D2D1_ANTIALIAS_MODE_ALIASED);
    c->ctx->DrawImage(blend.Get());
    c->ctx->PopAxisAlignedClip();
    hr = c->ctx->EndDraw();
    if (FAILED(hr)) { fail("EndDraw(result)", hr); return 0; }
    return 1;
}

extern "C" int ptb_save_png(PTBCanvas *c, const char *utf8Path) {
    D2D1_BITMAP_PROPERTIES1 props = D2D1::BitmapProperties1(
        D2D1_BITMAP_OPTIONS_CPU_READ | D2D1_BITMAP_OPTIONS_CANNOT_DRAW,
        D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), 96, 96);
    ComPtr<ID2D1Bitmap1> copy;
    HRESULT hr = c->ctx->CreateBitmap(D2D1::SizeU(c->width, c->height), nullptr, 0, &props, &copy);
    if (SUCCEEDED(hr)) { D2D1_POINT_2U origin = {0, 0}; hr = copy->CopyFromBitmap(&origin, c->result.Get(), nullptr); }
    D2D1_MAPPED_RECT mapped = {};
    if (SUCCEEDED(hr)) hr = copy->Map(D2D1_MAP_OPTIONS_READ, &mapped);
    if (FAILED(hr)) { fail("read back", hr); return 0; }
    ComPtr<IWICStream> stream; ComPtr<IWICBitmapEncoder> encoder; ComPtr<IWICBitmapFrameEncode> frame;
    hr = c->wic->CreateStream(&stream);
    if (SUCCEEDED(hr)) hr = stream->InitializeFromFilename(wide(utf8Path).c_str(), GENERIC_WRITE);
    if (SUCCEEDED(hr)) hr = c->wic->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder);
    if (SUCCEEDED(hr)) hr = encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache);
    if (SUCCEEDED(hr)) hr = encoder->CreateNewFrame(&frame, nullptr);
    if (SUCCEEDED(hr)) hr = frame->Initialize(nullptr);
    if (SUCCEEDED(hr)) hr = frame->SetSize(c->width, c->height);
    WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
    if (SUCCEEDED(hr)) hr = frame->SetPixelFormat(&format);
    if (SUCCEEDED(hr)) hr = frame->WritePixels(c->height, mapped.pitch, mapped.pitch * c->height, mapped.bits);
    if (SUCCEEDED(hr)) hr = frame->Commit();
    if (SUCCEEDED(hr)) hr = encoder->Commit();
    copy->Unmap();
    if (FAILED(hr)) { fail("PNG encode", hr); return 0; }
    return 1;
}

extern "C" void ptb_canvas_free(PTBCanvas *c) { delete c; }
#endif
