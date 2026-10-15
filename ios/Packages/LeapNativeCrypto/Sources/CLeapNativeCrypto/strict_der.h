#ifndef LEAP_STRICT_DER_H
#define LEAP_STRICT_DER_H
#include <stddef.h>
#include <stdint.h>
int leap_strict_sm2_certificate(const uint8_t *der, size_t length,
                                const uint8_t **point, size_t *point_length);
#endif
