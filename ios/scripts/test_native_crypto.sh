#!/usr/bin/env bash
# Isolated offline C regression tests. This does not link the iOS app or use BLE.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PACKAGE="$ROOT/ios/Packages/LeapNativeCrypto"
SANITIZE=0
case "${1:-}" in
  '') ;;
  --sanitize) SANITIZE=1; shift ;;
  --help|-h)
    cat <<'EOF'
Usage: ios/scripts/test_native_crypto.sh [--sanitize]

Compiles and runs the native C harness with existing OpenSSL 3.x only.
LEAP_OPENSSL_PREFIX selects an existing include/ + lib/libcrypto.a prefix.
Otherwise pkg-config libcrypto is used, or the compiler's system search paths.
CC selects one compiler executable (not a shell command). No downloads/installs.
--sanitize adds AddressSanitizer and UndefinedBehaviorSanitizer to the bridge
and harness; the existing OpenSSL library is not recompiled/instrumented.
EOF
    exit 0 ;;
  *) echo "Unknown argument: $1 (see --help)" >&2; exit 2 ;;
esac
[[ $# -eq 0 ]] || { echo 'Unexpected extra arguments.' >&2; exit 2; }
CC="${CC:-cc}"
command -v "$CC" >/dev/null || { echo "C compiler unavailable: $CC" >&2; exit 2; }
command -v python3 >/dev/null || { echo 'Python 3 is required to safely parse pkg-config flags.' >&2; exit 2; }
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/leap-native-crypto.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
CFLAGS=(-std=c11 -Wall -Wextra -Werror -pedantic)
INCLUDES=(-I "$PACKAGE/Sources/CLeapNativeCrypto/include")
LIBS=()
if [[ -n "${LEAP_OPENSSL_PREFIX:-}" ]]; then
  [[ -f "$LEAP_OPENSSL_PREFIX/include/openssl/opensslv.h" ]] || {
    echo 'LEAP_OPENSSL_PREFIX is missing include/openssl/opensslv.h.' >&2; exit 2;
  }
  [[ -f "$LEAP_OPENSSL_PREFIX/lib/libcrypto.a" ]] || {
    echo 'LEAP_OPENSSL_PREFIX is missing lib/libcrypto.a (a host-architecture static build is required).' >&2; exit 2;
  }
  INCLUDES+=(-I "$LEAP_OPENSSL_PREFIX/include")
  LIBS+=("$LEAP_OPENSSL_PREFIX/lib/libcrypto.a")
  [[ "$(uname -s)" != Linux ]] || LIBS+=(-ldl -pthread)
elif command -v pkg-config >/dev/null && pkg-config --exists libcrypto; then
  pkg-config --cflags libcrypto > "$CHECK_DIR/cflags"
  pkg-config --libs libcrypto > "$CHECK_DIR/libs"
  # shlex handles quoted/escaped paths without eval or word splitting.
  for name in cflags libs; do
    python3 - "$CHECK_DIR/$name" > "$CHECK_DIR/$name.nul" <<'PY'
import pathlib, shlex, sys
for flag in shlex.split(pathlib.Path(sys.argv[1]).read_text()):
    sys.stdout.buffer.write(flag.encode() + b'\0')
PY
  done
  while IFS= read -r -d '' flag; do INCLUDES+=("$flag"); done < "$CHECK_DIR/cflags.nul"
  while IFS= read -r -d '' flag; do LIBS+=("$flag"); done < "$CHECK_DIR/libs.nul"
else
  LIBS+=(-lcrypto)
fi
if [[ "$SANITIZE" -eq 1 ]]; then
  CFLAGS+=(-O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer)
else
  CFLAGS+=(-O2)
fi
cat > "$CHECK_DIR/prerequisite.c" <<'C'
#include <openssl/crypto.h>
#include <openssl/opensslv.h>
#include <stdio.h>
#if OPENSSL_VERSION_MAJOR != 3
#error "OpenSSL 3.x headers are required; LibreSSL is not a replacement."
#endif
int main(void) {
    if (OpenSSL_version_num() != OPENSSL_VERSION_NUMBER) {
        fputs("OpenSSL header/library version mismatch.\n", stderr);
        return 1;
    }
    puts(OpenSSL_version(OPENSSL_VERSION));
    return 0;
}
C
if ! "$CC" "${CFLAGS[@]}" "${INCLUDES[@]}" "$CHECK_DIR/prerequisite.c" "${LIBS[@]}" -o "$CHECK_DIR/prerequisite"; then
  echo 'Native tests NOT RUN: OpenSSL 3.x headers + matching host libcrypto and requested compiler/sanitizer support are required.' >&2
  echo 'On Mac, supply LEAP_OPENSSL_PREFIX from an approved source build; see ios/docs/NATIVE-CRYPTO.md.' >&2
  exit 2
fi
"$CHECK_DIR/prerequisite"
shopt -s nullglob
SOURCES=("$PACKAGE"/Sources/CLeapNativeCrypto/*.c)
[[ ${#SOURCES[@]} -gt 0 && -f "$PACKAGE/Tests/NativeHarness/main.c" ]] || {
  echo 'Native C source or Tests/NativeHarness/main.c is missing.' >&2; exit 2;
}
"$CC" "${CFLAGS[@]}" "${INCLUDES[@]}" "${SOURCES[@]}" \
  "$PACKAGE/Tests/NativeHarness/main.c" "${LIBS[@]}" -o "$CHECK_DIR/native-crypto-tests"
(cd "$PACKAGE" && "$CHECK_DIR/native-crypto-tests")
printf '\nNative C harness passed (sanitizers=%s). Swift, Xcode, simulator and real-device tests are separate.\n' "$SANITIZE"
