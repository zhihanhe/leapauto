#include "leap_native_crypto.h"
#include <assert.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned checks = 0;
#define CHECK(condition) do { checks++; if (!(condition)) { \
    fprintf(stderr, "Native crypto check failed at line %d\n", __LINE__); exit(1); } } while (0)

static void hex(const char *text, uint8_t *output, size_t length) {
    CHECK(strlen(text) == length * 2);
    for (size_t i = 0; i < length; i++) {
        unsigned byte;
        CHECK(sscanf(text + i * 2, "%2x", &byte) == 1);
        output[i] = (uint8_t)byte;
    }
}
static int zero(const uint8_t *p, size_t n) {
    uint8_t aggregate = 0;
    for (size_t i = 0; i < n; i++) aggregate |= p[i];
    return aggregate == 0;
}
static void expect_hex(const uint8_t *actual, size_t n, const char *expected) {
    uint8_t buffer[512];
    CHECK(n <= sizeof(buffer)); hex(expected, buffer, n); CHECK(memcmp(actual, buffer, n) == 0);
}

static const char *generator_hex = "0432c4ae2c1f1981195f9904466a39c9948fe30bbff2660be1715a4589334c74c7bc3736a2f4f6779c59bdcee36b692153d0a9877cc62a474002df32e52139f0a0";
static const char *peer_hex = "0456cefd60d7c87c000d58ef57fa73ba4d9c0dfa08c08a7331495c2e1da3f2bd5231b7e7e6cc8189f668535ce0f8eaf1bd6de84c182f6c8e716f780d3a970a23c3";

static void test_points(void) {
    uint8_t one[32] = {0}, two[32] = {0}, n[32], high[32], output[65], g[65], peer[65], compressed[33];
    one[31] = 1; two[31] = 2;
    CHECK(leap_sm2_public_key(one, g)); expect_hex(g, 65, generator_hex);
    CHECK(leap_sm2_public_key(two, peer)); expect_hex(peer, 65, peer_hex);
    CHECK(leap_sm2_multiply_point(two, g, 65, output)); CHECK(memcmp(output, peer, 65) == 0);
    compressed[0] = (uint8_t)(2 | (g[64] & 1)); memcpy(compressed + 1, g + 1, 32);
    CHECK(leap_sm2_multiply_point(one, compressed, 33, output)); CHECK(memcmp(output, g, 65) == 0);
    compressed[0] ^= 1;
    CHECK(leap_sm2_multiply_point(one, compressed, 33, output)); CHECK(memcmp(output + 1, g + 1, 32) == 0); CHECK(memcmp(output, g, 65) != 0);
    hex("fffffffeffffffffffffffffffffffff7203df6b21c6052b53bbf40939d54123", n, 32);
    memset(output, 0xa5, sizeof(output)); CHECK(!leap_sm2_public_key(n, output)); CHECK(zero(output, 65));
    memcpy(high, n, 32); high[31]--; CHECK(leap_sm2_public_key(high, output));
    uint8_t product[32]; CHECK(leap_sm2_multiply_scalars(high, high, product)); CHECK(memcmp(product, one, 32) == 0);
    CHECK(leap_sm2_multiply_scalars(one, two, product)); CHECK(memcmp(product, two, 32) == 0);
    memset(high, 0xff, 32); CHECK(!leap_sm2_public_key(high, output)); CHECK(zero(output, 65));
    memset(high, 0, 32); CHECK(!leap_sm2_public_key(high, output)); CHECK(zero(output, 65));
    memset(product, 0xa5, 32); CHECK(!leap_sm2_multiply_scalars(high, one, product)); CHECK(zero(product, 32));
    CHECK(!leap_sm2_multiply_scalars(one, n, product)); CHECK(zero(product, 32));
    CHECK(!leap_sm2_public_key(NULL, output)); CHECK(zero(output, 65));
    CHECK(!leap_sm2_public_key(one, NULL));
    CHECK(!leap_sm2_multiply_point(one, NULL, 65, output)); CHECK(zero(output, 65));
    uint8_t bad[65] = {0}; CHECK(!leap_sm2_multiply_point(one, bad, 1, output)); CHECK(zero(output, 65));
    bad[0] = 4; CHECK(!leap_sm2_multiply_point(one, bad, 65, output)); CHECK(zero(output, 65));
    memcpy(bad, g, 65); bad[0] = 6; CHECK(!leap_sm2_multiply_point(one, bad, 65, output));
    memcpy(bad, g, 65); bad[64] ^= 1; CHECK(!leap_sm2_multiply_point(one, bad, 65, output));
    memset(bad + 1, 0xff, 32); bad[0] = 2; CHECK(!leap_sm2_multiply_point(one, bad, 33, output));
    CHECK(!leap_sm2_multiply_point(one, g, 64, output)); CHECK(zero(output, 65));
}

/* All certificates below are synthetic structures with placeholder signatures.
 * They are neither account credentials nor trusted/signed server certificates. */
typedef struct { uint8_t bytes[4096]; size_t length; } Buffer;
static Buffer empty(void) { Buffer b = {{0}, 0}; return b; }
static void append(Buffer *b, const void *p, size_t n) {
    CHECK(n <= sizeof(b->bytes) - b->length);
    if (n) memcpy(b->bytes + b->length, p, n);
    b->length += n;
}
static Buffer wrap(uint8_t tag, const void *p, size_t n) {
    Buffer b = empty(); append(&b, &tag, 1);
    if (n < 128) { uint8_t length = (uint8_t)n; append(&b, &length, 1); }
    else if (n < 256) { uint8_t length[] = {0x81, (uint8_t)n}; append(&b, length, 2); }
    else { CHECK(n <= 65535); uint8_t length[] = {0x82, (uint8_t)(n >> 8), (uint8_t)n}; append(&b, length, 3); }
    append(&b, p, n); return b;
}
static Buffer boxed(uint8_t tag, Buffer b) { return wrap(tag, b.bytes, b.length); }
static void add(Buffer *b, Buffer part) { append(b, part.bytes, part.length); }

enum Mode {
    VALID, NONMINIMAL_INTEGER, NONMINIMAL_LENGTH, EXPLICIT_V1, WRONG_ALGORITHM,
    WRONG_CURVE, NULL_CURVE, PADDED_KEY, BAD_POINT, UNSORTED_SET, BAD_BOOLEAN,
    FALSE_CRITICAL, FALSE_BASIC_CA, INVALID_TIME, CONSTRUCTED_STRING, INVALID_UTF8,
    NONMINIMAL_OID, BAD_SIGNATURE_PADDING, EXTRA_SPKI, VALID_BASIC_CA, VALID_V1,
    VALID_SORTED_SET, VALID_KEY_USAGE, NONMINIMAL_KEY_USAGE, DEEP_NESTING,
    UNKNOWN_EXTENSION, DUPLICATE_EXTENSION, VALID_SKI, WRONG_SKI_TYPE,
    EXCESS_KEY_USAGE, VALID_NINTH_USAGE, PATH_WITHOUT_CA, NEGATIVE_PATH_LENGTH,
    VALID_PATH_LENGTH, BAD_NAME_VALUE, SIGNATURE_PARAMETERS, VALID_NULL_PARAMETERS,
    INVALID_VERSION, ZERO_SERIAL, EXPLICIT_PSS_DEFAULT
};
static Buffer name(enum Mode mode) {
    static const uint8_t cn_oid[] = {0x55, 0x04, 0x03};
    Buffer attribute = empty(); add(&attribute, wrap(6, cn_oid, sizeof(cn_oid)));
    uint8_t text[] = {'S', 'y', 'n', 't', 'h', 'e', 't', 'i', 'c'};
    if (mode == INVALID_UTF8) { text[0] = 0xc0; text[1] = 0x80; }
    if (mode == BAD_NAME_VALUE) add(&attribute, wrap(4, text, sizeof(text)));
    else add(&attribute, wrap(mode == CONSTRUCTED_STRING ? 0x2c : 0x0c, text, sizeof(text)));
    attribute = boxed(0x30, attribute);
    Buffer set = empty();
    if (mode == UNSORTED_SET || mode == VALID_SORTED_SET) {
        Buffer second = empty(); add(&second, wrap(6, cn_oid, sizeof(cn_oid))); add(&second, wrap(0x0c, "A", 1)); second = boxed(0x30, second);
        if (mode == UNSORTED_SET) { add(&set, attribute); add(&set, second); }
        else { add(&set, second); add(&set, attribute); }
    } else add(&set, attribute);
    return boxed(0x30, boxed(0x31, set));
}
static Buffer certificate(const uint8_t *point, size_t point_length, enum Mode mode, Buffer *spki_out) {
    static const uint8_t signature_oid[] = {0x2a,0x86,0x48,0xce,0x3d,0x04,0x03,0x02};
    static const uint8_t ec_oid[] = {0x2a,0x86,0x48,0xce,0x3d,0x02,0x01};
    uint8_t curve_oid[] = {0x2a,0x81,0x1c,0xcf,0x55,0x01,0x82,0x2d};
    Buffer signature_algorithm = empty();
    if (mode == EXPLICIT_PSS_DEFAULT) {
        static const uint8_t pss_oid[] = {0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x0a};
        static const uint8_t explicit_default[] = {0x30,0x05,0xa3,0x03,0x02,0x01,0x01};
        add(&signature_algorithm, wrap(6, pss_oid, sizeof(pss_oid))); append(&signature_algorithm, explicit_default, sizeof(explicit_default));
    } else add(&signature_algorithm, wrap(6, signature_oid, sizeof(signature_oid)));
    if (mode == DEEP_NESTING) {
        Buffer nested = wrap(5, NULL, 0);
        for (unsigned i = 0; i < 40; i++) nested = boxed(0x30, nested);
        add(&signature_algorithm, nested);
    }
    if (mode == SIGNATURE_PARAMETERS) add(&signature_algorithm, wrap(0x30, NULL, 0));
    if (mode == VALID_NULL_PARAMETERS) add(&signature_algorithm, wrap(5, NULL, 0));
    signature_algorithm = boxed(0x30, signature_algorithm);
    Buffer key_algorithm = empty();
    add(&key_algorithm, wrap(6, mode == WRONG_ALGORITHM ? signature_oid : ec_oid,
                            mode == WRONG_ALGORITHM ? sizeof(signature_oid) : sizeof(ec_oid)));
    if (mode == WRONG_CURVE) curve_oid[7] ^= 1;
    if (mode == NULL_CURVE) add(&key_algorithm, wrap(5, NULL, 0));
    else if (mode == NONMINIMAL_OID) {
        uint8_t overlong[9] = {0x80}; memcpy(overlong + 1, curve_oid, 8); add(&key_algorithm, wrap(6, overlong, 9));
    } else add(&key_algorithm, wrap(6, curve_oid, sizeof(curve_oid)));
    key_algorithm = boxed(0x30, key_algorithm);
    Buffer key = empty(); uint8_t padding = mode == PADDED_KEY ? 1 : 0; append(&key, &padding, 1); append(&key, point, point_length);
    if (mode == BAD_POINT) memset(key.bytes + 2, 0, key.length - 2);
    if (mode == PADDED_KEY) key.bytes[key.length - 1] &= 0xfe;
    Buffer spki = empty(); add(&spki, key_algorithm); add(&spki, boxed(3, key));
    if (mode == EXTRA_SPKI) add(&spki, wrap(5, NULL, 0));
    spki = boxed(0x30, spki); if (spki_out) *spki_out = spki;
    Buffer tbs = empty(); uint8_t version = mode == EXPLICIT_V1 ? 0 : (mode == INVALID_VERSION ? 3 : 2);
    if (mode != VALID_V1) add(&tbs, boxed(0xa0, wrap(2, &version, 1)));
    uint8_t serial[] = {0, mode == ZERO_SERIAL ? 0 : 1};
    if (mode == NONMINIMAL_LENGTH) { uint8_t invalid[] = {2, 0x81, 1, 1}; append(&tbs, invalid, sizeof(invalid)); }
    else add(&tbs, wrap(2, mode == NONMINIMAL_INTEGER ? serial : serial + 1, mode == NONMINIMAL_INTEGER ? 2 : 1));
    add(&tbs, signature_algorithm); add(&tbs, name(mode));
    Buffer validity = empty(); add(&validity, wrap(0x17, mode == INVALID_TIME ? "261301000000Z" : "260101000000Z", 13));
    add(&validity, wrap(0x17, "360101000000Z", 13)); add(&tbs, boxed(0x30, validity));
    add(&tbs, name(mode)); add(&tbs, spki);
    if (mode == BAD_BOOLEAN || mode == FALSE_CRITICAL || mode == FALSE_BASIC_CA || mode == VALID_BASIC_CA ||
        mode == VALID_KEY_USAGE || mode == NONMINIMAL_KEY_USAGE || mode == UNKNOWN_EXTENSION ||
        mode == DUPLICATE_EXTENSION || mode == VALID_SKI || mode == WRONG_SKI_TYPE ||
        mode == EXCESS_KEY_USAGE || mode == VALID_NINTH_USAGE || mode == PATH_WITHOUT_CA ||
        mode == NEGATIVE_PATH_LENGTH || mode == VALID_PATH_LENGTH) {
        uint8_t extension_oid[] = {0x55,0x1d,0x13};
        int is_usage = mode == VALID_KEY_USAGE || mode == NONMINIMAL_KEY_USAGE || mode == EXCESS_KEY_USAGE || mode == VALID_NINTH_USAGE;
        if (is_usage) extension_oid[2] = 0x0f;
        if (mode == UNKNOWN_EXTENSION) extension_oid[2] = 0x23;
        if (mode == VALID_SKI || mode == WRONG_SKI_TYPE) extension_oid[2] = 0x0e;
        Buffer ext = empty(); add(&ext, wrap(6, extension_oid, sizeof(extension_oid)));
        if (mode == BAD_BOOLEAN || mode == FALSE_CRITICAL) {
            uint8_t boolean = mode == BAD_BOOLEAN ? 1 : 0; add(&ext, wrap(1, &boolean, 1));
        }
        Buffer content = empty();
        if (mode == FALSE_BASIC_CA || mode == VALID_BASIC_CA || mode == NEGATIVE_PATH_LENGTH || mode == VALID_PATH_LENGTH) {
            uint8_t boolean = mode == FALSE_BASIC_CA ? 0 : 0xff; add(&content, wrap(1, &boolean, 1));
        }
        if (mode == PATH_WITHOUT_CA || mode == NEGATIVE_PATH_LENGTH || mode == VALID_PATH_LENGTH) {
            uint8_t value = mode == NEGATIVE_PATH_LENGTH ? 0xff : 0; add(&content, wrap(2, &value, 1));
        }
        if (is_usage) {
            uint8_t usage[] = {mode == VALID_KEY_USAGE ? 7 : 0, 0x80, 0};
            size_t count = 2;
            if (mode == EXCESS_KEY_USAGE || mode == VALID_NINTH_USAGE) {
                count = 3; usage[0] = mode == EXCESS_KEY_USAGE ? 6 : 7; usage[1] = 0;
                usage[2] = mode == EXCESS_KEY_USAGE ? 0xc0 : 0x80;
            }
            content = wrap(3, usage, count);
        } else if (mode == VALID_SKI || mode == WRONG_SKI_TYPE) {
            const uint8_t identifier[] = {1, 2, 3, 4}; content = wrap(mode == VALID_SKI ? 4 : 2, identifier, sizeof(identifier));
        } else content = boxed(0x30, content);
        add(&ext, boxed(4, content));
        Buffer ext_sequence = empty(); add(&ext_sequence, boxed(0x30, ext));
        if (mode == DUPLICATE_EXTENSION) add(&ext_sequence, boxed(0x30, ext));
        add(&tbs, boxed(0xa3, boxed(0x30, ext_sequence)));
    }
    Buffer cert = empty(); add(&cert, boxed(0x30, tbs)); add(&cert, signature_algorithm);
    uint8_t fake_signature[] = {0, 0x30, 6, 2, 1, 1, 2, 1, 1};
    if (mode == BAD_SIGNATURE_PADDING) { fake_signature[0] = 1; fake_signature[8] = 0; }
    add(&cert, wrap(3, fake_signature, sizeof(fake_signature)));
    return boxed(0x30, cert);
}
static void expect_bad_certificate(Buffer b) {
    uint8_t output[65]; memset(output, 0xa5, sizeof(output));
    CHECK(!leap_sm2_certificate_public_key(b.bytes, b.length, output)); CHECK(zero(output, 65));
}
static void test_certificates(void) {
    uint8_t point[65], output[65], compressed[33]; hex(generator_hex, point, 65);
    Buffer spki, valid = certificate(point, 65, VALID, &spki);
    CHECK(leap_sm2_certificate_public_key(valid.bytes, valid.length, output)); CHECK(memcmp(output, point, 65) == 0);
    compressed[0] = (uint8_t)(2 | (point[64] & 1)); memcpy(compressed + 1, point + 1, 32);
    Buffer compressed_cert = certificate(compressed, 33, VALID, NULL);
    CHECK(leap_sm2_certificate_public_key(compressed_cert.bytes, compressed_cert.length, output)); CHECK(memcmp(output, point, 65) == 0);
    enum Mode good_modes[] = {VALID_BASIC_CA, VALID_V1, VALID_SORTED_SET, VALID_KEY_USAGE,
        VALID_SKI, VALID_NINTH_USAGE, VALID_PATH_LENGTH, VALID_NULL_PARAMETERS};
    for (size_t i = 0; i < sizeof(good_modes) / sizeof(good_modes[0]); i++) {
        Buffer b = certificate(point, 65, good_modes[i], NULL); CHECK(leap_sm2_certificate_public_key(b.bytes, b.length, output));
    }
    enum Mode bad_modes[] = {NONMINIMAL_INTEGER, NONMINIMAL_LENGTH, EXPLICIT_V1, WRONG_ALGORITHM,
        WRONG_CURVE, NULL_CURVE, PADDED_KEY, BAD_POINT, UNSORTED_SET, BAD_BOOLEAN, FALSE_CRITICAL,
        FALSE_BASIC_CA, INVALID_TIME, CONSTRUCTED_STRING, INVALID_UTF8, NONMINIMAL_OID,
        BAD_SIGNATURE_PADDING, EXTRA_SPKI, NONMINIMAL_KEY_USAGE, DEEP_NESTING,
        UNKNOWN_EXTENSION, DUPLICATE_EXTENSION, WRONG_SKI_TYPE, EXCESS_KEY_USAGE,
        PATH_WITHOUT_CA, NEGATIVE_PATH_LENGTH, BAD_NAME_VALUE, SIGNATURE_PARAMETERS,
        INVALID_VERSION, ZERO_SERIAL, EXPLICIT_PSS_DEFAULT};
    for (size_t i = 0; i < sizeof(bad_modes) / sizeof(bad_modes[0]); i++) expect_bad_certificate(certificate(point, 65, bad_modes[i], NULL));
    expect_bad_certificate(spki);
    Buffer raw = empty(); append(&raw, point, 65); expect_bad_certificate(raw);
    Buffer trailing = valid; const uint8_t one = 1; append(&trailing, &one, 1); expect_bad_certificate(trailing);
    const size_t header = valid.bytes[1] < 128 ? 2 : 2 + (valid.bytes[1] & 0x7f);
    Buffer indefinite = empty(); const uint8_t prefix[] = {0x30, 0x80}, ending[] = {0, 0};
    append(&indefinite, prefix, 2); append(&indefinite, valid.bytes + header, valid.length - header); append(&indefinite, ending, 2); expect_bad_certificate(indefinite);
    Buffer nonminimal = empty(); uint8_t long_header[] = {0x30, (uint8_t)(0x80 | (header - 1)), 0};
    append(&nonminimal, long_header, 3); append(&nonminimal, valid.bytes + 2, valid.length - 2); expect_bad_certificate(nonminimal);
    for (size_t n = 0; n < valid.length; n++) {
        CHECK(!leap_sm2_certificate_public_key(valid.bytes, n, output)); CHECK(zero(output, 65));
    }
    /* Deterministic malformed input smoke coverage under ASan/UBSan. Valid
     * mutations may be accepted, but every rejected result must be zeroed. */
    uint32_t state = 0x12345678;
    for (unsigned i = 0; i < 2000; i++) {
        Buffer mutated = valid; state = state * 1664525u + 1013904223u;
        size_t offset = state % valid.length; state = state * 1664525u + 1013904223u;
        mutated.bytes[offset] ^= (uint8_t)(1u << (state % 8));
        if (!leap_sm2_certificate_public_key(mutated.bytes, mutated.length, output)) CHECK(zero(output, 65));
    }
    CHECK(!leap_sm2_certificate_public_key(NULL, 1, output)); CHECK(zero(output, 65));
    CHECK(!leap_sm2_certificate_public_key(valid.bytes, 131073, output)); CHECK(zero(output, 65));
}

static void test_sm3(void) {
    uint8_t output[32], input[64];
    CHECK(leap_sm3((const uint8_t *)"abc", 3, output));
    expect_hex(output, 32, "66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0");
    for (size_t i = 0; i < sizeof(input); i++) input[i] = (uint8_t)"abcd"[i % 4];
    CHECK(leap_sm3(input, sizeof(input), output));
    expect_hex(output, 32, "debe9ff92275b8a138604889c18e5a4d6fdb70e5387e5765293dcba39c0c5732");
    CHECK(leap_sm3(NULL, 0, output));
    expect_hex(output, 32, "1ab21d8355cfa17f8e61194831e81a8f22bec8c728fefb747ed035eb5082aa2b");
    memset(output, 0xa5, 32); CHECK(!leap_sm3(NULL, 1, output)); CHECK(zero(output, 32));
    CHECK(!leap_sm3(input, sizeof(input), NULL));
}

static void test_sm4(void) {
    uint8_t key[16], iv[16] = {0}, block[16], encrypted[256], decrypted[256];
    size_t written = 99, recovered = 99;
    hex("0123456789abcdeffedcba9876543210", key, 16); memcpy(block, key, 16);
    CHECK(leap_sm4_cbc_encrypt(key, iv, block, 16, encrypted, sizeof(encrypted), &written));
    CHECK(written == 32); expect_hex(encrypted, 16, "681edf34d206965e86b3e94f536e4246");
    CHECK(leap_sm4_cbc_decrypt(key, iv, encrypted, written, decrypted, sizeof(decrypted), &recovered));
    CHECK(recovered == 16 && memcmp(decrypted, block, 16) == 0);
    encrypted[15] ^= 1; memset(decrypted, 0xa5, sizeof(decrypted));
    CHECK(!leap_sm4_cbc_decrypt(key, iv, encrypted, written, decrypted, sizeof(decrypted), &recovered));
    CHECK(recovered == 0 && zero(decrypted, sizeof(decrypted)));
    uint8_t plain[127]; for (size_t i = 0; i < sizeof(plain); i++) plain[i] = (uint8_t)i;
    const size_t lengths[] = {0, 1, 15, 16, 17, 31, 32, 33, 127};
    for (size_t i = 0; i < sizeof(lengths) / sizeof(lengths[0]); i++) {
        const size_t n = lengths[i];
        CHECK(leap_sm4_cbc_encrypt(key, iv, n ? plain : NULL, n, encrypted, sizeof(encrypted), &written));
        CHECK(written == (n / 16 + 1) * 16);
        CHECK(leap_sm4_cbc_decrypt(key, iv, encrypted, written, decrypted, sizeof(decrypted), &recovered));
        CHECK(recovered == n && memcmp(decrypted, plain, n) == 0);
    }
    memset(encrypted, 0xa5, sizeof(encrypted));
    CHECK(!leap_sm4_cbc_encrypt(key, iv, block, 16, encrypted, 31, &written)); CHECK(written == 0 && zero(encrypted, 31)); CHECK(encrypted[31] == 0xa5);
    CHECK(!leap_sm4_cbc_encrypt(NULL, iv, block, 16, encrypted, sizeof(encrypted), &written)); CHECK(zero(encrypted, sizeof(encrypted)));
    CHECK(!leap_sm4_cbc_encrypt(key, NULL, block, 16, encrypted, sizeof(encrypted), &written));
    CHECK(!leap_sm4_cbc_encrypt(key, iv, NULL, 1, encrypted, sizeof(encrypted), &written));
    CHECK(!leap_sm4_cbc_encrypt(key, iv, block, (size_t)INT_MAX, encrypted, sizeof(encrypted), &written));
    CHECK(!leap_sm4_cbc_encrypt(key, iv, block, 16, encrypted, sizeof(encrypted), NULL));
    CHECK(!leap_sm4_cbc_encrypt(key, iv, block, 16, NULL, 0, &written));
    CHECK(!leap_sm4_cbc_decrypt(key, iv, encrypted, 15, decrypted, sizeof(decrypted), &recovered)); CHECK(recovered == 0 && zero(decrypted, sizeof(decrypted)));
    CHECK(!leap_sm4_cbc_decrypt(key, iv, NULL, 0, decrypted, sizeof(decrypted), &recovered));
    CHECK(!leap_sm4_cbc_decrypt(key, iv, encrypted, 16, decrypted, 15, &recovered));
    leap_crypto_cleanse(key, sizeof(key)); CHECK(zero(key, sizeof(key))); leap_crypto_cleanse(NULL, 20);
}

static void xbar_plus_one(const uint8_t point[65], uint8_t scalar[32]) {
    memset(scalar, 0, 32); memcpy(scalar + 16, point + 17, 16); scalar[16] |= 0x80;
    for (size_t i = 32; i > 0; i--) if (++scalar[i - 1]) break;
}
static void identity_digest(const uint8_t point[65], const uint8_t generator[65], uint8_t digest[32]) {
    uint8_t preimage[210]; preimage[0] = 0; preimage[1] = 0x80;
    memcpy(preimage + 2, "1234567812345678", 16);
    hex("fffffffeffffffffffffffffffffffffffffffff00000000fffffffffffffffc", preimage + 18, 32);
    hex("28e9fa9e9d9f5e344d5a9e4bcf6509a7f39789f515ab8f92ddbcbd414d940e93", preimage + 50, 32);
    memcpy(preimage + 82, generator + 1, 64); memcpy(preimage + 146, point + 1, 64);
    CHECK(leap_sm3(preimage, sizeof(preimage), digest)); leap_crypto_cleanse(preimage, sizeof(preimage));
}
static void test_custom_agreement(void) {
    uint8_t one[32] = {0}, two[32] = {0}, local[65], peer[65], a[32], b[32], t[32], intermediate[65], shared[65];
    one[31] = 1; two[31] = 2;
    CHECK(leap_sm2_public_key(one, local)); CHECK(leap_sm2_public_key(two, peer));
    xbar_plus_one(local, a); xbar_plus_one(peer, b);
    CHECK(leap_sm2_multiply_scalars(a, one, t));
    CHECK(leap_sm2_multiply_point(b, peer, 65, intermediate));
    CHECK(leap_sm2_multiply_point(t, intermediate, 65, shared));
    expect_hex(shared, 65, "0484bc6a2aa48bb01a485d83f235d53780e1dff6f8d24cef22601959b93c48555372314b7108a7dc87d3a9cf66f946aa744cab7c3c3928abe9024ce6aa5a27b08b");
    uint8_t za[32], zb[32]; identity_digest(local, local, za); identity_digest(peer, local, zb);
    expect_hex(za, 32, "5b32bfe35482899b195d72c09d33ccdb465b2ded883240ff91f120a68bc91de8");
    expect_hex(zb, 32, "60371fc8ee7c0ce0aa65d8837b874cd744602ad5ac009830fa40ba371984526a");
    uint8_t kdf_input[132] = {0}, material[32]; memcpy(kdf_input, shared + 1, 64); memcpy(kdf_input + 64, za, 32); memcpy(kdf_input + 96, zb, 32); kdf_input[131] = 1;
    CHECK(leap_sm3(kdf_input, sizeof(kdf_input), material)); expect_hex(material, 32, "5f86e6b17708f60dfb5d8e3f3ce2b35d3d29744d51c46fc14cdb7bb95fdaf48b");
    uint8_t selector_input[21] = {0x12,0x34,0x56,0x78}, selector[32], derivation[37], derived[32];
    const char *vin = "TESTVIN0000000001", *card = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    for (size_t i = 0; i < 17; i++) selector_input[i + 4] = (uint8_t)vin[16 - i];
    CHECK(leap_sm3(selector_input, sizeof(selector_input), selector)); CHECK((selector[0] >> 4) * 5 == 15);
    memcpy(derivation, card + 15, 5); memcpy(derivation + 5, material, 32); CHECK(leap_sm3(derivation, sizeof(derivation), derived));
    expect_hex(derived, 32, "6fa340d39f4141fea70453772e7dc265248f0c0a1fe1dc3e437410132db0dd25");
    /* Independent protocol unlock vector, including little-endian timestamp and
     * CRC8, encrypted with the derived lowercase-hex ASCII key/IV. */
    uint8_t command[10] = {0}, encrypted[16]; uint64_t timestamp = 1800000000;
    for (size_t i = 0; i < 8; i++) command[i + 1] = (uint8_t)(timestamp >> (i * 8));
    command[9] = 1;
    uint8_t crc = 0; for (size_t i = 1; i < 10; i++) { crc ^= command[i]; for (unsigned bit = 0; bit < 8; bit++) crc = (uint8_t)((crc << 1) ^ ((crc & 0x80) ? 7 : 0)); } command[0] = crc;
    size_t written = 0;
    CHECK(leap_sm4_cbc_encrypt((const uint8_t *)"6fa340d39f4141fe", (const uint8_t *)"437410132db0dd25", command, 10, encrypted, sizeof(encrypted), &written));
    CHECK(written == 16); expect_hex(encrypted, 16, "783b811463f0ff8c13c5f1c2e7c937eb");
    leap_crypto_cleanse(t, sizeof(t)); leap_crypto_cleanse(shared, sizeof(shared));
    leap_crypto_cleanse(material, sizeof(material)); leap_crypto_cleanse(derived, sizeof(derived));
}

int main(void) {
    test_points(); test_certificates(); test_sm3(); test_sm4(); test_custom_agreement();
    printf("Native offline crypto: %u checks passed; synthetic fixtures only.\n", checks);
    return 0;
}
