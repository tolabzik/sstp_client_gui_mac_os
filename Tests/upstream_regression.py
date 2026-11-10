#!/usr/bin/env python3
"""Apply the dependency patch to pristine 1.0.20 sources and test its C code.

Usage: python3 Tests/upstream_regression.py /path/to/sstp-client-1.0.20
Requires a C compiler and OpenSSL >= 1.0.2 headers/libraries. No installation,
VPN, root privileges or network access is used. OPENSSL_PREFIX may select a keg.
The supplied upstream source directory is never modified.
"""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def function(source, signature):
    start = source.index(signature)
    end = source.index("\n}", start) + 2
    return source[start:end] + "\n"


COMMON = r'''
#include <arpa/inet.h>
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>
typedef int status_t;
#define SSTP_FAIL -1
#define SSTP_OKAY 0
#define SSTP_VERIFY_NAME 1
#define SSTP_VERIFY_CERT 2
#define log_err(...) ((void) 0)
#define log_info(...) ((void) 0)
'''

PASSWORD_TEST = r'''
static void check_password(const char *password, const char *expected)
{
    FILE *file = tmpfile();
    assert(file);
    char *original = strdup(password);
    char output[4096];
    write_calls = 0;
    assert(sstp_pppd_write_password(fileno(file), password) == 0);
    assert(strcmp(original, password) == 0); /* Original MPPE secret unchanged. */
    assert(fseek(file, 0, SEEK_SET) == 0);
    size_t count = fread(output, 1, sizeof(output), file);
    assert(count == strlen(expected));
    assert(memcmp(output, expected, count) == 0);
    free(original);
    fclose(file);
}

static void password_tests(void)
{
    check_password("simple", "password \"simple\"\n");
    check_password("a\"b", "password \"a\\\"b\"\n");
    check_password("a\\b\\", "password \"a\\\\b\\\\\"\n");
    check_password("\\\"' #$;`", "password \"\\\\\\\"' #$;`\"\n");
    check_password("a\r\nb", "password \"a\\r\\nb\"\n");
    check_password("пароль", "password \"пароль\"\n");
    check_password("", "password \"\"\n");
    char password[256], expected[523];
    memset(password, '\\', 255);
    password[255] = 0;
    memcpy(expected, "password \"", 10);
    memset(expected + 10, '\\', 510);
    memcpy(expected + 520, "\"\n", 3);
    check_password(password, expected); /* Used to overread a 255-byte buffer. */
    write_calls = 1;
    assert(sstp_pppd_write_password(-1, "test") == -1);
    puts("PASS: password quoting, raw-secret preservation, 255-byte expansion, EINTR/short writes and write errors");
}
'''

TLS_TEST = r'''
static int handshake_step(SSL *ssl)
{
    int rc = SSL_do_handshake(ssl);
    if (rc == 1) return 1;
    int error = SSL_get_error(ssl, rc);
    assert(error == SSL_ERROR_WANT_READ || error == SSL_ERROR_WANT_WRITE);
    return 0;
}

static void tls_tests(const char *cert_path, const char *key_path, int trusted)
{
    SSL_CTX *server_ctx = SSL_CTX_new(TLS_server_method());
    SSL_CTX *client_ctx = SSL_CTX_new(TLS_client_method());
    assert(server_ctx && client_ctx);
    assert(SSL_CTX_use_certificate_file(server_ctx, cert_path, SSL_FILETYPE_PEM) == 1);
    assert(SSL_CTX_use_PrivateKey_file(server_ctx, key_path, SSL_FILETYPE_PEM) == 1);
    if (trusted)
        assert(SSL_CTX_load_verify_locations(client_ctx, cert_path, NULL) == 1);
    /* Match sstpc: inspect verification result on the established session. */
    SSL_CTX_set_verify(client_ctx, SSL_VERIFY_NONE, NULL);
    SSL *server = SSL_new(server_ctx), *client = SSL_new(client_ctx);
    assert(server && client);
    assert(sstp_stream_set_server_name(client, "vpn.example.test:8443") == 1);
    BIO *server_bio, *client_bio;
    assert(BIO_new_bio_pair(&server_bio, 0, &client_bio, 0) == 1);
    SSL_set_bio(server, server_bio, server_bio);
    SSL_set_bio(client, client_bio, client_bio);
    SSL_set_accept_state(server);
    SSL_set_connect_state(client);
    int server_done = 0, client_done = 0;
    for (int i = 0; i < 100 && !(server_done && client_done); i++)
    {
        if (!client_done) client_done = handshake_step(client);
        if (!server_done) server_done = handshake_step(server);
    }
    assert(server_done && client_done);
    assert(strcmp(SSL_get_servername(server, TLSEXT_NAMETYPE_host_name), "vpn.example.test") == 0);
    sstp_stream_st stream = { client };
    int flags = SSTP_VERIFY_NAME | SSTP_VERIFY_CERT;
    if (!trusted)
        assert(sstp_verify_cert(&stream, "vpn.example.test:8443", flags) == SSTP_FAIL);
    else
    {
        const char *matches[] = { "vpn.example.test", "vpn.example.test:8443",
            "vpn.example.test.:443", "VPN.EXAMPLE.TEST", "one.example.test",
            "192.0.2.1:444", "[2001:db8::1]:444" };
        const char *mismatches[] = { "unrelated.test", "wrong-cn.test",
            "two.one.example.test", "example.test", "vpn.partial.test",
            "192.0.2.2", "[2001:db8::2]:443" };
        for (size_t i = 0; i < sizeof(matches)/sizeof(matches[0]); i++)
            assert(sstp_verify_cert(&stream, matches[i], flags) == SSTP_OKAY);
        for (size_t i = 0; i < sizeof(mismatches)/sizeof(mismatches[0]); i++)
            assert(sstp_verify_cert(&stream, mismatches[i], flags) == SSTP_FAIL);
        assert(sstp_verify_cert(&stream, NULL, flags) == SSTP_FAIL);
    }
    SSL_free(client);
    SSL_free(server);
    client = SSL_new(client_ctx);
    assert(sstp_stream_set_server_name(client, "192.0.2.1:443") == 1);
    assert(SSL_get_servername(client, TLSEXT_NAMETYPE_host_name) == NULL);
    assert(sstp_stream_set_server_name(client, "[2001:db8::1]:443") == 1);
    assert(SSL_get_servername(client, TLSEXT_NAMETYPE_host_name) == NULL);
    SSL_free(client);
    SSL_CTX_free(client_ctx);
    SSL_CTX_free(server_ctx);
}

int main(int argc, char **argv)
{
    assert(argc == 3);
    password_tests();
    tls_tests(argv[1], argv[2], 1);
    tls_tests(argv[1], argv[2], 0);
    puts("PASS: same-session TLS chain + DNS SAN/IP SAN/wildcard/port validation, SNI without port, wrong identity and untrusted certificate rejection");
    return 0;
}
'''


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    upstream = Path(sys.argv[1]).resolve()
    repo = Path(__file__).resolve().parent.parent
    openssl_prefix = os.environ.get("OPENSSL_PREFIX")
    if not openssl_prefix:
        openssl_prefix = next((p for p in ["/opt/homebrew/opt/openssl@3", "/usr/local/opt/openssl@3"]
                               if Path(p).is_dir()), "")
    openssl = str(Path(openssl_prefix) / "bin/openssl") if openssl_prefix else "openssl"
    with tempfile.TemporaryDirectory(prefix="sstp-upstream-regression-") as temp:
        work = Path(temp)
        shutil.copytree(upstream / "src", work / "src")
        with (repo / "Patches/sstp-client-1.0.20-gui.patch").open("rb") as patch:
            subprocess.run(["patch", "-p1", "--batch", "--forward"], cwd=work, stdin=patch, check=True)
        pppd = (work / "src/sstp-pppd.c").read_text()
        client = (work / "src/sstp-client.c").read_text()
        stream = (work / "src/sstp-stream.c").read_text()
        util = (work / "src/sstp-util.c").read_text()
        option = (work / "src/sstp-option.c").read_text()
        assert 'vopts |= SSTP_VERIFY_CERT;' in client
        assert 'sstp-gui-fixes-1\\n' in option
        assert 'sstp_pppd_write_password(fd, opts->password)' in pppd
        # Compile the production functions themselves, not a reimplementation.
        program = COMMON + '#include "sstp-util.h"\n'
        program += r'''
static int write_calls;
static ssize_t regression_write(int fd, const void *data, size_t count)
{
    if (write_calls++ == 0) { errno = EINTR; return -1; }
    return write(fd, data, count > 7 ? 7 : count);
}
#define write regression_write
'''
        program += function(pppd, 'static int sstp_pppd_write_password(')
        program += '\n#undef write\n'
        for signature in ['static int is_ipv6(', 'static int is_ipv4(', 'static int is_hostname(',
                          'static int is_port(', 'void sstp_url_free(', 'status_t sstp_url_parse(']:
            program += function(util, signature)
        program += 'typedef struct { SSL *ssl; } sstp_stream_st;\n'
        program += function(stream, 'static int sstp_certificate_matches_host(')
        program += function(stream, 'status_t sstp_verify_cert(')
        program += function(stream, 'static int sstp_stream_set_server_name(')
        program += PASSWORD_TEST + TLS_TEST
        source = work / "regression.c"
        source.write_text(program)
        flags = ["-I" + str(Path(openssl_prefix) / "include"),
                 "-L" + str(Path(openssl_prefix) / "lib")] if openssl_prefix else []
        subprocess.run([os.environ.get("CC", "cc"), "-std=c99", "-Wall", "-Wextra", "-Werror",
                        "-fsanitize=" + os.environ.get("SANITIZERS", "undefined"), "-g", "-I" + str(work / "src"),
                        *flags, str(source), "-lssl", "-lcrypto", "-o", str(work / "regression")], check=True)
        cert, key = work / "server.pem", work / "server.key"
        subprocess.run([openssl, "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                        "-subj", "/CN=wrong-cn.test", "-addext",
                        "subjectAltName=DNS:vpn.example.test,DNS:*.example.test,DNS:v*.partial.test,IP:192.0.2.1,IP:2001:db8::1",
                        "-keyout", str(key), "-out", str(cert)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run([str(work / "regression"), str(cert), str(key)], check=True,
                       env={**os.environ, "ASAN_OPTIONS": "detect_leaks=0"})


if __name__ == "__main__":
    main()
