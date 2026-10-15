#ifndef LEAP_NATIVE_CRYPTO_H
#define LEAP_NATIVE_CRYPTO_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Offline-only primitives. Return 1 on success, 0 on failure. No diagnostics.
 * Callers supply valid buffers of the stated sizes. Input/output must not overlap.
 * Scalars are unsigned, 32-byte big endian, and must be in [1, SM2 order - 1].
 * Points may be 33-byte compressed or 65-byte uncompressed SEC1 encodings.
 * All point outputs are 65-byte uncompressed encodings. On failure fixed-size
 * outputs are cleared; CBC clears output_capacity bytes and sets written to zero.
 * These functions do not establish certificate trust, account/vehicle binding,
 * hardware readiness, or an audited constant-time/production security guarantee.
 */
int leap_sm2_public_key(const uint8_t scalar[32], uint8_t output[65]);
int leap_sm2_multiply_point(const uint8_t scalar[32], const uint8_t *point,
                          size_t point_length, uint8_t output[65]);
int leap_sm2_multiply_scalars(const uint8_t a[32], const uint8_t b[32],
                            uint8_t output[32]);

/* A complete, structurally canonical DER X.509 Certificate only (no PEM, SPKI, or raw key).
 * Requires exact id-ecPublicKey + named SM2 curve, zero SPKI BIT STRING padding,
 * and a finite on-curve point. No chain, signature, time, or identity verification.
 * Supported extensions: BasicConstraints, KeyUsage, SubjectKeyIdentifier only.
 * Unknown extension schemas fail closed. Certificate DEFAULTs are checked.
 * Signature algorithm parameters must be absent/NULL; Name attribute values
 * must use supported primitive strings. Other schemas fail closed.
 * Certificates larger than 128 KiB or deeper than 32 DER levels are rejected.
 */
int leap_sm2_certificate_public_key(const uint8_t *der, size_t der_length,
                                    uint8_t output[65]);

int leap_sm3(const uint8_t *input, size_t input_length, uint8_t output[32]);

/* SM4-CBC with PKCS#7 padding. Maximum input: INT_MAX - 16 bytes.
 * Encrypt requires floor(input_length / 16) * 16 + 16 output capacity.
 * Decrypt requires input_length output capacity; input must be nonempty blocks.
 * Decrypted bytes are copied to caller only after padding validation succeeds.
 * CBC does not authenticate a message. Never expose padding errors to a peer.
 */
int leap_sm4_cbc_encrypt(const uint8_t key[16], const uint8_t iv[16],
                         const uint8_t *input, size_t input_length,
                         uint8_t *output, size_t output_capacity, size_t *written);
int leap_sm4_cbc_decrypt(const uint8_t key[16], const uint8_t iv[16],
                         const uint8_t *input, size_t input_length,
                         uint8_t *output, size_t output_capacity, size_t *written);

/* Wipes caller-owned temporary buffers; Swift copies/CoW remain caller concerns. */
void leap_crypto_cleanse(void *buffer, size_t length);

#ifdef __cplusplus
}
#endif
#endif
