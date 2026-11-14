#include "CTeamTLS.h"
#include <openssl/crypto.h>

/* OpenSSL linked statically on Windows gets no DLL_THREAD_DETACH, so a thread that used it must release its
   per-thread state (error queue, DRBG) itself before it ends. */
void ptb_tls_thread_stop(void) { OPENSSL_thread_stop(); }
