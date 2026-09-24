#include "tlsServer.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>

#define ACCEPT_POLL_MS 50
/* A client that stops talking releases the server thread after this long */
#define IO_TIMEOUT_S 10
#define TPKT_HEADER_LENGTH 4
#define X224_REQUEST_MAX 512
#define CERTIFICATE_LIFETIME_S 3600
#define RSA_BITS 2048

/*
 * X.224 Connection Confirm with an RDP Negotiation Response that selects PROTOCOL_SSL:
 * TPKT header (version 3, length 19), then LI 14, CC code 0xD0, references and class,
 * then type 0x02, flags 0, length 8 and the selected protocol 0x00000001, little-endian
 */
static const uint8_t connectionConfirmTls[] = { 0x03, 0x00, 0x00, 0x13, 0x0E, 0xD0, 0x00, 0x00, 0x12, 0x34,
                                                0x00, 0x02, 0x00, 0x08, 0x00, 0x01, 0x00, 0x00, 0x00 };

struct TlsServer {
    int listener;
    uint16_t port;
    pthread_t thread;
    atomic_bool stopping;
    atomic_int continued;
    SSL_CTX* tls;
    char* certificatePem;
};

static void fail(const char* what)
{
    fprintf(stderr, "tls server: %s failed\n", what);
    ERR_print_errors_fp(stderr);
    abort();
}

static X509* selfSignedCertificate(EVP_PKEY* key)
{
    X509* certificate = X509_new();
    if (!certificate)
        fail("X509_new");

    X509_NAME* name = X509_get_subject_name(certificate);
    if (!X509_set_version(certificate, 2) || !ASN1_INTEGER_set(X509_get_serialNumber(certificate), 1) ||
        !X509_gmtime_adj(X509_getm_notBefore(certificate), 0) ||
        !X509_gmtime_adj(X509_getm_notAfter(certificate), CERTIFICATE_LIFETIME_S) ||
        !X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC, (const unsigned char*)"VibeRDP test server", -1,
                                    -1, 0) ||
        !X509_set_issuer_name(certificate, name) || !X509_set_pubkey(certificate, key) ||
        !X509_sign(certificate, key, EVP_sha256()))
        fail("building the certificate");
    return certificate;
}

static char* toPem(X509* certificate)
{
    BIO* bio = BIO_new(BIO_s_mem());
    if (!bio || !PEM_write_bio_X509(bio, certificate))
        fail("PEM_write_bio_X509");

    char* data = NULL;
    const long length = BIO_get_mem_data(bio, &data);
    char* pem = calloc((size_t)length + 1, 1);
    if (!pem)
        abort();
    memcpy(pem, data, (size_t)length);
    BIO_free(bio);
    return pem;
}

static bool readFully(int fd, uint8_t* buffer, size_t length)
{
    size_t done = 0;
    while (done < length)
    {
        const ssize_t received = recv(fd, buffer + done, length - done, 0);
        if (received <= 0)
            return false;
        done += (size_t)received;
    }
    return true;
}

/* Reads the whole Connection Request, whatever it asks for: the server always chooses TLS */
static bool negotiateTls(int fd)
{
    uint8_t request[X224_REQUEST_MAX];
    if (!readFully(fd, request, TPKT_HEADER_LENGTH) || request[0] != 0x03)
        return false;

    const size_t length = ((size_t)request[2] << 8) | request[3];
    if (length < TPKT_HEADER_LENGTH || length > sizeof(request) ||
        !readFully(fd, request + TPKT_HEADER_LENGTH, length - TPKT_HEADER_LENGTH))
        return false;
    return send(fd, connectionConfirmTls, sizeof(connectionConfirmTls), 0) == (ssize_t)sizeof(connectionConfirmTls);
}

static void serveClient(TlsServer* server, int fd)
{
    const struct timeval timeout = { .tv_sec = IO_TIMEOUT_S };
    /* A client that walks away mid-handshake must not kill the test process with SIGPIPE on the next write */
    const int noSigPipe = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    (void)setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    (void)setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
    if (!negotiateTls(fd))
        return;

    SSL* ssl = SSL_new(server->tls);
    if (!ssl)
        fail("SSL_new");
    /*
     * The client checks the certificate once the handshake is over, so a finished handshake proves nothing
     * A client that accepted it goes on and sends its first RDP bytes; one that rejected it closes
     */
    uint8_t first = 0;
    if (SSL_set_fd(ssl, fd) == 1 && SSL_accept(ssl) == 1 && SSL_read(ssl, &first, 1) == 1)
        atomic_fetch_add(&server->continued, 1);
    ERR_clear_error();
    SSL_free(ssl);
}

static void* serveLoop(void* arg)
{
    TlsServer* server = arg;
    struct pollfd listener = { .fd = server->listener, .events = POLLIN };

    while (!atomic_load(&server->stopping))
    {
        if (poll(&listener, 1, ACCEPT_POLL_MS) <= 0)
            continue;
        const int client = accept(server->listener, NULL, NULL);
        if (client < 0)
            continue;
        serveClient(server, client);
        close(client);
    }
    return NULL;
}

static int listenLoopback(uint16_t* port)
{
    const int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in address = { .sin_family = AF_INET, .sin_port = 0 };
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    socklen_t length = sizeof(address);
    if (fd < 0 || bind(fd, (struct sockaddr*)&address, sizeof(address)) != 0 ||
        getsockname(fd, (struct sockaddr*)&address, &length) != 0 || listen(fd, 4) != 0)
    {
        fprintf(stderr, "tls server: listen failed: %s\n", strerror(errno));
        abort();
    }
    *port = ntohs(address.sin_port);
    return fd;
}

TlsServer* tlsServerStart(void)
{
    TlsServer* server = calloc(1, sizeof(TlsServer));
    if (!server)
        abort();

    EVP_PKEY* key = EVP_RSA_gen(RSA_BITS);
    if (!key)
        fail("EVP_RSA_gen");
    X509* certificate = selfSignedCertificate(key);
    server->certificatePem = toPem(certificate);

    server->tls = SSL_CTX_new(TLS_server_method());
    if (!server->tls || SSL_CTX_use_certificate(server->tls, certificate) != 1 ||
        SSL_CTX_use_PrivateKey(server->tls, key) != 1)
        fail("setting up the TLS context");
    X509_free(certificate);
    EVP_PKEY_free(key);

    server->listener = listenLoopback(&server->port);
    if (pthread_create(&server->thread, NULL, serveLoop, server) != 0)
        fail("pthread_create");
    return server;
}

uint16_t tlsServerPort(const TlsServer* server)
{
    return server->port;
}

const char* tlsServerCertificatePem(const TlsServer* server)
{
    return server->certificatePem;
}

int tlsServerContinuedCount(TlsServer* server)
{
    return atomic_load(&server->continued);
}

void tlsServerStop(TlsServer* server)
{
    atomic_store(&server->stopping, true);
    pthread_join(server->thread, NULL);
    close(server->listener);
    SSL_CTX_free(server->tls);
    free(server->certificatePem);
    free(server);
}
