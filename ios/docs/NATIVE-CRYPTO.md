# 隔离的原生密码后端

核查日期：2026-10-15。`Packages/LeapNativeCrypto` 是独立的离线开发包，使用现有 OpenSSL 3.x 提供原生 C 原语和 Swift `BLESM2Provider` 适配。**主 App、Widget 和 LeapCore 默认依赖没有切换到它，真实 BLE 门禁保持关闭。** 此包不请求登录、网络、蓝牙、钥匙激活或车辆控制，不包含真实私钥/证书，也不是可发布的密码组件。

## 1. 实现与仍缺少的安全条件

- C 层：SM2 `dG`、`kP`、模曲线阶标量乘法、严格 DER X.509 中的 SM2 公钥提取、SM3、SM4-CBC/PKCS#7，以及调用方临时缓冲区清除。
- SM2 与 P-256 是不同曲线，不能相互替代。私有标量必须在 `[1, n-1]`；输入点必须有合法编码、位于 SM2 曲线上且不是无穷点。
- 证书入口只接受完整、规范 DER 的 X.509 证书，要求明确的 EC 公钥算法与 SM2 named-curve OID。证书扩展仅支持 BasicConstraints、KeyUsage 和 SubjectKeyIdentifier；未知扩展结构拒绝，不默默降级。
- 提取公钥**不验证**证书链、签名、有效时间、吊销状态，也不建立账号/VIN/车辆身份绑定。缺少这些条件不能开放硬件。
- SM4-CBC 不提供消息真实性；不能把解密/填充错误暴露为对端可观察的 oracle。
- Swift `Data` 的复制和写时复制不保证秘密完全清除。C 临时清理、原生库调用和向量通过，均不是整个 Swift 会话的恒定时间或秘密生命周期审计。
- Swift 的 SM2 协议兼容测试通过 `BLEOfflineSM2` 编排；该编排仍使用既有离线 SM3 参考。原生 SM3 有独立测试，不能把协议测试描述成“全部秘密路径已替换为原生”。

路径：

```text
ios/Packages/LeapNativeCrypto/
  Package.swift
  Sources/CLeapNativeCrypto/include/leap_native_crypto.h
  Sources/CLeapNativeCrypto/*.c
  Sources/COpenSSL/
  Sources/LeapNativeCrypto/
  Tests/NativeHarness/main.c
  Tests/LeapNativeCryptoTests/
```

## 2. 宿主机 C 验证：优先运行

从仓库根目录运行：

```sh
./ios/scripts/test_native_crypto.sh
./ios/scripts/test_native_crypto.sh --sanitize
python3 ios/scripts/test_native_crypto_build.py -v
```

前两个命令只编译 C 桥接和合成夹具。默认通过已有的 `pkg-config libcrypto`，或编译器系统路径寻找库。脚本要求 OpenSSL 3.x 头文件与实际链接库版本完全相符；LibreSSL 不能代替。`--sanitize` 对本项目桥接及 harness 开启 AddressSanitizer/UndefinedBehaviorSanitizer，不会重新编译或完整插桩已有 OpenSSL。

本轮云端 sanitizer 默认运行在 prerequisite 阶段遇到 LeakSanitizer 的 ptrace 环境限制，并非已通过 leak 检查。明确关闭 leak detection 后，`ASAN_OPTIONS=detect_leaks=0 ./ios/scripts/test_native_crypto.sh --sanitize` 实际通过；这只计为 ASan/UBSan 证据，泄漏检测仍未运行。脚本不自动关闭检测，在没有该环境限制的 Mac/CI 应优先保留默认检查。

Mac 上若已有经批准的宿主机 OpenSSL 静态构建，可明确指定 prefix。当前只读环境检查发现 `/opt/homebrew/opt/openssl@3` 有 macOS arm64 的 OpenSSL 3.6.4 头文件和静态库；它不是 iOS 库，也与云端现有 3.5.7 的版本不同。下列命令是验证入口，是否通过必须看实际执行记录：

```sh
export LEAP_OPENSSL_PREFIX=/opt/homebrew/opt/openssl@3
./ios/scripts/test_native_crypto.sh
./ios/scripts/test_native_crypto.sh --sanitize
swift test --package-path ios/Packages/LeapNativeCrypto
```

prefix 必须包含 `include/openssl/opensslv.h` 与 `lib/libcrypto.a`，且库架构/最低 macOS 版本适合当前机器。不要把 iPhoneOS 或 iOS Simulator 静态库用于宿主机测试。环境缺少头文件、静态库、编译器、Swift 或 sanitizer 时，相关阶段是“未运行/阻塞”，不是通过；本脚本不会自动安装软件或寻找未审核二进制。

## 3. SwiftPM 链接选择

独立包在加载 manifest 时读取：

1. `LEAP_OPENSSL_XCFRAMEWORK=1`：使用包内固定路径 `.build/native/OpenSSLCrypto.xcframework`，binary target/module 名为 `OpenSSLCrypto`。这个开关不是文件路径，且不能用于仅含 iOS slices 的宿主机测试。
2. 否则，非空 `LEAP_OPENSSL_PREFIX`：显式使用该目录的 `include` 和 `lib`，只适用于匹配目标平台/架构的库。
3. 否则：使用 `COpenSSL` system-library target 与 `pkg-config libcrypto`。

没有任何远端二进制 URL 或自动下载。prefix 使用 SwiftPM 本地 unsafe search flags，因此这是隔离的本地验证配置，不应作为已完成的可分发 SwiftPM 依赖方案。切换平台/依赖模式时使用独立 scratch directory；不要让宿主机产物冒充 iOS 编译结果。

## 4. 可复核的源码构建配方

`ios/scripts/build_native_crypto_openssl.py` 是**尚需 Mac 实际执行的构建配方**。它只消费用户已经批准、独立核实来源的本地 OpenSSL **3.5.7** 干净源码目录。它不下载源码、安装开发工具、修改系统 prefix、签名或接入 App。仅调用源码中的构建过程，把 development outputs 放进明确指定的新目录；已有输出目录不会被覆盖或删除。

需要：macOS、完整 Xcode、对应 macOS/iPhoneOS/iPhoneSimulator SDK、Python 3.8+、Perl、make，以及经批准的源码目录。Mac 现有 Homebrew 库足以尝试宿主机测试，但不能替代 iOS 源码/SDK 构建前提。未取得源码与执行授权前，不运行下列 build 命令。

先独立核实源码来自官方发布版本及其发布签名/校验和，再计算并记录本脚本定义的 tree hash：

```sh
python3 ios/scripts/build_native_crypto_openssl.py \
  --source "/approved/source/openssl-3.5.7" --print-source-sha256
```

tree hash 是排序后的每个相对文件路径、NUL、文件 SHA-256 和换行的 SHA-256；只排除根目录 `.git` 元数据，拒绝符号链接及已配置的源码。它与官方下载归档的 SHA-256 不同。**自行算出的 hash 只记录内容，不能证明来源可信。** 后续传入先前记录并核实过的值，不能用“刚计算再原样传入”替代来源审核。

需要单独的 macOS 宿主机 prefix 时：

```sh
python3 ios/scripts/build_native_crypto_openssl.py \
  --source "/approved/source/openssl-3.5.7" \
  --source-sha256 "<previously-reviewed-tree-sha256>" \
  --mode macos \
  --output "$PWD/ios/Packages/LeapNativeCrypto/.build/native-host"

LEAP_OPENSSL_PREFIX="$PWD/ios/Packages/LeapNativeCrypto/.build/native-host" \
  ./ios/scripts/test_native_crypto.sh
LEAP_OPENSSL_PREFIX="$PWD/ios/Packages/LeapNativeCrypto/.build/native-host" \
  swift test --package-path ios/Packages/LeapNativeCrypto
```

iOS 源码构建：

```sh
python3 ios/scripts/build_native_crypto_openssl.py \
  --source "/approved/source/openssl-3.5.7" \
  --source-sha256 "<previously-reviewed-tree-sha256>" \
  --mode ios \
  --output "$PWD/ios/Packages/LeapNativeCrypto/.build/native"
```

配方使用官方 `ios64-xcrun`（device arm64）、`iossimulator-arm64-xcrun` 与 `iossimulator-x86_64-xcrun`。仅两种 simulator 架构用 `lipo` 合并，再与 device 库分别打包成 XCFramework；绝不把 device 和 simulator 合成一个 fat library。deployment target 为 iOS 17，宿主机配方为 macOS 13。不同 simulator 架构的生成配置头保留各自内容并通过架构条件分发；其他头文件出现差异就停止。

输出包括源码逐文件 hash、完整构建参数/Xcode/SDK 信息、输出 hash、构建日志，以及从源码保存的 LICENSE/NOTICE/COPYING/AUTHORS/COPYRIGHT 文件。XCFramework 内另保留 Notices。失败时 manifest 标记 partial output 不可使用；成功仅表示库构建结束，**脚本不运行 OpenSSL 上游测试，也不证明 iOS 应用链接或设备行为**。需要进一步审查来源、版本安全公告、配置、法律义务、二进制内容和复现结果。

## 5. iOS 独立包编译配方

下面只在已取得并成功构建上节本地 XCFramework 后尝试，仍需实际 Mac 执行验证。它们不把包加入 `LeapAuto.xcodeproj`，不签名，也不运行真实蓝牙。环境与 SwiftPM 版本可能使交叉编译失败，应保留原始诊断，不将失败替换成默认系统库链接。

```sh
PACKAGE="$PWD/ios/Packages/LeapNativeCrypto"
export LEAP_OPENSSL_XCFRAMEWORK=1
unset LEAP_OPENSSL_PREFIX

xcrun swift build --package-path "$PACKAGE" \
  --scratch-path "$PACKAGE/.build/ios-simulator-arm64" \
  --triple arm64-apple-ios17.0-simulator \
  --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)"

xcrun swift build --package-path "$PACKAGE" \
  --scratch-path "$PACKAGE/.build/ios-simulator-x86_64" \
  --triple x86_64-apple-ios17.0-simulator \
  --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)"

xcrun swift build --package-path "$PACKAGE" \
  --scratch-path "$PACKAGE/.build/ios-device-arm64" \
  --triple arm64-apple-ios17.0 \
  --sdk "$(xcrun --sdk iphoneos --show-sdk-path)"

unset LEAP_OPENSSL_XCFRAMEWORK
```

编译通过仍不等于 simulator 执行 XCTest、Xcode App 链接、iPhone 测试或实车验收。实际接入 App 前还须增加对应 Apple 测试承载 target、验证每个 slice 的链接/执行、复核证书信任与身份绑定、会话随机数/秘密管理和硬件授权门禁。本轮没有这些授权，也不改变相关门禁。

独立包以外的回归仍须单独运行：

```sh
./ios/scripts/validate.sh
# On a suitably equipped Mac:
./ios/scripts/validate_macos.sh
```

## 6. 本轮证据边界

- 云端：已检查系统 OpenSSL 3.5.7 与 C 编译器；构建配方的 11 项纯 Python 回归通过，shell 语法检查通过。这些测试使用最小合成目录，不执行 OpenSSL 源码。
- 云端 C harness 实际通过；ASan/UBSan 在显式关闭受 ptrace 阻塞的 LeakSanitizer 后通过。详细覆盖与最后一次检查数量以本次执行记录为准；这不覆盖未经插桩的系统 OpenSSL 内部或泄漏检测。
- Swift 包、Mac 和现有 App 全套回归结果应以本次实际执行记录为准，不能从“测试脚本存在”推断通过。
- 原生包的 Apple XCFramework 构建、iOS 各架构编译、模拟器执行、iPhone 和真实车辆测试未由此文档证明。源码配方未执行不能称为“已支持 iPhone”。

## 7. 上游依据与许可

- [OpenSSL 3.5.7 官方 iOS targets](https://github.com/openssl/openssl/blob/openssl-3.5.7/Configurations/15-ios.conf)
- [OpenSSL 3.5.7 构建选项](https://github.com/openssl/openssl/blob/openssl-3.5.7/INSTALL.md)
- [Apple XCFramework 平台打包要求](https://developer.apple.com/documentation/xcode/creating-a-multi-platform-binary-framework-bundle)
- [OpenSSL 许可](https://openssl-library.org/source/license/index.html)

OpenSSL 3.x 使用 Apache-2.0；保留所用版本随附的适用许可与通知。源库可用不代表本应用具有所有上游源码、SDK、素材或协议的分发权。此文档和本地构建不授权签名、发布、传输真实凭据或车辆操作。
