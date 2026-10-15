#include "leap_native_crypto.h"
#include "strict_der.h"
#include <limits.h>
#include <string.h>
#include <openssl/bn.h>
#include <openssl/crypto.h>
#include <openssl/ec.h>
#include <openssl/evp.h>
#include <openssl/obj_mac.h>
#include <openssl/x509.h>

#if OPENSSL_VERSION_MAJOR != 3
#error "LeapNativeCrypto requires OpenSSL major version 3"
#endif

void leap_crypto_cleanse(void *buffer, size_t length) {
    if (buffer && length) OPENSSL_cleanse(buffer, length);
}

static BIGNUM *scalar_read(const uint8_t input[32], const EC_GROUP *group) {
    BIGNUM *value = NULL;
    if (!input || !group || !(value = BN_secure_new())) return NULL;
    if (!BN_bin2bn(input, 32, value) || BN_is_zero(value) ||
        BN_cmp(value, EC_GROUP_get0_order(group)) >= 0) {
        BN_clear_free(value);
        return NULL;
    }
    BN_set_flags(value, BN_FLG_CONSTTIME);
    return value;
}

static int point_read(const EC_GROUP *group, EC_POINT *output,
                      const uint8_t *input, size_t length, BN_CTX *context) {
    if (!input || !((length == 65 && input[0] == 4) ||
                    (length == 33 && (input[0] == 2 || input[0] == 3)))) return 0;
    return EC_POINT_oct2point(group, output, input, length, context) == 1 &&
           EC_POINT_is_at_infinity(group, output) == 0 &&
           EC_POINT_is_on_curve(group, output, context) == 1;
}

static int point_write(const EC_GROUP *group, const EC_POINT *point,
                       uint8_t output[65], BN_CTX *context) {
    return EC_POINT_is_at_infinity(group, point) == 0 &&
           EC_POINT_is_on_curve(group, point, context) == 1 &&
           EC_POINT_point2oct(group, point, POINT_CONVERSION_UNCOMPRESSED,
                              output, 65, context) == 65;
}

static int multiply(const uint8_t scalar[32], const uint8_t *input,
                     size_t input_length, int generator, uint8_t output[65]) {
    int success = 0;
    EC_GROUP *group = NULL;
    EC_POINT *point = NULL, *result = NULL;
    BIGNUM *value = NULL;
    BN_CTX *context = NULL;
    if (!output) return 0;
    if (!(group = EC_GROUP_new_by_curve_name(NID_sm2)) ||
        !(context = BN_CTX_secure_new()) || !(result = EC_POINT_new(group)) ||
        !(value = scalar_read(scalar, group))) goto cleanup;
    if (generator) {
        if (EC_POINT_mul(group, result, value, NULL, NULL, context) != 1) goto cleanup;
    } else {
        if (!(point = EC_POINT_new(group)) || !point_read(group, point, input, input_length, context) ||
            EC_POINT_mul(group, result, NULL, point, value, context) != 1) goto cleanup;
    }
    success = point_write(group, result, output, context);
cleanup:
    EC_POINT_clear_free(point);
    EC_POINT_clear_free(result);
    BN_clear_free(value);
    BN_CTX_free(context);
    EC_GROUP_free(group);
    if (!success) leap_crypto_cleanse(output, 65);
    return success;
}

int leap_sm2_public_key(const uint8_t scalar[32], uint8_t output[65]) {
    return multiply(scalar, NULL, 0, 1, output);
}

int leap_sm2_multiply_point(const uint8_t scalar[32], const uint8_t *point,
                          size_t point_length, uint8_t output[65]) {
    return multiply(scalar, point, point_length, 0, output);
}

int leap_sm2_multiply_scalars(const uint8_t a[32], const uint8_t b[32], uint8_t output[32]) {
    int success = 0;
    EC_GROUP *group = NULL;
    BIGNUM *left = NULL, *right = NULL, *result = NULL;
    BN_CTX *context = NULL;
    if (!output) return 0;
    if (!(group = EC_GROUP_new_by_curve_name(NID_sm2)) ||
        !(context = BN_CTX_secure_new()) || !(left = scalar_read(a, group)) ||
        !(right = scalar_read(b, group)) || !(result = BN_secure_new())) goto cleanup;
    BN_set_flags(result, BN_FLG_CONSTTIME);
    /* BN_FLG_CONSTTIME is best effort only. BN_mod_mul does not document a
     * blanket constant-time guarantee; this offline bridge is not audited for
     * timing side channels and must not independently open the hardware gate. */
    if (BN_mod_mul(result, left, right, EC_GROUP_get0_order(group), context) != 1 ||
        BN_is_zero(result) || BN_bn2binpad(result, output, 32) != 32) goto cleanup;
    success = 1;
cleanup:
    BN_clear_free(left);
    BN_clear_free(right);
    BN_clear_free(result);
    BN_CTX_free(context);
    EC_GROUP_free(group);
    if (!success) leap_crypto_cleanse(output, 32);
    return success;
}

int leap_sm2_certificate_public_key(const uint8_t *der, size_t der_length, uint8_t output[65]) {
    int success = 0;
    const uint8_t *encoded_point = NULL, *cursor = der;
    size_t point_length = 0;
    X509 *certificate = NULL;
    EC_GROUP *group = NULL;
    EC_POINT *point = NULL;
    BN_CTX *context = NULL;
    if (!output) return 0;
    if (!leap_strict_sm2_certificate(der, der_length, &encoded_point, &point_length)) goto cleanup;
    if (!(certificate = d2i_X509(NULL, &cursor, (long)der_length)) || cursor != der + der_length ||
        ASN1_TIME_check(X509_get0_notBefore(certificate)) != 1 ||
        ASN1_TIME_check(X509_get0_notAfter(certificate)) != 1) goto cleanup;
    if (!(group = EC_GROUP_new_by_curve_name(NID_sm2)) || !(context = BN_CTX_secure_new()) ||
        !(point = EC_POINT_new(group)) || !point_read(group, point, encoded_point, point_length, context)) goto cleanup;
    success = point_write(group, point, output, context);
cleanup:
    EC_POINT_clear_free(point);
    BN_CTX_free(context);
    EC_GROUP_free(group);
    X509_free(certificate);
    if (!success) leap_crypto_cleanse(output, 65);
    return success;
}

int leap_sm3(const uint8_t *input, size_t input_length, uint8_t output[32]) {
    int success = 0;
    unsigned int written = 0;
    EVP_MD *algorithm = NULL;
    EVP_MD_CTX *context = NULL;
    if (!output) return 0;
    if ((!input && input_length) || !(algorithm = EVP_MD_fetch(NULL, "SM3", NULL)) ||
        !(context = EVP_MD_CTX_new()) || EVP_DigestInit_ex2(context, algorithm, NULL) != 1 ||
        (input_length && EVP_DigestUpdate(context, input, input_length) != 1) ||
        EVP_DigestFinal_ex(context, output, &written) != 1 || written != 32) goto cleanup;
    success = 1;
cleanup:
    EVP_MD_CTX_free(context);
    EVP_MD_free(algorithm);
    if (!success) leap_crypto_cleanse(output, 32);
    return success;
}

static int sm4_cbc(int encrypt, const uint8_t key[16], const uint8_t iv[16],
                    const uint8_t *input, size_t input_length, uint8_t *output,
                    size_t output_capacity, size_t *written) {
    int success = 0, first = 0, final = 0;
    size_t temporary_length = 0;
    uint8_t *temporary = NULL;
    EVP_CIPHER *algorithm = NULL;
    EVP_CIPHER_CTX *context = NULL;
    if (written) *written = 0;
    if (!written || !key || !iv || !output || (!input && input_length) ||
        input_length > (size_t)INT_MAX - 16 ||
        (!encrypt && (!input_length || input_length % 16))) goto cleanup;
    temporary_length = encrypt ? (input_length / 16 + 1) * 16 : input_length;
    if (output_capacity < temporary_length || !(temporary = OPENSSL_malloc(temporary_length)) ||
        !(algorithm = EVP_CIPHER_fetch(NULL, "SM4-CBC", NULL)) || !(context = EVP_CIPHER_CTX_new()) ||
        EVP_CipherInit_ex2(context, algorithm, key, iv, encrypt, NULL) != 1 ||
        EVP_CIPHER_CTX_set_padding(context, 1) != 1 ||
        (input_length && EVP_CipherUpdate(context, temporary, &first, input, (int)input_length) != 1) ||
        EVP_CipherFinal_ex(context, temporary + first, &final) != 1 ||
        first < 0 || final < 0 || (size_t)first + (size_t)final > temporary_length) goto cleanup;
    *written = (size_t)first + (size_t)final;
    if (*written) memcpy(output, temporary, *written);
    success = 1;
cleanup:
    EVP_CIPHER_CTX_free(context);
    EVP_CIPHER_free(algorithm);
    OPENSSL_clear_free(temporary, temporary_length);
    if (!success) leap_crypto_cleanse(output, output_capacity);
    return success;
}

int leap_sm4_cbc_encrypt(const uint8_t key[16], const uint8_t iv[16],
                         const uint8_t *input, size_t input_length,
                         uint8_t *output, size_t output_capacity, size_t *written) {
    return sm4_cbc(1, key, iv, input, input_length, output, output_capacity, written);
}

int leap_sm4_cbc_decrypt(const uint8_t key[16], const uint8_t iv[16],
                         const uint8_t *input, size_t input_length,
                         uint8_t *output, size_t output_capacity, size_t *written) {
    return sm4_cbc(0, key, iv, input, input_length, output, output_capacity, written);
}
