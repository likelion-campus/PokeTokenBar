// The common file dialogs, the task dialog and one accessibility property are COM or packed structs, which the Swift side
// cannot call or import: the Backup & transfer rows of the popover (stage 7 Task 15) live behind these functions.
#include "CWinShim.h"

#include <windows.h>
#include <commctrl.h>
#include <oleacc.h>
#include <shobjidl.h>
#include <shlobj.h>

#include <cstring>
#include <cwchar>

#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "oleacc.lib")
#pragma comment(lib, "oleaut32.lib")

namespace {

// Spelled out (not DEFINE_GUID / __uuidof) so the link needs no uuid.lib and no MS extensions.
const GUID kClsidFileOpenDialog = {0xdc1c5a9c, 0xe88a, 0x4dde, {0xa5, 0xa1, 0x60, 0xf8, 0x2a, 0x20, 0xae, 0xf7}};
const GUID kClsidFileSaveDialog = {0xc0b4e2f3, 0xba21, 0x4773, {0x8d, 0xba, 0x33, 0x5e, 0xc9, 0x46, 0xeb, 0x8b}};
const GUID kIidFileDialog = {0x42f85136, 0xdb7e, 0x439c, {0x85, 0xf1, 0xe4, 0x07, 0x5d, 0x13, 0x5f, 0xc8}};
const GUID kIidShellItem = {0x43826d1e, 0xe718, 0x42ee, {0xbc, 0x55, 0xa1, 0xe2, 0x61, 0xc3, 0x7b, 0xfe}};
const GUID kFolderIdDocuments = {0xfdd39ad0, 0x238f, 0x46af, {0xad, 0xb4, 0x6c, 0x85, 0x48, 0x03, 0x69, 0xc7}};
// Remembers the last folder per app (the Mac's panels remember theirs), apart from the other dialogs of the machine.
const GUID kClientGuid = {0x7c1e2b14, 0x5d3a, 0x4f6b, {0x9a, 0x1c, 0x3e, 0x8f, 0x0b, 0x2d, 0x4a, 0x61}};
const GUID kClsidAccPropServices = {0xb5f8350b, 0x0548, 0x48b1, {0xa6, 0xee, 0x88, 0xbd, 0x00, 0xb4, 0xa5, 0xe7}};
const GUID kIidAccPropServices = {0x6e26e776, 0x04f0, 0x495d, {0x80, 0xe4, 0x33, 0x30, 0x35, 0x2e, 0x31, 0x69}};
const GUID kIidAccessible = {0x618736e0, 0x3c3d, 0x11cf, {0x81, 0x0c, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}};
const GUID kPropIdAccValue = {0x123fe443, 0x211a, 0x4615, {0x95, 0x27, 0xc4, 0x5a, 0x7e, 0x93, 0x71, 0x7a}};

template <class T> struct Com {
    T *p = nullptr;
    ~Com() { if (p) p->Release(); }
    T **out() { return &p; }
    T *operator->() const { return p; }
};

IFileDialog *g_activeFileDialog = nullptr;
HWND g_taskDialog = nullptr;

HRESULT runFileDialog(void *owner, bool save, const uint16_t *title, const uint16_t *defaultName, const uint16_t *filterName,
                      const uint16_t *filterSpec, const uint16_t *defaultExt, uint16_t *out, uint32_t outCap) {
    Com<IFileDialog> dlg;
    HRESULT hr = CoCreateInstance(save ? kClsidFileSaveDialog : kClsidFileOpenDialog, nullptr, CLSCTX_INPROC_SERVER,
                                  kIidFileDialog, reinterpret_cast<void **>(dlg.out()));
    if (FAILED(hr)) return hr;
    DWORD options = 0;
    dlg->GetOptions(&options);
    options |= FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST | FOS_NOCHANGEDIR;
    options |= save ? FOS_OVERWRITEPROMPT : FOS_FILEMUSTEXIST;
    dlg->SetOptions(options);
    dlg->SetClientGuid(kClientGuid);
    if (title) dlg->SetTitle(reinterpret_cast<LPCWSTR>(title));
    COMDLG_FILTERSPEC spec = {reinterpret_cast<LPCWSTR>(filterName), reinterpret_cast<LPCWSTR>(filterSpec)};
    if (filterName && filterSpec) {
        dlg->SetFileTypes(1, &spec);
        dlg->SetFileTypeIndex(1);
    }
    if (defaultExt) dlg->SetDefaultExtension(reinterpret_cast<LPCWSTR>(defaultExt));
    if (save && defaultName) dlg->SetFileName(reinterpret_cast<LPCWSTR>(defaultName));
    // Documents is where it opens the first time (a OneDrive-redirected Documents comes out right: the shell resolves it).
    Com<IShellItem> documents;
    if (SUCCEEDED(SHGetKnownFolderItem(kFolderIdDocuments, KF_FLAG_DEFAULT, nullptr, kIidShellItem,
                                       reinterpret_cast<void **>(documents.out())))) {
        dlg->SetDefaultFolder(documents.p);
    }
    g_activeFileDialog = dlg.p;
    hr = dlg->Show(static_cast<HWND>(owner));
    g_activeFileDialog = nullptr;
    if (FAILED(hr)) return hr;
    Com<IShellItem> item;
    hr = dlg->GetResult(item.out());
    if (FAILED(hr)) return hr;
    PWSTR path = nullptr;
    hr = item->GetDisplayName(SIGDN_FILESYSPATH, &path);
    if (FAILED(hr)) return hr;
    const size_t length = std::wcslen(path);
    if (length + 1 > outCap) {
        CoTaskMemFree(path);
        return HRESULT_FROM_WIN32(ERROR_INSUFFICIENT_BUFFER);
    }
    std::memcpy(out, path, (length + 1) * sizeof(uint16_t));
    CoTaskMemFree(path);
    return S_OK;
}

HRESULT CALLBACK taskDialogCallback(HWND hwnd, UINT message, WPARAM, LPARAM, LONG_PTR) {
    if (message == TDN_CREATED) g_taskDialog = hwnd;
    if (message == TDN_DESTROYED) g_taskDialog = nullptr;
    return S_OK;
}

typedef HRESULT(WINAPI *TaskDialogIndirectFn)(const TASKDIALOGCONFIG *, int *, int *, BOOL *);

}  // namespace

extern "C" int32_t ptb_file_dialog(void *owner, int32_t save, const uint16_t *title, const uint16_t *default_name,
                                   const uint16_t *filter_name, const uint16_t *filter_spec, const uint16_t *default_ext,
                                   uint16_t *out, uint32_t out_cap) {
    if (!out || out_cap < 2) return static_cast<int32_t>(E_INVALIDARG);
    out[0] = 0;
    const HRESULT init = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);  // RPC_E_CHANGED_MODE: usable anyway
    const HRESULT hr = runFileDialog(owner, save != 0, title, default_name, filter_name, filter_spec, default_ext, out, out_cap);
    if (SUCCEEDED(init)) CoUninitialize();
    if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) return 1;
    return static_cast<int32_t>(hr);
}

extern "C" int32_t ptb_file_dialog_close(void) {
    if (!g_activeFileDialog) return 0;
    g_activeFileDialog->Close(HRESULT_FROM_WIN32(ERROR_CANCELLED));
    return 1;
}

extern "C" int32_t ptb_task_dialog(void *owner, const uint16_t *window_title, const uint16_t *heading, const uint16_t *content,
                                   int32_t icon, const uint16_t *const *buttons, int32_t count, int32_t default_index,
                                   int32_t *chosen) {
    if (!chosen || !buttons || count < 1 || count > 8) return static_cast<int32_t>(E_INVALIDARG);
    *chosen = -1;
    // comctl32 version 6 only (the manifest): a process without it has no TaskDialogIndirect, and a static import would
    // stop that process (the test runner) from loading at all, so it is looked up when needed.
    HMODULE comctl = GetModuleHandleW(L"comctl32.dll");  // the version the manifest activated, when the app's controls loaded it
    if (!comctl) comctl = LoadLibraryExW(L"comctl32.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    const auto taskDialog = comctl ? reinterpret_cast<TaskDialogIndirectFn>(GetProcAddress(comctl, "TaskDialogIndirect")) : nullptr;
    if (!taskDialog) return static_cast<int32_t>(E_NOTIMPL);
    TASKDIALOG_BUTTON list[8];
    for (int32_t i = 0; i < count; i++) {
        list[i].nButtonID = 1000 + i;
        list[i].pszButtonText = reinterpret_cast<PCWSTR>(buttons[i]);
    }
    TASKDIALOGCONFIG config;
    std::memset(&config, 0, sizeof(config));
    config.cbSize = sizeof(config);
    config.hwndParent = static_cast<HWND>(owner);
    config.dwFlags = TDF_ALLOW_DIALOG_CANCELLATION | TDF_POSITION_RELATIVE_TO_WINDOW;
    config.pszWindowTitle = reinterpret_cast<PCWSTR>(window_title);
    config.pszMainInstruction = reinterpret_cast<PCWSTR>(heading);
    config.pszContent = reinterpret_cast<PCWSTR>(content);
    config.pszMainIcon = icon == 1 ? TD_WARNING_ICON : icon == 2 ? TD_ERROR_ICON : icon == 3 ? TD_INFORMATION_ICON : nullptr;
    config.cButtons = static_cast<UINT>(count);
    config.pButtons = list;
    config.nDefaultButton = 1000 + (default_index >= 0 && default_index < count ? default_index : 0);
    config.pfCallback = taskDialogCallback;
    int selected = 0;
    const HRESULT hr = taskDialog(&config, &selected, nullptr, nullptr);
    g_taskDialog = nullptr;
    if (FAILED(hr)) return static_cast<int32_t>(hr);
    *chosen = selected >= 1000 && selected < 1000 + count ? selected - 1000 : -1;  // Esc and the close box: IDCANCEL
    return 0;
}

extern "C" void *ptb_task_dialog_window(void) { return g_taskDialog; }

extern "C" int32_t ptb_acc_set_value(void *hwnd, const uint16_t *text) {
    if (!hwnd || !text) return static_cast<int32_t>(E_INVALIDARG);
    const HRESULT init = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    Com<IAccPropServices> services;
    HRESULT hr = CoCreateInstance(kClsidAccPropServices, nullptr, CLSCTX_INPROC_SERVER, kIidAccPropServices,
                                  reinterpret_cast<void **>(services.out()));
    if (SUCCEEDED(hr)) {
        hr = services->SetHwndPropStr(static_cast<HWND>(hwnd), OBJID_CLIENT, CHILDID_SELF, kPropIdAccValue,
                                      reinterpret_cast<LPCWSTR>(text));
    }
    if (SUCCEEDED(init)) CoUninitialize();
    return static_cast<int32_t>(hr);
}

extern "C" int32_t ptb_acc_describe(void *hwnd, uint16_t *name, uint32_t name_cap, uint16_t *value, uint32_t value_cap) {
    if (!hwnd) return static_cast<int32_t>(E_INVALIDARG);
    if (name && name_cap) name[0] = 0;
    if (value && value_cap) value[0] = 0;
    const HRESULT init = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    IAccessible *accessible = nullptr;
    HRESULT hr = AccessibleObjectFromWindow(static_cast<HWND>(hwnd), OBJID_CLIENT, kIidAccessible, reinterpret_cast<void **>(&accessible));
    if (SUCCEEDED(hr) && accessible) {
        VARIANT self;
        VariantInit(&self);
        self.vt = VT_I4;
        self.lVal = CHILDID_SELF;
        auto copy = [](BSTR text, uint16_t *out, uint32_t cap) {
            UINT length = SysStringLen(text);
            if (length >= cap) length = cap - 1;
            std::memcpy(out, text, length * sizeof(uint16_t));
            out[length] = 0;
        };
        BSTR text = nullptr;
        if (name && name_cap && SUCCEEDED(accessible->get_accName(self, &text)) && text) {
            copy(text, name, name_cap);
            SysFreeString(text);
        }
        text = nullptr;
        if (value && value_cap && SUCCEEDED(accessible->get_accValue(self, &text)) && text) {
            copy(text, value, value_cap);
            SysFreeString(text);
        }
        accessible->Release();
    }
    if (SUCCEEDED(init)) CoUninitialize();
    return static_cast<int32_t>(hr);
}
