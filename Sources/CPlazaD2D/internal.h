// Shared by codec.cpp and probe.cpp (not part of the C ABI): COM smart pointer, per-thread error text, per-thread apartment.
#ifndef CPLAZAD2D_INTERNAL_H
#define CPLAZAD2D_INTERNAL_H

#include <windows.h>
#include <objbase.h>

#include <cstdio>

namespace ptb {

template <class T> struct Com {
    T *p = nullptr;
    Com() = default;
    Com(const Com &) = delete;
    Com &operator=(const Com &) = delete;
    ~Com() { if (p) p->Release(); }
    T **out() { return &p; }
    T *operator->() const { return p; }
};

inline thread_local char tlsError[192] = "";

inline int fail(const char *stage, HRESULT hr) {
    std::snprintf(tlsError, sizeof(tlsError), "%s: 0x%08X", stage, static_cast<unsigned>(hr));
    return static_cast<int>(hr);
}

// The apartment a thread that calls in without one gets: the MTA, released when the thread ends.
struct ComThread {
    bool holdsCount = false;
    ~ComThread() { if (holdsCount) CoUninitialize(); }
};
inline thread_local ComThread tlsCom;
inline thread_local bool tlsComReady = false;

inline HRESULT ensureCom() {
    if (tlsComReady) return S_OK;
    const HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (hr == S_OK || hr == S_FALSE) {  // S_FALSE: this thread is an MTA already; the call still took a count
        tlsCom.holdsCount = true;
        tlsComReady = true;
        return S_OK;
    }
    if (hr == RPC_E_CHANGED_MODE) {  // an STA (the main thread): WIC works there as it is, and there is nothing to release
        tlsComReady = true;
        return S_OK;
    }
    return hr;
}

}  // namespace ptb

#endif
