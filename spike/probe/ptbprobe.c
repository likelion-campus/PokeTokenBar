// Throwaway (spec §9 experiment 2): Windows side of scripts/team-probe.swift.
// DNS-SD through the built-in windns API, TCP through Winsock, TLS 1.2 PSK through OpenSSL.
//   ptbprobe serve <code> [--once]
//   ptbprobe browse <code> [--host <host> --port <port>] [--once]
#define WIN32_LEAN_AND_MEAN
#define _CRT_SECURE_NO_WARNINGS
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <windns.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/hmac.h>
#include <openssl/sha.h>

#define SERVICE L"_ptbteam._tcp.local"
static const char *IDENTITY = "ptb-team-v1";
static unsigned char g_key[32];
static int g_once = 0;
static volatile LONG g_done = 0;

static void say(const char *fmt, ...) {
    SYSTEMTIME t; GetLocalTime(&t);
    printf("[%02d:%02d:%02d] ", t.wHour, t.wMinute, t.wSecond);
    va_list ap; va_start(ap, fmt); vprintf(fmt, ap); va_end(ap);
    printf("\n"); fflush(stdout);
}

static void derive_key(const char *code) {
    const char *info = "poketokenbar.team.psk.v1";
    unsigned int n = 0;
    HMAC(EVP_sha256(), code, (int)strlen(code), (const unsigned char *)info, strlen(info), g_key, &n);
    unsigned char digest[32]; SHA256(g_key, 32, digest);
    char hex[17]; for (int i = 0; i < 8; i++) sprintf(hex + i * 2, "%02x", digest[i]);
    say("KEY sha256 prefix %s (must match the other side)", hex);
}

static unsigned int psk_client(SSL *ssl, const char *hint, char *identity, unsigned int max_identity,
                               unsigned char *psk, unsigned int max_psk) {
    (void)ssl; (void)hint;
    if (max_identity <= strlen(IDENTITY) || max_psk < 32) return 0;
    strcpy(identity, IDENTITY); memcpy(psk, g_key, 32); return 32;
}
static unsigned int psk_server(SSL *ssl, const char *identity, unsigned char *psk, unsigned int max_psk) {
    (void)ssl;
    if (!identity || strcmp(identity, IDENTITY) != 0 || max_psk < 32) return 0;
    memcpy(psk, g_key, 32); return 32;
}

static SSL_CTX *make_ctx(int server) {
    SSL_CTX *ctx = SSL_CTX_new(server ? TLS_server_method() : TLS_client_method());
    SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);
    SSL_CTX_set_max_proto_version(ctx, TLS1_2_VERSION);
    if (SSL_CTX_set_cipher_list(ctx, "PSK-AES128-GCM-SHA256") != 1) { say("FAIL TLS cipher list"); exit(1); }
    if (server) SSL_CTX_set_psk_server_callback(ctx, psk_server); else SSL_CTX_set_psk_client_callback(ctx, psk_client);
    return ctx;
}

static void tls_error(const char *stage) {
    unsigned long e = ERR_get_error(); char buf[256]; ERR_error_string_n(e, buf, sizeof buf);
    say("FAIL %s %s (wsa %d)", stage, buf, WSAGetLastError());
}

static int read_line(SSL *ssl, char *out, int cap) {
    int n = 0;
    while (n < cap - 1) {
        char c; int r = SSL_read(ssl, &c, 1);
        if (r <= 0) return -1;
        if (c == '\n') break;
        out[n++] = c;
    }
    out[n] = 0; return n;
}

// ---- client side ----
static int talk(SOCKET s, const char *label) {
    say("TCP OK %s", label);
    SSL_CTX *ctx = make_ctx(0); SSL *ssl = SSL_new(ctx);
    SSL_set_fd(ssl, (int)s);
    if (SSL_connect(ssl) != 1) { tls_error("TLS"); return 0; }
    say("TLS OK %s %s", SSL_get_version(ssl), SSL_get_cipher_name(ssl));
    char host[256] = "windows"; DWORD len = sizeof host; GetComputerNameA(host, &len);
    char line[512]; sprintf(line, "ping %s %lld\n", host, (long long)time(NULL));
    if (SSL_write(ssl, line, (int)strlen(line)) <= 0) { tls_error("FRAME write"); return 0; }
    char reply[512];
    if (read_line(ssl, reply, sizeof reply) < 0) { tls_error("FRAME read"); return 0; }
    say("FRAME OK got: %s", reply);
    SSL_shutdown(ssl); SSL_free(ssl); SSL_CTX_free(ctx);
    return 1;
}

static int connect_host(const char *host, unsigned short port) {
    char service[16]; sprintf(service, "%u", port);
    struct addrinfo hints = {0}, *res = NULL; hints.ai_socktype = SOCK_STREAM; hints.ai_family = AF_UNSPEC;
    int rc = getaddrinfo(host, service, &hints, &res);
    if (rc != 0) { say("FAIL RESOLVE %s:%u getaddrinfo %d", host, port, rc); return 0; }
    for (struct addrinfo *a = res; a; a = a->ai_next) {
        SOCKET s = socket(a->ai_family, a->ai_socktype, a->ai_protocol);
        if (connect(s, a->ai_addr, (int)a->ai_addrlen) == 0) {
            char label[300]; sprintf(label, "%s:%u (%s)", host, port, a->ai_family == AF_INET6 ? "IPv6" : "IPv4");
            int ok = talk(s, label); closesocket(s); freeaddrinfo(res); return ok;
        }
        say("FAIL TCP %s:%u family %d wsa %d", host, port, a->ai_family, WSAGetLastError());
        closesocket(s);
    }
    freeaddrinfo(res); return 0;
}

static VOID WINAPI on_resolved(DWORD status, PVOID ctx, PDNS_SERVICE_INSTANCE inst) {
    (void)ctx;
    if (status != ERROR_SUCCESS || !inst) { say("FAIL RESOLVE dns status %lu", status); return; }
    char host[256] = ""; WideCharToMultiByte(CP_UTF8, 0, inst->pszHostName, -1, host, sizeof host, NULL, NULL);
    say("RESOLVED host %s port %u ip4 %s ip6 %s", host, inst->wPort, inst->ip4Address ? "yes" : "no", inst->ip6Address ? "yes" : "no");
    int ok = 0;
    if (inst->ip4Address) {
        struct in_addr a; a.S_un.S_addr = *inst->ip4Address; char ip[64]; inet_ntop(AF_INET, &a, ip, sizeof ip);
        ok = connect_host(ip, inst->wPort);
    }
    if (!ok) ok = connect_host(host, inst->wPort);
    if (ok && g_once) InterlockedExchange(&g_done, 1);
    DnsServiceFreeInstance(inst);
}

static VOID WINAPI on_browse(DWORD status, PVOID ctx, PDNS_RECORD records) {
    (void)ctx;
    if (status != ERROR_SUCCESS) { say("FAIL BROWSE dns status %lu", status); return; }
    for (PDNS_RECORD r = records; r; r = r->pNext) {
        if (r->wType != DNS_TYPE_PTR) continue;
        char name[512] = ""; WideCharToMultiByte(CP_UTF8, 0, r->Data.PTR.pNameHost, -1, name, sizeof name, NULL, NULL);
        say("FOUND %s (ttl %lu)", name, r->dwTtl);
        if (r->dwTtl == 0) continue;
        DNS_SERVICE_RESOLVE_REQUEST req = {0};
        req.Version = DNS_QUERY_REQUEST_VERSION1;
        req.QueryName = r->Data.PTR.pNameHost;
        req.pResolveCompletionCallback = on_resolved;
        DNS_SERVICE_CANCEL cancel;
        DNS_STATUS s = DnsServiceResolve(&req, &cancel);
        if (s != DNS_REQUEST_PENDING) say("FAIL RESOLVE start %ld", s);
    }
    DnsRecordListFree(records, DnsFreeRecordList);
}

static int run_browse(const char *host, unsigned short port) {
    if (host) { say("direct mode (no DNS-SD): %s:%u", host, port); return connect_host(host, port) ? 0 : 1; }
    DNS_SERVICE_BROWSE_REQUEST req = {0};
    req.Version = DNS_QUERY_REQUEST_VERSION1;
    req.QueryName = SERVICE;
    req.pBrowseCallback = on_browse;
    DNS_SERVICE_CANCEL cancel;
    DNS_STATUS s = DnsServiceBrowse(&req, &cancel);
    if (s != DNS_REQUEST_PENDING) { say("FAIL BROWSE start %ld", s); return 1; }
    say("BROWSING _ptbteam._tcp (Ctrl-C to quit)");
    for (int i = 0; !g_done && (!g_once || i < 200); i++) Sleep(100);
    return g_done || !g_once ? 0 : 1;
}

// ---- server side ----
static VOID WINAPI on_registered(DWORD status, PVOID ctx, PDNS_SERVICE_INSTANCE inst) {
    (void)ctx;
    if (status != ERROR_SUCCESS) { say("FAIL ADVERTISE dns status %lu", status); return; }
    char name[512] = ""; if (inst) WideCharToMultiByte(CP_UTF8, 0, inst->pszInstanceName, -1, name, sizeof name, NULL, NULL);
    say("ADVERTISED %s port %u", name, inst ? inst->wPort : 0);
    if (inst) DnsServiceFreeInstance(inst);
}

static int run_serve(void) {
    SOCKET ls = socket(AF_INET6, SOCK_STREAM, IPPROTO_TCP);
    DWORD off = 0; setsockopt(ls, IPPROTO_IPV6, IPV6_V6ONLY, (const char *)&off, sizeof off);
    struct sockaddr_in6 addr = {0}; addr.sin6_family = AF_INET6; addr.sin6_addr = in6addr_any;
    if (bind(ls, (struct sockaddr *)&addr, sizeof addr) != 0 || listen(ls, 8) != 0) { say("FAIL LISTEN wsa %d", WSAGetLastError()); return 1; }
    int alen = sizeof addr; getsockname(ls, (struct sockaddr *)&addr, &alen);
    unsigned short port = ntohs(addr.sin6_port);
    say("LISTENING port %u", port);

    wchar_t computer[128] = L"windows"; DWORD clen = 128; GetComputerNameExW(ComputerNameDnsHostname, computer, &clen);
    wchar_t host[200]; swprintf(host, 200, L"%s.local", computer);
    wchar_t instance[300]; swprintf(instance, 300, L"probe-win-%04x.%s", (unsigned)(GetTickCount() & 0xffff), SERVICE);
    PDNS_SERVICE_INSTANCE inst = DnsServiceConstructInstance(instance, host, NULL, NULL, port, 0, 0, 0, NULL, NULL);
    DNS_SERVICE_REGISTER_REQUEST req = {0};
    req.Version = DNS_QUERY_REQUEST_VERSION1;
    req.pServiceInstance = inst;
    req.pRegisterCompletionCallback = on_registered;
    DNS_SERVICE_CANCEL cancel;
    DWORD s = DnsServiceRegister(&req, &cancel);
    if (s != DNS_REQUEST_PENDING) say("FAIL ADVERTISE start %lu", s);

    SSL_CTX *ctx = make_ctx(1);
    for (;;) {
        struct sockaddr_storage peer; int plen = sizeof peer;
        SOCKET c = accept(ls, (struct sockaddr *)&peer, &plen);
        if (c == INVALID_SOCKET) { say("FAIL ACCEPT wsa %d", WSAGetLastError()); return 1; }
        char ip[80] = "?"; getnameinfo((struct sockaddr *)&peer, plen, ip, sizeof ip, NULL, 0, NI_NUMERICHOST);
        say("TCP OK incoming from %s", ip);
        SSL *ssl = SSL_new(ctx); SSL_set_fd(ssl, (int)c);
        if (SSL_accept(ssl) != 1) { tls_error("TLS"); SSL_free(ssl); closesocket(c); continue; }
        say("TLS OK %s %s", SSL_get_version(ssl), SSL_get_cipher_name(ssl));
        char line[512];
        if (read_line(ssl, line, sizeof line) >= 0) {
            char reply[600]; sprintf(reply, "pong %s\n", line);
            SSL_write(ssl, reply, (int)strlen(reply));
            say("FRAME OK got: %s", line);
            if (g_once) { SSL_shutdown(ssl); SSL_free(ssl); closesocket(c); DnsServiceDeRegister(&req, NULL); Sleep(300); return 0; }
        } else tls_error("FRAME read");
        SSL_free(ssl); closesocket(c);
    }
}

int main(int argc, char **argv) {
    if (argc < 3 || (strcmp(argv[1], "serve") != 0 && strcmp(argv[1], "browse") != 0)) {
        printf("usage:\n  ptbprobe serve <code> [--once]\n  ptbprobe browse <code> [--host <host> --port <port>] [--once]\n");
        return 2;
    }
    const char *host = NULL; unsigned short port = 0;
    for (int i = 3; i < argc; i++) {
        if (!strcmp(argv[i], "--once")) g_once = 1;
        else if (!strcmp(argv[i], "--host") && i + 1 < argc) host = argv[++i];
        else if (!strcmp(argv[i], "--port") && i + 1 < argc) port = (unsigned short)atoi(argv[++i]);
    }
    WSADATA wsa; WSAStartup(MAKEWORD(2, 2), &wsa);
    OSVERSIONINFOEXW v = {0}; v.dwOSVersionInfoSize = sizeof v;
    typedef LONG(WINAPI *RtlGetVersionFn)(OSVERSIONINFOEXW *);
    RtlGetVersionFn f = (RtlGetVersionFn)GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "RtlGetVersion");
    if (f) f(&v);
    say("ptbprobe on Windows build %lu, %s", v.dwBuildNumber, OpenSSL_version(OPENSSL_VERSION));
    derive_key(argv[2]);
    return strcmp(argv[1], "serve") == 0 ? run_serve() : run_browse(host, port);
}
