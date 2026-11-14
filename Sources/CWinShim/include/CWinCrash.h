#ifndef CWINCRASH_H
#define CWINCRASH_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Runs on a fresh thread before the dump, waited at most 500 ms. The app passes NULL: settings are never written
/// from a crashing process (the debounced sync and the verified plist backup already bound the loss).
typedef void (*ptb_crash_hook)(void);

/// The app version recorded in every crash record. Call before `ptb_crash_install`. Printable ASCII only is kept.
void ptb_crash_set_version(const char *utf8);

/// Opens `crash_log_path` for append (kept open for the session), remembers `dump_dir`, and installs the unhandled
/// exception filter and a SIGABRT handler. The filter body allocates nothing and takes no lock: it formats into
/// stack buffers and uses WriteFile. It chains to the previous filter and returns EXCEPTION_CONTINUE_SEARCH, so
/// Windows Error Reporting behaves as it did. Paths are UTF-16 (`wchar_t`). 0 on success, else a Win32 error code.
int ptb_crash_install(const uint16_t *crash_log_path, const uint16_t *dump_dir, ptb_crash_hook before_dump);

/// Points fd 2 and the C `stderr` at `path` (append, unbuffered), so the Swift runtime's "Fatal error: ..." line
/// lands in a file: the app is a GUI-subsystem exe and has no console. 0 on success, else an error code.
int ptb_crash_redirect_stderr(const uint16_t *path);

/// 1 when the environment variable `PTB_CRASH_DUMPS` is `1`: minidumps are OFF unless the user opted in (a dump holds
/// thread stacks, which can hold tokens or file contents). `ptb_crash_install` reads it once; the filter never does.
int ptb_crash_dumps_opted_in(void);

/// Selftest only: 0 = write through a bad pointer, 1 = read through one, 2 = abort().
void ptb_crash_selftest_trigger(int mode);

#ifdef __cplusplus
}
#endif

#endif
