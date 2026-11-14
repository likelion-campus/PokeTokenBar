#include "CTeamTLS.h"
#include <openssl/crypto.h>

const char *ptb_tls_openssl_version(void) { return OpenSSL_version(OPENSSL_VERSION); }
