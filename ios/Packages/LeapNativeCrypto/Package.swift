// swift-tools-version: 5.9
import PackageDescription
import Foundation

// This package is deliberately separate from the application and LeapCore.
// It never downloads OpenSSL or enables BLE hardware. See NATIVE-CRYPTO.md.
let environment = ProcessInfo.processInfo.environment
let prefix = environment["LEAP_OPENSSL_PREFIX"]
let useAppleArtifact = environment["LEAP_OPENSSL_XCFRAMEWORK"] == "1"
var targets: [Target] = []
var cDependencies: [Target.Dependency] = []
var cSettings: [CSetting] = []
var linkerSettings: [LinkerSetting] = []
if useAppleArtifact {
    targets.append(.binaryTarget(name: "OpenSSLCrypto", path: ".build/native/OpenSSLCrypto.xcframework"))
    cDependencies = ["OpenSSLCrypto"]
} else if let prefix, !prefix.isEmpty {
    cSettings = [.unsafeFlags(["-I", prefix + "/include"])]
    linkerSettings = [.unsafeFlags(["-L", prefix + "/lib"]), .linkedLibrary("crypto")]
} else {
    targets.append(.systemLibrary(name: "COpenSSL", pkgConfig: "libcrypto"))
    cDependencies = ["COpenSSL"]
}
targets += [
    .target(name: "CLeapNativeCrypto", dependencies: cDependencies,
            publicHeadersPath: "include", cSettings: cSettings, linkerSettings: linkerSettings),
    .target(name: "LeapNativeCrypto", dependencies: ["CLeapNativeCrypto", .product(name: "LeapCore", package: "LeapCore")]),
    .testTarget(name: "LeapNativeCryptoTests", dependencies: ["LeapNativeCrypto", "CLeapNativeCrypto", .product(name: "LeapCore", package: "LeapCore")])
]
let package = Package(
    name: "LeapNativeCrypto",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "LeapNativeCrypto", targets: ["LeapNativeCrypto"])],
    dependencies: [.package(path: "../LeapCore")],
    targets: targets
)
