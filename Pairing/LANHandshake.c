#include "ODPairing.h"

#include <openssl/mem.h>
#include <openssl/rand.h>
#include <stdio.h>
#include <string.h>

static int valid_id(const char *id) {
    if (strlen(id) != 36) return 0;
    for (size_t i = 0; i < 36; i++) {
        unsigned char c = id[i];
        if (i == 8 || i == 13 || i == 18 || i == 23) {
            if (c != '-') return 0;
        } else if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) {
            return 0;
        }
    }
    return 1;
}

// Both sides write one small introduction before reading the peer's.
// No OpenDisplay media or control messages are accepted during this phase.
static int introduce(const od_lan_io *io, void *ctx, int sender, int request,
                     const char *id, const char *name, od_lan_result *result) {
    if (!valid_id(id) || request < 0 || request > 2) return 0;
    size_t name_size = strlen(name);
    if (name_size > OD_LAN_NAME_MAX) return 0;
    uint8_t hello[41] = {'O', 'D', 1, (uint8_t)sender, (uint8_t)request};
    memcpy(hello + 5, id, 36);
    uint8_t length = (uint8_t)name_size;
    if (!io->write(ctx, hello, sizeof(hello)) || !io->write(ctx, &length, 1) ||
        (length && !io->write(ctx, (const uint8_t *)name, length))) return 0;
    if (!io->read(ctx, hello, sizeof(hello)) ||
        hello[0] != 'O' || hello[1] != 'D' || hello[2] != 1 ||
        hello[3] != 1 - sender || hello[4] > 2 ||
        (request == 0) == (hello[4] == 0) ||
        !io->read(ctx, &length, 1) || length > OD_LAN_NAME_MAX) return 0;
    memcpy(result->peer_id, hello + 5, 36);
    if (!valid_id(result->peer_id) || strcmp(result->peer_id, id) == 0 ||
        (length && !io->read(ctx, (uint8_t *)result->peer_name, length)) ||
        strlen(result->peer_name) != length) return 0;
    result->request = request ? request : hello[4];
    return 1;
}

static int verify_proof(const od_lan_io *io, void *ctx, const uint8_t *key,
                        int sender, const uint8_t *exporter, const uint8_t *binding,
                        size_t binding_size) {
    uint8_t sent[32], received[32], expected[32];
    if (!od_pair_proof(key, sender, exporter, binding, binding_size, sent) ||
        !od_pair_proof(key, !sender, exporter, binding, binding_size, expected)) return 0;
    if (sender && !io->write(ctx, sent, sizeof(sent))) return 0;
    if (!io->read(ctx, received, sizeof(received)) || !od_pair_equal(received, expected)) return 0;
    return sender || io->write(ctx, sent, sizeof(sent));
}

static int new_pair(const od_lan_io *io, void *ctx, int sender, const uint8_t *exporter,
                    const uint8_t *binding, size_t binding_size, od_lan_result *result) {
    char code[7] = {0};
    if (!sender) {
        // Uniform across all one million values, including leading zeroes.
        uint32_t number;
        do {
            if (!RAND_bytes((uint8_t *)&number, sizeof(number))) return 0;
        } while (number >= 4294000000u);
        snprintf(code, sizeof(code), "%06u", number % 1000000u);
        if (!io->code(ctx, result->peer_name, code, 1)) return -1;
    }
    int outcome = 0;
    for (int attempt = 0; attempt < 5; attempt++) {
        uint8_t mine[32], theirs[32], proof[32], expected[32], accepted;
        if (sender && (!io->read(ctx, theirs, sizeof(theirs)) ||
                       !io->code(ctx, result->peer_name, code, 0))) break;
        od_pair *pair = od_pair_new(sender, binding, binding_size,
                                    (const uint8_t *)code, exporter, mine);
        if (!pair) break;
        int exchanged = io->write(ctx, mine, sizeof(mine)) &&
                        (sender || io->read(ctx, theirs, sizeof(theirs)));
        int derived = exchanged && od_pair_finish(pair, theirs, result->secret);
        od_pair_free(pair);
        if (!derived) break;
        if (!od_pair_proof(result->secret, !sender, exporter, binding, binding_size, expected) ||
            !od_pair_proof(result->secret, sender, exporter, binding, binding_size, proof)) break;
        if (sender) {
            if (!io->write(ctx, proof, sizeof(proof)) || !io->read(ctx, &accepted, 1)) break;
            if (accepted == 1 && io->read(ctx, proof, sizeof(proof)) &&
                od_pair_equal(proof, expected)) {
                outcome = 1;
                break;
            }
            if (accepted != 0) {
                outcome = -3;
                break;
            }
        } else {
            uint8_t received[32];
            if (!io->read(ctx, received, sizeof(received))) break;
            accepted = od_pair_equal(received, expected);
            if (!io->write(ctx, &accepted, 1)) break;
            if (accepted) {
                outcome = io->write(ctx, proof, sizeof(proof)) ? 1 : 0;
                break;
            }
        }
        outcome = -3;
    }
    OPENSSL_cleanse(code, sizeof(code));
    return outcome;
}

int od_lan_handshake(const od_lan_io *io, void *ctx, int sender, int request,
                     const char *id, const char *name, const uint8_t exporter[32],
                     od_lan_result *result) {
    memset(result, 0, sizeof(*result));
    if (!introduce(io, ctx, sender, request, id, name, result)) return 0;
    if (!io->inspect(ctx, result->peer_id, result->peer_name, result->request)) return -1;
    uint8_t known = io->load(ctx, result->peer_id, result->secret) == 1;
    uint8_t peer_known;
    if (!io->write(ctx, &known, 1) || !io->read(ctx, &peer_known, 1) || peer_known > 1) return 0;
    uint8_t binding[76];
    memcpy(binding, sender ? id : result->peer_id, 36);
    memcpy(binding + 36, sender ? result->peer_id : id, 36);
    binding[72] = 1; // protocol version
    binding[73] = (uint8_t)result->request;
    binding[74] = (uint8_t)(sender ? request != 0 : request == 0);
    binding[75] = (uint8_t)(known && peer_known);
    int outcome;
    if (known && peer_known) {
        outcome = verify_proof(io, ctx, result->secret, sender, exporter,
                               binding, sizeof(binding)) ? 1 : -3;
    } else if (result->request == 2) {
        outcome = -2;
    } else {
        result->fresh = 1;
        outcome = new_pair(io, ctx, sender, exporter, binding, sizeof(binding), result);
    }
    if (outcome != 1) OPENSSL_cleanse(result->secret, sizeof(result->secret));
    return outcome;
}
