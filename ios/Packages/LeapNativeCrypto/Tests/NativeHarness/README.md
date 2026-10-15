# Native offline C harness

Run from the repository root using the existing OpenSSL 3.x host installation:

```sh
./ios/scripts/test_native_crypto.sh
ASAN_OPTIONS=detect_leaks=0 ./ios/scripts/test_native_crypto.sh --sanitize
```

The second command disables LeakSanitizer only for environments where ptrace or
sandbox restrictions prevent it from running. AddressSanitizer and
UndefinedBehaviorSanitizer remain enabled for the bridge and harness; the
installed OpenSSL library is not rebuilt or instrumented. Do not describe this as
LeakSanitizer coverage. The harness has no network, hardware, credential, fixture
file, or current-time dependencies. OpenSSL may initialize its normal local
provider/configuration machinery.

## Coverage

- SM2 generator and arbitrary finite-point multiplication, compressed SEC1 points,
  scalar modular multiplication, exact order boundaries, zero/overflow scalars,
  bad coordinate/point encodings, null inputs, and failure-output clearing.
- Synthetic X.509 containers, full DER consumption, DER minimal lengths and
  INTEGER/OID encodings, UTF-8, SET ordering, certificate version DEFAULT omission,
  exact SPKI `id-ecPublicKey` / SM2 curve OIDs, zero SPKI BIT STRING padding,
  finite curve points, date encoding/calendar fields, and certificate truncation.
- Supported extension schemas, their DEFAULT omission and uniqueness; unknown
  extensions, malformed KeyUsage, invalid BasicConstraints, and opaque signature
  parameters fail closed. The regression with explicit RSASSA-PSS trailerField
  DEFAULT 1 ensures an OpenSSL decode/re-encode cache cannot replace DER checking.
- 2,000 deterministic single-bit certificate mutations under the same memory
  safety checks. This is smoke coverage, not exhaustive fuzzing or a security audit.
- Standard SM3 vectors, standard SM4 block vector within CBC, PKCS#7 boundaries,
  padding failure, allocation/capacity/input checks, and failure cleanup.
- The complete recovered custom SM2 agreement, identity hashes, KDF, card selector,
  final key/IV derivation, and unlock ciphertext from the repository's synthetic
  `API/fixtures/bluetooth/generate-sm2-vectors.cjs` reference.

The test certificates use placeholder signatures. Successful extraction does not
verify a certificate chain, signature, current validity, account identity, or VIN.
No test authorizes Bluetooth hardware or real vehicle use.

## Deliberately bounded certificate profile

The bridge validates generic DER framing/primitive canonicality and the exact
supported certificate schema before OpenSSL parsing. This is not a claim that a
generic ASN.1 walker can recognize every schema's DEFAULT fields.

Supported extension OIDs are BasicConstraints, KeyUsage (at most nine named bits),
and SubjectKeyIdentifier. Unknown or duplicate extensions are rejected. Signature
AlgorithmIdentifier parameters must be absent or NULL, so parameterized schemes
such as RSA-PSS are rejected. Distinguished-name values must use supported
primitive string encodings. Certificate serials are positive and at most 20
encoded octets. Dates require seconds and UTC `Z`, and actual calendar fields are
checked without testing the certificate's current validity. DER inputs are capped
at 128 KiB and 32 nesting levels.

A real certificate outside this profile remains unsupported. Expanding the profile
requires separate local evidence, schema-aware validation, regression tests, and
security review; callers must not silently retry with a permissive parser.

## Security and platform limits

Secret BIGNUMs and temporary byte buffers are cleared on cleanup. Secure BIGNUM
allocation does not establish that a platform has configured OpenSSL secure heap
or locked memory. Swift copy-on-write and other caller copies have separate
lifetimes. `BN_FLG_CONSTTIME` is applied, but `BN_mod_mul` does not provide a blanket
constant-time contract; the complete provider is not claimed timing-audited or
production-ready. CBC is unauthenticated and must not expose padding failures to
a remote peer. No diagnostic contains input, point, certificate, or key bytes.

Host C tests do not establish Swift compilation, Apple SDK linkage, simulator,
iPhone, or vehicle acceptance. The package remains separate from application
hardware enablement.

No upstream source or binary is vendored here. OpenSSL 3.x is an external
Apache-2.0 dependency; distribution must preserve the applicable upstream license,
notices, and repository rights. This wrapper does not change the repository's
licensing or grant missing distribution rights.
