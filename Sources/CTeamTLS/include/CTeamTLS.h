#ifndef CTEAMTLS_H
#define CTEAMTLS_H

#include <stddef.h>
#include <stdint.h>

/// The version string of the OpenSSL this binary was linked against (static, from vcpkg).
const char *ptb_tls_openssl_version(void);

/// TLS 1.2 + TLS_PSK_WITH_AES_128_GCM_SHA256 only, the team link's wire suite (matches the Mac's
/// BonjourTeamTransport.parameters). Swift never sees OpenSSL headers; everything below is plain C.
typedef struct ptb_tls_ctx ptb_tls_ctx;
typedef struct ptb_tls ptb_tls;

enum { PTB_TLS_OK = 0, PTB_TLS_WANT_READ = -2, PTB_TLS_WANT_WRITE = -3, PTB_TLS_CLOSED = -4, PTB_TLS_FAILED = -5 };

/// NULL on failure (see ptb_tls_last_error). The key and identity are copied; the server accepts only `identity`.
ptb_tls_ctx *ptb_tls_ctx_new(int server, const uint8_t psk[32], const char *identity);
/// Zeroes the key copy. Free only after every ptb_tls made from it is closed.
void         ptb_tls_ctx_free(ptb_tls_ctx *);
/// `socket` must be a non-blocking socket; it is NOT closed by ptb_tls_close.
ptb_tls     *ptb_tls_new(ptb_tls_ctx *, uintptr_t socket);
/// OK, WANT_READ, WANT_WRITE, CLOSED (peer sent close_notify) or FAILED (message in ptb_tls_last_error).
int          ptb_tls_handshake(ptb_tls *);
/// > 0 bytes read, or a PTB_TLS_* code.
int          ptb_tls_read(ptb_tls *, uint8_t *buf, int cap);
/// > 0 bytes accepted (partial writes allowed), or a PTB_TLS_* code. Retry with the same data after WANT_*.
int          ptb_tls_write(ptb_tls *, const uint8_t *buf, int len);
/// Decrypted bytes already buffered, readable without socket readiness.
int          ptb_tls_pending(ptb_tls *);
/// Sends close_notify once without waiting, then frees. NULL is a no-op.
void         ptb_tls_close(ptb_tls *);
const char  *ptb_tls_cipher(ptb_tls *);        // NULL before the handshake completes
const char  *ptb_tls_version_name(ptb_tls *);  // e.g. "TLSv1.2"
/// The detail of the last FAILED / NULL on this thread. Never contains key material.
const char  *ptb_tls_last_error(void);
/// HMAC-SHA256 one-shot, for cross-checking the key derivation against Swift Crypto. 0 on success.
int          ptb_tls_hmac_sha256(const uint8_t *key, size_t klen, const uint8_t *msg, size_t mlen, uint8_t out[32]);
/// Frees the calling thread's OpenSSL state (OPENSSL_thread_stop). Call last on a thread that used TLS (CTeamTLSThread.c).
void         ptb_tls_thread_stop(void);

#endif
