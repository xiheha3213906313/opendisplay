#ifndef OD_PAIRING_H
#define OD_PAIRING_H

#include <stddef.h>
#include <stdint.h>

#define OD_PAIR_SIZE 32

typedef struct od_pair od_pair;

// Pairing roles follow the direction of the screen stream, regardless of
// which peer opened TCP. context binds the two installation IDs and intent.
od_pair *od_pair_new(int sender, const uint8_t *context, size_t context_size,
                     const uint8_t code[6], const uint8_t exporter[32],
                     uint8_t share[32]);
int od_pair_finish(od_pair *pair, const uint8_t share[32], uint8_t secret[32]);
void od_pair_free(od_pair *pair);

int od_pair_proof(const uint8_t secret[32], int sender, const uint8_t exporter[32],
                  const uint8_t *context, size_t context_size, uint8_t proof[32]);
int od_pair_equal(const uint8_t lhs[32], const uint8_t rhs[32]);

// Generate a process-local self-signed TLS certificate and its private key.
// Callers authenticate the channel via proof of the pairing key before use.
int od_pair_identity(uint8_t *certificate, size_t *certificate_size,
                     uint8_t *pkcs8, size_t *pkcs8_size, uint8_t x963[97]);

#define OD_LAN_EXPORTER "EXPORTER-OpenDisplay-LAN-v1"
#define OD_LAN_ALPN "opendisplay/1"
#define OD_LAN_NAME_MAX 120

// request: 0 for an accepted TCP connection, 1 for Connect, 2 for Resume.
// inspect receives the actual request in either direction. code receives a
// generated code on the receiver; on the sender it fills six ASCII digits.
typedef struct {
    int (*read)(void *, uint8_t *, size_t);
    int (*write)(void *, const uint8_t *, size_t);
    int (*inspect)(void *, const char *, const char *, int);
    int (*load)(void *, const char *, uint8_t *);
    int (*code)(void *, const char *, char *, int);
} od_lan_io;

typedef struct {
    char peer_id[37];
    char peer_name[OD_LAN_NAME_MAX + 1];
    uint8_t secret[32];
    int fresh;
    int request;
} od_lan_result;

// Returns 1 on success, 0 on EOF or invalid messages, -1 on cancelled or
// refused, -2 on a resume with missing keys, -3 on failed authentication.
int od_lan_handshake(const od_lan_io *io, void *ctx, int sender, int request,
                     const char *id, const char *name, const uint8_t exporter[32],
                     od_lan_result *result);

#if defined(__APPLE__)
#include <Security/SecProtocolOptions.h>
#include <Security/SecProtocolMetadata.h>
int od_pair_export_apple(sec_protocol_metadata_t metadata, uint8_t output[32]);
#endif

#endif
