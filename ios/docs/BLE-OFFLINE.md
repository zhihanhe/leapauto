# BLE 离线移植边界

当前包含协议、离线会话状态机和传输适配源码，**不包含可使用的蓝牙钥匙**。`BLEHardwareFeatureGate.isEnabled` 固定返回 `false`；没有设置项、环境变量或依赖注入开关能够启用它。App 不创建 `BLETransport`，即使创建也不会初始化 `CBCentralManager`；扫描、连接和写入全部拒绝。未声明蓝牙权限或后台模式。

## 已移植且可以离线测试

- `0xAB/AC/AE/EE` 帧长度检查、流式重组、坏输入重新同步和缓冲上限
- 广播 UUID 中的协议 minor、车型默认值、CRC8、已解密文本解析及事件字段
- 两种分片 profile 均按既有 Kotlin/test 的 160 字节硬上限；旧 API.md 的 197 字节描述不作为实现依据
- iOS 使用 `maximumWriteValueLength` 的真实 payload 上限，不像 Android ATT MTU 一样减 3
- 串行 GATT 写 ACK 队列、一次连接一次手动操作确认、会话/车辆代次变化、超时和未知结果
- SM3、SM4-CBC/PKCS7、SM2 身份摘要、单块 KDF 及密码卡派生的离线参考，见 `BLECryptoTests`
- 新增 `BLEOfflineSM2Session`：从有请求身份绑定的证书快照完成离线派生、AA AE 认证帧、AA AB 手动开/闭锁帧、响应解密和一次连接的认证/命令状态约束，见 `BLEOfflineSessionTests`

协议依据保留在根目录 `API/BLUETOOTH_PROTOCOL.md`、`API/BLUETOOTH_CERTIFICATE.md`。Android 历史参考：[BleKeyProtocol.kt](https://github.com/zhihanhe/leapauto/blob/106b633bc4dbd0c816dd70e3160c22135e0cec6a/app/src/main/java/com/leapauto/app/bluetooth/BleKeyProtocol.kt)、[BleSm2Crypto.kt](https://github.com/zhihanhe/leapauto/blob/106b633bc4dbd0c816dd70e3160c22135e0cec6a/app/src/main/java/com/leapauto/app/bluetooth/BleSm2Crypto.kt)。所有测试使用公开合成夹具，不使用真实账号、私钥或车辆凭据。

## 离线会话的具体边界

`BLEOfflineKeyCertificate` 保存六个协议字段及证书请求时的账号、VIN、登录代次、设备 ID 绑定。绑定元数据不发送给车辆，不能由广播名、MAC、RSSI 或未验证的载入值推断。创建会话时匹配当前身份；每次认证、收包和命令入口重新检查身份与连接代次，不匹配立即关闭。证书快照在会话中不可替换。该构造器只做结构检查，并不赋予信任、权限或证书有效性。

认证要求显式选择兼容 profile：

- `legacyVersioned` 保留所有证书文本字段，包括空字段；账号/设备字段由绑定身份替换。minor 小于 9 的手动标志为 `0;0;`，其余为 `1;0;0;0;`
- `onePaoV010` 对齐清理前 Android 当前源码的默认布局：恰好六个证书字段，固定四个手动标志 `1;0;0;0;`
- 两者使用 AA AE 长度、UInt32LE 文本长度、原始签名字节、Base64(SM4) 和固定 `01 09` 尾部。该尾部并不代表广播 minor 被强制改为 9
- `.c10C16` 对应上游车型校准 `69;1.00;04;21`；`.standard` 为 `56;2.00;08;16`。这些是原始协议参数，不能解释成米或承诺真实距离行为
- 所有帧只包含手动模式；没有无感解锁、自动落锁或按钮启用入口。选择 C10 校准或某个 profile 不能证明该车认证会成功

认证的两个条件缺一不可：当前连接的认证写入已开始并收到全部 GATT ACK，以及在同一待处理认证窗口成功解密的非空 type-0 回复。可以先收到回复再收到最后一个 ACK，顺序不会造成误判；仅 GATT 成功、明文事件或旧连接回调都不能认证。这里的“authenticated”是恢复协议的应答状态，不是 CBC 的消息完整性证明或 CA 验证。

手动开/闭锁仅在该离线状态机认证后、当前账号/车辆/连接确认仍匹配且界面可见、前台条件满足时构帧。仍需未来 App 层本机认证/PIN 与真实用户点击，不能把这些布尔参数当成身份认证。主动且匹配的事件必须在写入开始后到达才确认动作；命令文本回复或 GATT ACK 不确认动作。每条连接只允许一个动作，完成、断开、超时或拒绝后关闭，写入开始后的不确定结果不自动重发、不自动切换 HTTP。`terminalCommandOutcome` 在异常关闭后仍保留 `notSent`/`unknown`（或已确认的 `confirmed`），防止调用方把解密错误或身份切换误报成安全未发送。

AA EE 快速重连仅保留帧解码支持，未加入重连认证构帧或凭据持久化；收到的重连凭据直接丢弃。当前没有足够的证书生命周期与凭据来源绑定来安全启用该流程。

## 完整 SM2 的确切缺口

`BLESM2Provider` 定义 sm2p256v1 曲线运算、模阶标量运算与严格 X.509 解析边界。默认实现 `BLEUnavailableSM2Provider` 始终失败。测试中的严格回放 provider 只接受公开固定输入，位于测试 target，不能处理任意证书或真实密钥。没有新增手写椭圆曲线实现。

Android 依赖 `org.bouncycastle:bcprov-jdk18on:1.86` 的底层 API；该 JVM 库不是可直接链接到 iOS 的原生依赖。仓库未包含适用于 iOS 的 SM2 后端、XCFramework、许可/构建配置、受信证书源或签名验证策略。Apple P-256 不能替代 SM2；纯编码/坐标范围检查也不能证明曲线成员关系或证书可信。不得用另一个 App 的真实钥匙/重连凭据填补缺口。

未来原生后端至少需要：完整且无尾随字节的 X.509 DER 解析，精确的 `id-ecPublicKey` 与 `sm2p256v1` OID，有限曲线点/压缩点验证，模阶乘法，符合已恢复公式的双重角色协议运算，可靠随机源与临时密钥生命周期。另须定义合法证书获取、账号-VIN-设备绑定、到期/撤销及密钥存储边界。

现有 SM3/SM4 是离线参考，并非经审计的生产密码库。SM4 使用秘密相关表索引，无恒定时间保证；Swift 值语义也不保证中间副本安全擦除。会话关闭只做尽力擦除和释放。向量一致性不等于安全审计，本轮没有下载或绑定外部密码库，没有生成或保存真实密钥。

## 离线向量与验证

从仓库根目录可运行：

```sh
node API/fixtures/bluetooth/generate-sm2-vectors.cjs
node ios/scripts/generate-ble-session-vectors.cjs
swift test --package-path ios/Packages/LeapCore --filter BLEOfflineSessionTests
```

前两个脚本由本地 Node/OpenSSL 独立生成合成向量，没有网络/BLE 操作。新增 Swift 测试覆盖 legacy minor 8/9 完整认证帧、C10 固定布局、空/额外字段、手动命令、双条件认证、乱序 ACK、过期、身份/连接切换、畸形密文/UTF-8、单次命令与未知结果。云容器已执行向量生成和结构检查；Swift/Xcode 结果应以实际 Mac 验证记录为准，不能从脚本成功推断。

## CoreBluetooth 适配与启用条件

适配仅定位明确 UUID 的候选设备，不用 MAC、设备名或 RSSI 信任车辆。服务/特征匹配、通知启用或写入成功都不表示已经通过钥匙认证。CoreBluetooth 标识为系统 UUID，而非 Android MAC。[Apple 标识说明](https://developer.apple.com/documentation/corebluetooth/cbpeer/identifier)

启用前还必须完成：

1. 合规且经审计的原生 SM2/SM3/SM4 后端及独立互操作向量
2. 证书获取/到期/撤销、账号-VIN-设备绑定和生产级会话集成
3. Xcode 类型检查、蓝牙权限、严格 GATT 回调/断连与真实设备场景验收
4. 明确用户操作、车辆安全状态、本机认证和操作结果回执
5. 车辆所有者在安全场地明确授权后的逐项测试

现有上游记录曾出现 GATT 和 SM2 派生成功后认证拒绝 code 9，不能给 code 9 自行赋予“证书过期”“密码错误”等含义；离线移植也不能被称为已修复 C10 实车连接。

当前未启用后台恢复或无感靠近动作。iOS 后台 BLE 是系统管理的事件唤醒，不保证 Android 前台 Service 式常驻；不能承诺靠近必解锁或离车必锁。[Apple 后台说明](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html)
