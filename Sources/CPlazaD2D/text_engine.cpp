// The text engine's fonts (text.h): the DirectWrite factory, the private collection from the bundled files, the fallback chain,
// hhea metrics scaled as CoreText scales them, cached text formats.
#include "text.h"

#include <windows.h>

#include <cmath>
#include <cwchar>

namespace ptb {
namespace {

// The bundled fonts by number, and the system font each is replaced by when its file is missing (logged by Swift). Galmuri and
// Pretendard both have Hangul; Malgun Gothic is the Korean UI font every Windows 10 / 11 has.
const wchar_t *const kExpectedFamily[kFontCount] = {L"Galmuri11", L"Galmuri14", L"Pretendard", L"Segoe UI Emoji"};
const wchar_t *const kMissingFamily[kFontCount] = {L"Malgun Gothic", L"Malgun Gothic", L"Malgun Gothic", L"Segoe UI Emoji"};

// What the emoji font is asked for first, before the system fallback: the emoji blocks and the joiners and selectors that make
// sequences of them (only reached for characters the asked font does not have).
const DWRITE_UNICODE_RANGE kEmojiRanges[] = {
    {0x1F000, 0x1FAFF},  // mahjong ... symbols and pictographs extended-A (regional indicators 1F1E6-1F1FF included)
    {0x2600, 0x27BF},    // miscellaneous symbols, dingbats
    {0x2300, 0x23FF},    // technical (watch, hourglass, ...)
    {0x2B00, 0x2BFF},    // arrows, stars
    {0x200D, 0x200D},    // zero width joiner
    {0x20E3, 0x20E3},    // combining enclosing keycap
    {0xFE0F, 0xFE0F},    // emoji presentation selector
    {0xE0020, 0xE007F},  // tags (subdivision flags)
    {0x3030, 0x3030}, {0x303D, 0x303D}, {0x3297, 0x3297}, {0x3299, 0x3299},
};

bool loadDWrite(HRESULT *hr) {
    if (LoadLibraryExW(L"dwrite.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32)) return true;
    *hr = HRESULT_FROM_WIN32(GetLastError());
    return false;
}

uint16_t be16(const uint8_t *p) { return static_cast<uint16_t>((p[0] << 8) | p[1]); }

// CoreText's scale of a design-unit value: the units-per-em ratio rounded to 16.16 fixed point, times the size (measured: font-metrics.json).
double coreTextScaled(int units, uint32_t unitsPerEm, double size) {
    if (unitsPerEm == 0) return 0;
    const double ratio = std::nearbyint(std::fabs(static_cast<double>(units)) * 65536.0 / unitsPerEm) / 65536.0;
    return size * ratio;
}

}  // namespace

TextEngine::~TextEngine() = default;

int TextEngine::init(int mode) {
    measuringMode = mode;
    HRESULT hr = S_OK;
    if (!loadDWrite(&hr)) return fail("dwrite.dll", hr);
    hr = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory5), reinterpret_cast<IUnknown **>(factory.out()));
    if (FAILED(hr)) return fail("DWriteCreateFactory(IDWriteFactory5)", hr);
    hr = factory->CreateFontSetBuilder(builder.out());
    if (FAILED(hr)) return fail("CreateFontSetBuilder", hr);
    // IDWriteFactory's overload, named through the base: IDWriteFactory3 declares another GetSystemFontCollection.
    hr = static_cast<IDWriteFactory *>(factory.get())->GetSystemFontCollection(systemFonts.out(), FALSE);
    if (FAILED(hr)) return fail("GetSystemFontCollection", hr);
    return 0;
}

int TextEngine::addFontFile(const wchar_t *path) {
    if (!builder) return fail("addFontFile after finish", E_UNEXPECTED);
    Ref<IDWriteFontFile> file;
    HRESULT hr = factory->CreateFontFileReference(path, nullptr, file.out());
    if (SUCCEEDED(hr)) hr = builder->AddFontFile(file.get());
    if (FAILED(hr)) {
        filesFailed++;
        return fail("AddFontFile", hr);
    }
    filesAdded++;
    return 0;
}

std::wstring TextEngine::findPrivate(const wchar_t *expected) {
    if (!privateFonts) return L"";
    UINT32 index = 0;
    BOOL exists = FALSE;
    if (SUCCEEDED(privateFonts->FindFamilyName(expected, &index, &exists)) && exists) return expected;
    // A file whose family is spelled differently ("Galmuri11 Regular"): the first family that starts with the expected name.
    const size_t n = std::wcslen(expected);
    for (UINT32 i = 0; i < privateFonts->GetFontFamilyCount(); i++) {
        Ref<IDWriteFontFamily> family;
        Ref<IDWriteLocalizedStrings> names;
        IDWriteFontCollection *base = privateFonts.get();  // IDWriteFontCollection1 overloads GetFontFamily
        if (FAILED(base->GetFontFamily(i, family.out())) || FAILED(family->GetFamilyNames(names.out()))) continue;
        UINT32 length = 0;
        if (FAILED(names->GetStringLength(0, &length))) continue;
        std::wstring name(length + 1, L'\0');
        if (FAILED(names->GetString(0, &name[0], length + 1))) continue;
        name.resize(length);
        if (name.compare(0, n, expected) == 0) return name;
    }
    return L"";
}

int TextEngine::finish() {
    if (!builder) return 0;
    HRESULT hr = S_OK;
    if (filesAdded > 0) {  // no bundled file at all: no private collection, every font stands in from the system
        Ref<IDWriteFontSet> set;
        hr = builder->CreateFontSet(set.out());
        if (FAILED(hr)) return fail("CreateFontSet", hr);
        hr = factory->CreateFontCollectionFromFontSet(set.get(), privateFonts.out());
        if (FAILED(hr)) return fail("CreateFontCollectionFromFontSet", hr);
    }
    builder.reset();
    for (int f = 0; f < kFontEmoji; f++) families[f] = findPrivate(kExpectedFamily[f]);

    Ref<IDWriteFontFallbackBuilder> chain;
    hr = factory->CreateFontFallbackBuilder(chain.out());
    if (FAILED(hr)) return fail("CreateFontFallbackBuilder", hr);
    const WCHAR *emoji[] = {L"Segoe UI Emoji"};
    hr = chain->AddMapping(kEmojiRanges, static_cast<UINT32>(sizeof(kEmojiRanges) / sizeof(kEmojiRanges[0])), emoji, 1,
                           systemFonts.get(), nullptr, nullptr, 1.0f);
    if (FAILED(hr)) return fail("AddMapping(emoji)", hr);
    Ref<IDWriteFontFallback> system;
    hr = factory->GetSystemFontFallback(system.out());
    if (FAILED(hr)) return fail("GetSystemFontFallback", hr);
    hr = chain->AddMappings(system.get());
    if (FAILED(hr)) return fail("AddMappings(system)", hr);
    hr = chain->CreateFontFallback(fallback.out());
    if (FAILED(hr)) return fail("CreateFontFallback", hr);
    return 0;
}

TextEngine::Family TextEngine::family(int font) const {
    Family out;
    if (font < 0 || font >= kFontCount) font = kFontGalmuri14;
    if (font != kFontEmoji && !families[font].empty()) {
        out.name = families[font];
        out.collection = privateFonts.get();
        out.privateFont = true;
    } else {
        out.name = (font == kFontEmoji) ? kExpectedFamily[kFontEmoji] : kMissingFamily[font];
        out.collection = systemFonts.get();
    }
    return out;
}

int TextEngine::face(int font, int weight, Ref<IDWriteFontFace> &out) {
    const Family f = family(font);
    if (!f.collection) return fail("font collection", E_UNEXPECTED);
    UINT32 index = 0;
    BOOL exists = FALSE;
    HRESULT hr = f.collection->FindFamilyName(f.name.c_str(), &index, &exists);
    if (SUCCEEDED(hr) && !exists) hr = static_cast<HRESULT>(0x88985002L);  // DWRITE_E_NOFONT
    Ref<IDWriteFontFamily> family;
    if (SUCCEEDED(hr)) hr = f.collection->GetFontFamily(index, family.out());
    Ref<IDWriteFont> match;
    if (SUCCEEDED(hr)) {
        hr = family->GetFirstMatchingFont(static_cast<DWRITE_FONT_WEIGHT>(weight), DWRITE_FONT_STRETCH_NORMAL, DWRITE_FONT_STYLE_NORMAL,
                                          match.out());
    }
    if (SUCCEEDED(hr)) hr = match->CreateFontFace(out.out());
    return SUCCEEDED(hr) ? 0 : fail("font face", hr);
}

Hhea TextEngine::hheaOf(IDWriteFontFace *face) {
    Hhea h;
    DWRITE_FONT_METRICS m = {};
    face->GetMetrics(&m);
    h.unitsPerEm = m.designUnitsPerEm;
    const void *data = nullptr;
    UINT32 size = 0;
    void *context = nullptr;
    BOOL exists = FALSE;
    if (SUCCEEDED(face->TryGetFontTable(DWRITE_MAKE_OPENTYPE_TAG('h', 'h', 'e', 'a'), &data, &size, &context, &exists)) && exists) {
        if (size >= 10) {
            const uint8_t *p = static_cast<const uint8_t *>(data);
            h.ascender = static_cast<int16_t>(be16(p + 4));
            h.descender = static_cast<int16_t>(be16(p + 6));
            h.lineGap = static_cast<int16_t>(be16(p + 8));
            h.found = true;
        }
        face->ReleaseFontTable(context);
    }
    if (!h.found) {  // a font without hhea (never seen): DirectWrite's own metrics stand in
        h.ascender = m.ascent;
        h.descender = -static_cast<int>(m.descent);
        h.lineGap = m.lineGap;
    }
    return h;
}

TextMetrics TextEngine::metrics(IDWriteFontFace *face, double size) {
    Hhea h;
    bool cached = false;
    AcquireSRWLockShared(&lock);
    for (const HheaEntry &e : hheaCache) {
        if (e.face.get() == face) { h = e.hhea; cached = true; break; }
    }
    ReleaseSRWLockShared(&lock);
    if (!cached) {
        h = hheaOf(face);
        AcquireSRWLockExclusive(&lock);
        HheaEntry e;
        e.face.p = face;
        face->AddRef();
        e.hhea = h;
        hheaCache.push_back(std::move(e));
        ReleaseSRWLockExclusive(&lock);
    }
    TextMetrics t;
    t.ascent = coreTextScaled(h.ascender, h.unitsPerEm, size);
    t.descent = coreTextScaled(h.descender, h.unitsPerEm, size);
    t.leading = coreTextScaled(h.lineGap, h.unitsPerEm, size);
    return t;
}

int TextEngine::format(int font, int weight, float size, Ref<IDWriteTextFormat> &out) {
    AcquireSRWLockShared(&lock);
    for (const FormatEntry &e : formats) {
        if (e.font == font && e.weight == weight && e.size == size) { out = e.format; break; }
    }
    ReleaseSRWLockShared(&lock);
    if (out) return 0;
    const Family f = family(font);
    Ref<IDWriteTextFormat> made;
    HRESULT hr = factory->CreateTextFormat(f.name.c_str(), f.collection, static_cast<DWRITE_FONT_WEIGHT>(weight), DWRITE_FONT_STYLE_NORMAL,
                                           DWRITE_FONT_STRETCH_NORMAL, size, L"ko-kr", made.out());
    if (FAILED(hr)) return fail("CreateTextFormat", hr);
    made->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
    Ref<IDWriteTextFormat1> withFallback;
    hr = made->QueryInterface(__uuidof(IDWriteTextFormat1), reinterpret_cast<void **>(withFallback.out()));
    if (SUCCEEDED(hr)) hr = withFallback->SetFontFallback(fallback.get());
    if (FAILED(hr)) return fail("SetFontFallback", hr);
    AcquireSRWLockExclusive(&lock);
    FormatEntry e;
    e.font = font;
    e.weight = weight;
    e.size = size;
    e.format = made;
    formats.push_back(std::move(e));
    ReleaseSRWLockExclusive(&lock);
    out = made;
    return 0;
}

}  // namespace ptb
