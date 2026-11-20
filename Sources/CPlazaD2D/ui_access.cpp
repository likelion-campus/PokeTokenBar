// The overlay scroll lane's IAccessible (CPlazaD2DAccess.h).
#include "CPlazaD2DAccess.h"
#include "internal.h"

#include <oleacc.h>
#include <oleauto.h>

#include <cstdio>
#include <cstdlib>
#include <new>

namespace {

const wchar_t *kPos = L"PTB.ScrollPos";
const wchar_t *kRange = L"PTB.ScrollRange";

int propValue(HWND h, const wchar_t *name) {
    return static_cast<int>(reinterpret_cast<intptr_t>(GetPropW(h, name)));
}

/// ROLE_SYSTEM_SCROLLBAR over the window's standard client object.
class LaneAccessible final : public IAccessible {
public:
    LaneAccessible(HWND hwnd, IAccessible *inner) : hwnd_(hwnd), inner_(inner) {}
    ~LaneAccessible() { if (inner_) inner_->Release(); }

    // IUnknown
    STDMETHODIMP QueryInterface(REFIID riid, void **out) override {
        if (!out) return E_POINTER;
        if (riid == __uuidof(IUnknown) || riid == __uuidof(IDispatch) || riid == __uuidof(IAccessible)) {
            *out = static_cast<IAccessible *>(this);
            AddRef();
            return S_OK;
        }
        *out = nullptr;
        return E_NOINTERFACE;
    }
    STDMETHODIMP_(ULONG) AddRef() override { return static_cast<ULONG>(InterlockedIncrement(&refs_)); }
    STDMETHODIMP_(ULONG) Release() override {
        const LONG n = InterlockedDecrement(&refs_);
        if (n == 0) delete this;
        return static_cast<ULONG>(n);
    }

    // IDispatch (the standard object's)
    STDMETHODIMP GetTypeInfoCount(UINT *n) override { return inner_->GetTypeInfoCount(n); }
    STDMETHODIMP GetTypeInfo(UINT i, LCID l, ITypeInfo **t) override { return inner_->GetTypeInfo(i, l, t); }
    STDMETHODIMP GetIDsOfNames(REFIID r, LPOLESTR *names, UINT c, LCID l, DISPID *ids) override { return inner_->GetIDsOfNames(r, names, c, l, ids); }
    STDMETHODIMP Invoke(DISPID d, REFIID r, LCID l, WORD f, DISPPARAMS *p, VARIANT *v, EXCEPINFO *e, UINT *u) override {
        return inner_->Invoke(d, r, l, f, p, v, e, u);
    }

    // IAccessible: the three answers that make it a scroll bar, the rest the standard object's
    STDMETHODIMP get_accRole(VARIANT child, VARIANT *role) override {
        if (!role) return E_POINTER;
        if (child.vt == VT_I4 && child.lVal == CHILDID_SELF) {
            role->vt = VT_I4;
            role->lVal = ROLE_SYSTEM_SCROLLBAR;
            return S_OK;
        }
        return inner_->get_accRole(child, role);
    }
    STDMETHODIMP get_accValue(VARIANT child, BSTR *value) override {
        if (!value) return E_POINTER;
        if (child.vt == VT_I4 && child.lVal == CHILDID_SELF) {
            const int range = propValue(hwnd_, kRange), pos = propValue(hwnd_, kPos);
            int percent = range > 0 ? static_cast<int>((static_cast<long long>(pos) * 100 + range / 2) / range) : 0;
            if (percent < 0) percent = 0;
            if (percent > 100) percent = 100;
            wchar_t text[16];
            swprintf_s(text, L"%d%%", percent);
            *value = SysAllocString(text);
            return *value ? S_OK : E_OUTOFMEMORY;
        }
        return inner_->get_accValue(child, value);
    }
    STDMETHODIMP get_accParent(IDispatch **p) override { return inner_->get_accParent(p); }
    STDMETHODIMP get_accChildCount(long *n) override { return inner_->get_accChildCount(n); }
    STDMETHODIMP get_accChild(VARIANT c, IDispatch **d) override { return inner_->get_accChild(c, d); }
    STDMETHODIMP get_accName(VARIANT c, BSTR *n) override { return inner_->get_accName(c, n); }
    STDMETHODIMP get_accDescription(VARIANT c, BSTR *n) override { return inner_->get_accDescription(c, n); }
    STDMETHODIMP get_accState(VARIANT c, VARIANT *s) override { return inner_->get_accState(c, s); }
    STDMETHODIMP get_accHelp(VARIANT c, BSTR *n) override { return inner_->get_accHelp(c, n); }
    STDMETHODIMP get_accHelpTopic(BSTR *f, VARIANT c, long *t) override { return inner_->get_accHelpTopic(f, c, t); }
    STDMETHODIMP get_accKeyboardShortcut(VARIANT c, BSTR *n) override { return inner_->get_accKeyboardShortcut(c, n); }
    STDMETHODIMP get_accFocus(VARIANT *c) override { return inner_->get_accFocus(c); }
    STDMETHODIMP get_accSelection(VARIANT *c) override { return inner_->get_accSelection(c); }
    STDMETHODIMP get_accDefaultAction(VARIANT c, BSTR *n) override { return inner_->get_accDefaultAction(c, n); }
    STDMETHODIMP accSelect(long f, VARIANT c) override { return inner_->accSelect(f, c); }
    STDMETHODIMP accLocation(long *l, long *t, long *w, long *h, VARIANT c) override { return inner_->accLocation(l, t, w, h, c); }
    STDMETHODIMP accNavigate(long d, VARIANT s, VARIANT *e) override { return inner_->accNavigate(d, s, e); }
    STDMETHODIMP accHitTest(long x, long y, VARIANT *c) override { return inner_->accHitTest(x, y, c); }
    STDMETHODIMP accDoDefaultAction(VARIANT c) override { return inner_->accDoDefaultAction(c); }
    STDMETHODIMP put_accName(VARIANT c, BSTR n) override { return inner_->put_accName(c, n); }
    STDMETHODIMP put_accValue(VARIANT, BSTR) override { return E_NOTIMPL; }

private:
    LONG refs_ = 1;
    HWND hwnd_;
    IAccessible *inner_;
};

}  // namespace

extern "C" {

int64_t ptb_scrollbar_get_object(void *hwnd, uint64_t wParam, int64_t lParam) {
    if (!hwnd || static_cast<DWORD>(lParam) != static_cast<DWORD>(OBJID_CLIENT)) return 0;
    HWND h = static_cast<HWND>(hwnd);
    IAccessible *inner = nullptr;
    if (FAILED(CreateStdAccessibleObject(h, OBJID_CLIENT, __uuidof(IAccessible), reinterpret_cast<void **>(&inner))) || !inner) return 0;
    LaneAccessible *object = new (std::nothrow) LaneAccessible(h, inner);
    if (!object) {
        inner->Release();
        return 0;
    }
    const LRESULT result = LresultFromObject(__uuidof(IAccessible), static_cast<WPARAM>(wParam), object);
    object->Release();
    return SUCCEEDED(static_cast<HRESULT>(result)) ? static_cast<int64_t>(result) : 0;
}

int ptb_scrollbar_probe(void *hwnd, int32_t *role, int32_t *state, uint16_t *value, uint32_t cap) {
    if (!hwnd || !role || !state || !value || cap == 0) return static_cast<int>(E_INVALIDARG);
    ptb::ensureCom();
    IAccessible *acc = nullptr;
    HRESULT hr = AccessibleObjectFromWindow(static_cast<HWND>(hwnd), OBJID_CLIENT, __uuidof(IAccessible), reinterpret_cast<void **>(&acc));
    if (FAILED(hr) || !acc) return static_cast<int>(FAILED(hr) ? hr : E_FAIL);
    VARIANT self;
    VariantInit(&self);
    self.vt = VT_I4;
    self.lVal = CHILDID_SELF;
    VARIANT r, s;
    VariantInit(&r);
    VariantInit(&s);
    hr = acc->get_accRole(self, &r);
    *role = SUCCEEDED(hr) && r.vt == VT_I4 ? r.lVal : -1;
    hr = acc->get_accState(self, &s);
    *state = SUCCEEDED(hr) && s.vt == VT_I4 ? s.lVal : -1;
    BSTR text = nullptr;
    value[0] = 0;
    hr = acc->get_accValue(self, &text);
    if (SUCCEEDED(hr) && text) {
        UINT n = SysStringLen(text);
        if (n >= cap) n = cap - 1;
        for (UINT i = 0; i < n; i++) value[i] = text[i];
        value[n] = 0;
    }
    if (text) SysFreeString(text);
    acc->Release();
    return 0;
}

}  // extern "C"
