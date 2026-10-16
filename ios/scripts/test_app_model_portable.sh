#!/usr/bin/env bash
# Offline Linux orchestration coverage only; NOT Apple SDK validation.
set -euo pipefail

if [[ "$(uname -s)" != "Linux" ]]; then
  printf 'This compatibility harness is Linux-only. Use validate_macos.sh for Apple SDK validation.\n' >&2
  exit 2
fi

IOS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWIFT_BIN="${SWIFT_BIN:-swift}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/Sources/Combine" "$WORK_DIR/Sources/LeapAuto" \
  "$WORK_DIR/Tests/LeapAutoTests" "$WORK_DIR/home" "$WORK_DIR/cache" "$WORK_DIR/config" "$WORK_DIR/tmp"

cp "$IOS_ROOT/scripts/portable-app-model/Combine.swift" "$WORK_DIR/Sources/Combine/"
cp "$IOS_ROOT/scripts/portable-app-model/UnavailableAppleAdapters.swift" "$WORK_DIR/Sources/LeapAuto/"
cp "$IOS_ROOT/LeapAuto/App/AppModel.swift" "$IOS_ROOT/LeapAuto/App/DemoFixtures.swift" \
  "$IOS_ROOT/LeapAuto/Security/SessionLifecycleStore.swift" "$WORK_DIR/Sources/LeapAuto/"
cp "$IOS_ROOT/LeapAutoTests/"*.swift "$WORK_DIR/Tests/LeapAutoTests/"
mkdir -p "$WORK_DIR/LeapCore"
cp "$IOS_ROOT/Packages/LeapCore/Package.swift" "$WORK_DIR/LeapCore/"
cp -R "$IOS_ROOT/Packages/LeapCore/Sources" "$IOS_ROOT/Packages/LeapCore/Tests" "$WORK_DIR/LeapCore/"

cat > "$WORK_DIR/Package.swift" <<'SWIFT'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "LeapAuto",
    dependencies: [.package(path: "LeapCore")],
    targets: [
        .target(name: "Combine"),
        .target(name: "LeapAuto", dependencies: ["Combine", .product(name: "LeapCore", package: "LeapCore")]),
        .testTarget(name: "LeapAutoTests", dependencies: ["LeapAuto", .product(name: "LeapCore", package: "LeapCore")])
    ]
)
SWIFT

printf 'Running actual AppModel offline regressions on Linux. NOT Apple SDK validation.\n'
HOME="$WORK_DIR/home" XDG_CACHE_HOME="$WORK_DIR/cache" XDG_CONFIG_HOME="$WORK_DIR/config" TMPDIR="$WORK_DIR/tmp" \
  LEAPAUTO_OFFLINE_TESTS=1 "$SWIFT_BIN" test --package-path "$WORK_DIR" "$@"
