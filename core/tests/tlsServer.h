/*
 * A fake RDP server that gets exactly as far as the TLS handshake:
 * it answers the X.224 connection request by choosing TLS, presents a self-signed certificate and hangs up
 * The certificate is generated at start, so no key material lives in the repository
 */

#ifndef VRC_TLS_SERVER_H
#define VRC_TLS_SERVER_H

#include <stdint.h>

typedef struct TlsServer TlsServer;

TlsServer* tlsServerStart(void);
uint16_t tlsServerPort(const TlsServer* server);
/* The server certificate in PEM, NUL-terminated */
const char* tlsServerCertificatePem(const TlsServer* server);
/* Connections where the client sent data after the handshake, that is, accepted the certificate */
int tlsServerContinuedCount(TlsServer* server);
void tlsServerStop(TlsServer* server);

#endif
