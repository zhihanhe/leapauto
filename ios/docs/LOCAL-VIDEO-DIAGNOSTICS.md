# 本机合成视频编解码诊断

## 实现范围与证据边界

本模块是后续 iOS 屏幕共享工作的一个独立前置验证：

`合成彩条和计数 → BGRA CVPixelBuffer → VideoToolbox H.264 → VideoToolbox 解码 → 像素校验和预览`

不使用录制样例文件或模拟编码器。只有 Apple 解码器回调返回符合尺寸、BGRA 格式、彩条像素容差的图像，才累计“已解码”。H.264 是有损格式，彩条取中间点，每通道允许 48/255 的色彩转换和压缩误差。输入计数绘制为小型数字位图；没有字体或素材依赖。

这是**本机诊断，不是车机投屏**。仓库尚无已验证的车机发现、接收、会话握手、传输封装或鉴权协议。本模块不读取 AppModel、不接车辆会话、不请求真实车辆接口。

当前代码不使用 ReplayKit，不录制真实屏幕、不采集麦克风或应用音频、不联网、不保存帧或视频、不新增权限、entitlement 或后台模式。诊断的软硬件实现由 VideoToolbox 选择，不强制硬件编码，避免把模拟器平台限制伪装成功。

## 生命周期和资源约束

- 用户手动开始；默认 640 × 360、10 fps、800 kbps、最多提交 300 帧。另有 1280 × 720 / 2 Mbps 预设。
- 每次开始、重新开始或运行中切换尺寸，都替换整组编码器/解码器，并生成新 UUID。旧回调不能修改新轮统计或预览。
- 单一串行队列拥有 VideoToolbox 会话、合成源和状态机。输出闭包持有不可变 ticket，没有不安全的裸帧指针或手动 retain/release 回调上下文。
- 编码器关闭帧重排并请求最大帧延迟为 0，避免 lookahead 占满有限 admission 槽位而无法前进。若编码器明确返回 `kVTPropertyNotSupportedErr`（已在 iOS 26.5 模拟器观察到），改为在每次提交后排空实际编码帧；其他参数错误仍会失败，解码与像素验证不变。
- 在途默认最多 3 帧（配置允许 1–8），从提交前一直占用到解码、丢弃或失败。编码完成不会提前释放容量。
- 合成像素池分配阈值为在途上限加 1；停止后释放源和原生会话。预览最多每 250 ms 转换一次，UI 只保留一条最新待投递更新，不堆积主线程图像队列。
- 背压时跳过输入并计数，绝不为每帧创建无限 Task/队列。收到 codec 丢帧只释放相应 ticket 一次。
- 在途帧 5 秒未完成时，在下一次队列计时检查停止整轮并显示错误。它不是能够中断系统原生阻塞调用的硬实时保证，也不会在 codec 仍持有帧时释放槽位后继续无限提交。
- 到达有限帧数后排空编码器，全部已接纳帧结束后自动完成。没有实际解码帧时明确失败。
- 停止、离开视图、scene 不再活跃都会取消当前诊断；不自动恢复。停止后清除预览，保留统计；自然完成保留最后的合成解码预览。
- 状态分别统计背压丢帧、编解码丢帧、取消帧、失败帧、在途/峰值、压缩字节和平均/最大耗时。耗时包含图像生成、编码、解码、回调排队和像素校验，不是车机延迟。

编码器/解码器实际硬件状态无法读取时显示“未知”。编码器硬件状态属性仅在 iOS 17.4 以上读取；保持 App 的 iOS 17.0 最低版本。模拟器软件路径成功不能证明真机硬件路径或真机性能。

## 代码和工程接入

新增文件：

- `LeapAuto/ScreenCapture/SyntheticVideoFrameSource.swift`：合成输入、像素池、输出彩条验证；`LocalVideoFrameSource` 是本机源接口
- `LeapAuto/ScreenCapture/LocalVideoCodecEngine.swift`：真实编解码和资源生命周期
- `LeapAuto/ScreenCapture/LocalVideoCodecDiagnosticsModel.swift`：主线程状态与迟到 UI 更新隔离
- `LeapAuto/ScreenCapture/LocalVideoCodecDiagnosticsView.swift`：独立 SwiftUI 页面 `LocalVideoCodecDiagnosticsView`
- `Packages/LeapCore/Sources/LeapCore/LocalVideoCodecState.swift`：不依赖 Apple 媒体框架的配置、状态机和统计
- `Packages/LeapCore/Tests/LeapCoreTests/LocalVideoCodecStateTests.swift`：纯逻辑测试
- `LeapAutoTests/LocalVideoCodecTests.swift`：Apple 实际视频测试

集成负责人在“车辆连接与能力”增加独立本机诊断入口，并执行：

```sh
python3 ios/scripts/generate_project.py
python3 ios/scripts/validate_structure.py
```

不需要手工增加 framework 链接或 capability；现有生成器自动枚举 Swift 文件并使用 Swift 模块自动链接。没有变更 AppModel、车辆控制或认证路径。

## 验证入口

纯逻辑覆盖：配置边界、1000 次背压仍有界、旧/重复/乱序回调、停止重启和尺寸重置、延迟/字节统计、丢帧和失败只释放一次、超时不提前重用槽位、源帧数限制和排空、未完成不能冒称完成、非法时钟输入。

```sh
swift test --package-path ios/Packages/LeapCore --filter LocalVideoCodecStateTests
```

Apple tests 使用真实 VideoToolbox，不通过 mock 返回成功：

1. 合成源彩条与变化的计数、错误尺寸拒绝
2. 像素池达到阈值拒绝额外分配
3. 12 帧真实 H.264 编码→解码→像素验证，检查尺寸、字节、延迟及有界在途
4. 停止→720p 重启，旧回调不能污染第二轮 8 帧结果
5. 连续开始/立即停止，迟到回调不能恢复画面或运行状态
6. 仅一个在途槽位时仍完成真实编解码
7. 无效配置在提交帧前明确失败

```sh
xcodebuild -project ios/LeapAuto.xcodeproj -scheme LeapAuto \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_ID>' \
  CODE_SIGNING_ALLOWED=NO -only-testing:LeapAutoTests/LocalVideoCodecTests test
```

2026-10-16 已在 Mac 的 Xcode 26.6 / iOS 26.5 iPhone 17 Pro 模拟器完成定向及全量验证：LeapCore 245、App 55（含 7 个实际 VideoToolbox 用例）、UI 3，均无失败。真实 H.264 往返和解码像素检查、仅一个在途槽位、停止确认、720p 重启及旧回调隔离均已执行。完整入口为 `SIMULATOR_ID=<SIMULATOR_ID> ./ios/scripts/validate_macos.sh`。

模拟器结果不能证明 iPhone 的实际硬件使用、前后台/锁屏、内存及功耗，也没有验证 ReplayKit 采集或车机传输；这些仍须分别验证。

UI 人工验收：开始、重复开始、停止、运行中改尺寸、返回后重进、App 不活跃后恢复、自然完成、错误文字及大字体/深浅色。不要用一个 mock 视频截图声称真实链路成功。

## ReplayKit 后续接口与车机门槛

当前 `LocalVideoFrameSource` 只服务受控合成输入。后续应增加独立的 ReplayKit capture adapter：明确用户启动和停止、仅视频类型、音频不采集/不转发、采用有界 latest-frame 交接，处理方向/尺寸变化、权限拒绝/系统中断、敏感 UI 和系统内容保护。该适配器不能默认启动，也不能把收到 CMSampleBuffer 等同于允许传给第三方。

本机 iOS 26.5 SDK 已核查 ReplayKit 的 `startCapture` 可用；网页上的 deprecated 标记不能替代目标 SDK 的 availability。macOS ScreenCaptureKit 不能用于本 iOS target。此轮不增加 ReplayKit 调用或 broadcast extension。

真正向车机发送画面还须独立证据：支持车型与接收应用、协议发现/握手、账号/车辆绑定、传输与加密、帧格式和时序、网络切换、背压/重连、安全驾驶限制、用户知情同意。尚无这些证据，不构造猜测的车端命令。

官方参考：

- https://developer.apple.com/documentation/videotoolbox/encoding-video-for-live-streaming
- https://developer.apple.com/documentation/videotoolbox/vtcompressionsession-api-collection
- https://developer.apple.com/documentation/videotoolbox/vtdecompressionsession-api-collection
