#include "ODPairing.h"

#include <openssl/bytestring.h>
#include <openssl/curve25519.h>
#include <openssl/ec.h>
#include <openssl/evp.h>
#include <openssl/hkdf.h>
#include <openssl/hmac.h>
#include <openssl/mem.h>
#include <openssl/nid.h>
#include <openssl/rand.h>
#include <openssl/x509.h>
#include <string.h>

struct od_pair {
    SPAKE2_CTX *spake;
    uint8_t exporter[32];
};

od_pair *od_pair_new(int sender, const uint8_t *context, size_t context_size,
                     const uint8_t code[6], const uint8_t exporter[32],
                     uint8_t share[32]) {
    static const uint8_t sender_name[] = "OpenDisplay LAN sender 1";
    static const uint8_t receiver_name[] = "OpenDisplay LAN receiver 1";
    const uint8_t *my_name = sender ? sender_name : receiver_name;
    const uint8_t *their_name = sender ? receiver_name : sender_name;
    size_t my_size = sender ? sizeof(sender_name) : sizeof(receiver_name);
    size_t their_size = sender ? sizeof(receiver_name) : sizeof(sender_name);
    uint8_t password[38];
    uint8_t bound_password[32];
    unsigned bound_size = 0;
    size_t share_size = 0;
    for (size_t i = 0; i < 6; i++) {
        if (code[i] < '0' || code[i] > '9') return NULL;
    }
    memcpy(password, code, 6);
    memcpy(password + 6, exporter, 32);
    int bound = HMAC(EVP_sha256(), password, sizeof(password), context, context_size,
                     bound_password, &bound_size) != NULL && bound_size == 32;
    OPENSSL_cleanse(password, sizeof(password));
    od_pair *pair = bound ? OPENSSL_zalloc(sizeof(*pair)) : NULL;
    if (pair) {
        pair->spake = SPAKE2_CTX_new(sender ? spake2_role_alice : spake2_role_bob,
                                    my_name, my_size, their_name, their_size);
        memcpy(pair->exporter, exporter, 32);
        if (!pair->spake || !SPAKE2_generate_msg(pair->spake, share, &share_size, 32,
                                                bound_password, sizeof(bound_password)) ||
            share_size != 32) {
            od_pair_free(pair);
            pair = NULL;
        }
    }
    OPENSSL_cleanse(bound_password, sizeof(bound_password));
    return pair;
}

int od_pair_finish(od_pair *pair, const uint8_t share[32], uint8_t secret[32]) {
    static const uint8_t info[] = "OpenDisplay LAN pairing key 1";
    uint8_t key[SPAKE2_MAX_KEY_SIZE];
    size_t key_size = 0;
    int ok = SPAKE2_process_msg(pair->spake, key, &key_size, sizeof(key), share, 32) &&
             HKDF(secret, 32, EVP_sha256(), key, key_size, pair->exporter, 32,
                  info, sizeof(info) - 1);
    OPENSSL_cleanse(key, sizeof(key));
    return ok;
}

void od_pair_free(od_pair *pair) {
    if (!pair) return;
    SPAKE2_CTX_free(pair->spake);
    OPENSSL_cleanse(pair, sizeof(*pair));
    OPENSSL_free(pair);
}

int od_pair_proof(const uint8_t secret[32], int sender, const uint8_t exporter[32],
                  const uint8_t *context, size_t context_size, uint8_t proof[32]) {
    static const uint8_t sender_info[] = "OpenDisplay LAN sender proof 1";
    static const uint8_t receiver_info[] = "OpenDisplay LAN receiver proof 1";
    const uint8_t *info = sender ? sender_info : receiver_info;
    size_t info_size = sender ? sizeof(sender_info) : sizeof(receiver_info);
    uint8_t proof_key[32];
    unsigned proof_size = 0;
    int ok = HKDF(proof_key, sizeof(proof_key), EVP_sha256(), secret, 32,
                  exporter, 32, info, info_size - 1) &&
             HMAC(EVP_sha256(), proof_key, sizeof(proof_key), context, context_size,
                  proof, &proof_size) != NULL && proof_size == 32;
    OPENSSL_cleanse(proof_key, sizeof(proof_key));
    return ok;
}

int od_pair_equal(const uint8_t lhs[32], const uint8_t rhs[32]) {
    return CRYPTO_memcmp(lhs, rhs, 32) == 0;
}

int od_pair_identity(uint8_t *certificate, size_t *certificate_size,
                     uint8_t *pkcs8, size_t *pkcs8_size, uint8_t x963[97]) {
    int ok = 0;
    uint8_t serial[16];
    CBB builder;
    CBB_zero(&builder);
    X509 *cert = X509_new();
    EVP_PKEY *key = EVP_PKEY_new();
    EC_KEY *ec = EC_KEY_new_by_curve_name(NID_X9_62_prime256v1);
    BIGNUM *serial_bn = NULL;
    if (!cert || !key || !ec || !EC_KEY_generate_key(ec) ||
        !EVP_PKEY_set1_EC_KEY(key, ec) || !RAND_bytes(serial, sizeof(serial))) goto done;
    serial[0] |= 1;
    serial_bn = BN_bin2bn(serial, sizeof(serial), NULL);
    X509_NAME *name = X509_get_subject_name(cert);
    if (!serial_bn || !X509_set_version(cert, 2) ||
        !BN_to_ASN1_INTEGER(serial_bn, X509_get_serialNumber(cert)) ||
        !X509_gmtime_adj(X509_getm_notBefore(cert), -3600) ||
        !X509_gmtime_adj(X509_getm_notAfter(cert), 86400) ||
        !X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC,
                                    (const unsigned char *)"OpenDisplay", -1, -1, 0) ||
        !X509_set_issuer_name(cert, name) || !X509_set_pubkey(cert, key) ||
        !X509_sign(cert, key, EVP_sha256())) goto done;
    int length = i2d_X509(cert, NULL);
    if (length <= 0 || (size_t)length > *certificate_size) goto done;
    unsigned char *output = certificate;
    if (i2d_X509(cert, &output) != length ||
        !CBB_init_fixed(&builder, pkcs8, *pkcs8_size) ||
        !EVP_marshal_private_key(&builder, key) ||
        !CBB_finish(&builder, NULL, pkcs8_size)) goto done;
    if (EC_POINT_point2oct(EC_KEY_get0_group(ec), EC_KEY_get0_public_key(ec),
                           POINT_CONVERSION_UNCOMPRESSED, x963, 65, NULL) != 65 ||
        !BN_bn2bin_padded(x963 + 65, 32, EC_KEY_get0_private_key(ec))) goto done;
    *certificate_size = (size_t)length;
    ok = 1;
done:
    CBB_cleanup(&builder);
    BN_free(serial_bn);
    EC_KEY_free(ec);
    EVP_PKEY_free(key);
    X509_free(cert);
    return ok;
}
