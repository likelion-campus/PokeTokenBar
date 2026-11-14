#include "CTeamTLS.h"
#include <openssl/crypto.h>
#include <openssl/err.h>
#include <openssl/hmac.h>
#include <openssl/ssl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define PTB_IDENTITY_MAX 64

struct ptb_tls_ctx {
    SSL_CTX *ssl_ctx;
    int server;
    uint8_t key[32];
    char identity[PTB_IDENTITY_MAX];
};

struct ptb_tls {
    SSL *ssl;
};

#ifdef _WIN32
#define PTB_THREAD_LOCAL __declspec(thread)
#else
#define PTB_THREAD_LOCAL _Thread_local
#endif
static PTB_THREAD_LOCAL char g_error[320];

const char *ptb_tls_openssl_version(void) { return OpenSSL_version(OPENSSL_VERSION); }
const char *ptb_tls_last_error(void) { return g_error; }

/// Records `stage` plus the queued OpenSSL errors (library/reason strings only, never key bytes).
static void set_error(const char *stage, int detail) {
    size_t n = (size_t)snprintf(g_error, sizeof g_error, "%s", stage);
    if (detail != 0 && n < sizeof g_error) n += (size_t)snprintf(g_error + n, sizeof g_error - n, " (ssl_error %d)", detail);
    unsigned long e;
    for (int i = 0; i < 3 && (e = ERR_get_error()) != 0 && n < sizeof g_error; i++) {
        char buf[160];
        ERR_error_string_n(e, buf, sizeof buf);
        n += (size_t)snprintf(g_error + n, sizeof g_error - n, ": %s", buf);
    }
    ERR_clear_error();
}

static unsigned int psk_client(SSL *ssl, const char *hint, char *identity, unsigned int max_identity,
                               unsigned char *psk, unsigned int max_psk) {
    (void)hint;
    ptb_tls_ctx *c = (ptb_tls_ctx *)SSL_CTX_get_app_data(SSL_get_SSL_CTX(ssl));
    if (!c || strlen(c->identity) >= max_identity || max_psk < 32) return 0;
    strcpy(identity, c->identity);
    memcpy(psk, c->key, 32);
    return 32;
}

static unsigned int psk_server(SSL *ssl, const char *identity, unsigned char *psk, unsigned int max_psk) {
    ptb_tls_ctx *c = (ptb_tls_ctx *)SSL_CTX_get_app_data(SSL_get_SSL_CTX(ssl));
    if (!c || !identity || strcmp(identity, c->identity) != 0 || max_psk < 32) return 0;  // 0 = unknown_psk_identity
    memcpy(psk, c->key, 32);
    return 32;
}

ptb_tls_ctx *ptb_tls_ctx_new(int server, const uint8_t psk[32], const char *identity) {
    g_error[0] = 0;
    if (!psk || !identity || strlen(identity) >= PTB_IDENTITY_MAX) { set_error("bad PSK arguments", 0); return NULL; }
    if (OPENSSL_init_ssl(0, NULL) != 1) { set_error("OpenSSL init failed", 0); return NULL; }  // one-time, thread-safe
    ptb_tls_ctx *c = (ptb_tls_ctx *)calloc(1, sizeof *c);
    if (!c) { set_error("out of memory", 0); return NULL; }
    memcpy(c->key, psk, 32);
    strcpy(c->identity, identity);
    c->server = server != 0;
    c->ssl_ctx = SSL_CTX_new(server ? TLS_server_method() : TLS_client_method());
    if (!c->ssl_ctx) { set_error("SSL_CTX_new failed", 0); goto fail; }
    if (SSL_CTX_set_min_proto_version(c->ssl_ctx, TLS1_2_VERSION) != 1
        || SSL_CTX_set_max_proto_version(c->ssl_ctx, TLS1_2_VERSION) != 1) { set_error("cannot pin TLS 1.2", 0); goto fail; }
    if (SSL_CTX_set_cipher_list(c->ssl_ctx, "PSK-AES128-GCM-SHA256") != 1) { set_error("cipher list rejected", 0); goto fail; }
    SSL_CTX_set_mode(c->ssl_ctx, SSL_MODE_ENABLE_PARTIAL_WRITE | SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER);
    if (SSL_CTX_set_app_data(c->ssl_ctx, c) != 1) { set_error("cannot attach key to context", 0); goto fail; }
    if (server) SSL_CTX_set_psk_server_callback(c->ssl_ctx, psk_server);
    else SSL_CTX_set_psk_client_callback(c->ssl_ctx, psk_client);
    return c;
fail:
    ptb_tls_ctx_free(c);
    return NULL;
}

void ptb_tls_ctx_free(ptb_tls_ctx *c) {
    if (!c) return;
    if (c->ssl_ctx) SSL_CTX_free(c->ssl_ctx);
    OPENSSL_cleanse(c->key, sizeof c->key);
    free(c);
}

ptb_tls *ptb_tls_new(ptb_tls_ctx *c, uintptr_t socket) {
    g_error[0] = 0;
    if (!c) { set_error("no context", 0); return NULL; }
    ptb_tls *t = (ptb_tls *)calloc(1, sizeof *t);
    if (!t) { set_error("out of memory", 0); return NULL; }
    t->ssl = SSL_new(c->ssl_ctx);
    if (!t->ssl) { set_error("SSL_new failed", 0); free(t); return NULL; }
    if (SSL_set_fd(t->ssl, (int)socket) != 1) { set_error("SSL_set_fd failed", 0); SSL_free(t->ssl); free(t); return NULL; }
    if (c->server) SSL_set_accept_state(t->ssl); else SSL_set_connect_state(t->ssl);
    return t;
}

/// Maps an SSL_* return into a PTB_TLS_* code. `r` is the call's return value (<= 0).
static int classify(ptb_tls *t, int r, const char *stage) {
    int e = SSL_get_error(t->ssl, r);
    switch (e) {
        case SSL_ERROR_WANT_READ: ERR_clear_error(); return PTB_TLS_WANT_READ;
        case SSL_ERROR_WANT_WRITE: ERR_clear_error(); return PTB_TLS_WANT_WRITE;
        case SSL_ERROR_ZERO_RETURN: ERR_clear_error(); return PTB_TLS_CLOSED;
        default: set_error(stage, e); return PTB_TLS_FAILED;
    }
}

int ptb_tls_handshake(ptb_tls *t) {
    if (!t || !t->ssl) return PTB_TLS_FAILED;
    ERR_clear_error();
    int r = SSL_do_handshake(t->ssl);
    if (r == 1) return PTB_TLS_OK;
    return classify(t, r, "TLS handshake failed");
}

int ptb_tls_read(ptb_tls *t, uint8_t *buf, int cap) {
    if (!t || !t->ssl || !buf || cap <= 0) return PTB_TLS_FAILED;
    ERR_clear_error();
    int r = SSL_read(t->ssl, buf, cap);
    if (r > 0) return r;
    return classify(t, r, "TLS read failed");
}

int ptb_tls_write(ptb_tls *t, const uint8_t *buf, int len) {
    if (!t || !t->ssl || !buf || len <= 0) return PTB_TLS_FAILED;
    ERR_clear_error();
    int r = SSL_write(t->ssl, buf, len);
    if (r > 0) return r;
    return classify(t, r, "TLS write failed");
}

int ptb_tls_pending(ptb_tls *t) { return (t && t->ssl) ? SSL_pending(t->ssl) : 0; }

void ptb_tls_close(ptb_tls *t) {
    if (!t) return;
    if (t->ssl) {
        if (SSL_is_init_finished(t->ssl)) { ERR_clear_error(); SSL_shutdown(t->ssl); }  // close_notify, no wait
        SSL_free(t->ssl);
    }
    ERR_clear_error();
    free(t);
}

const char *ptb_tls_cipher(ptb_tls *t) {
    return (t && t->ssl && SSL_is_init_finished(t->ssl)) ? SSL_get_cipher_name(t->ssl) : NULL;
}
const char *ptb_tls_version_name(ptb_tls *t) {
    return (t && t->ssl && SSL_is_init_finished(t->ssl)) ? SSL_get_version(t->ssl) : NULL;
}

int ptb_tls_hmac_sha256(const uint8_t *key, size_t klen, const uint8_t *msg, size_t mlen, uint8_t out[32]) {
    unsigned int n = 0;
    return HMAC(EVP_sha256(), key, (int)klen, msg, mlen, out, &n) && n == 32 ? 0 : -1;
}
