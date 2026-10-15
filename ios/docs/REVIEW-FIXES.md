# iOS 审查修复与回归证据

日期：2026-10-15 UTC。修复基线：`81acfa8b6b6bee1b2e4405e59a0c3521fa4a6aa7`。

本轮仅修改 iOS 源码、离线测试及验证说明，Android、登录 SDK、BLE 安全门禁、真实网络和车辆操作均未改变。

## 修复内容

1. **数值标识符精度**：`JSONValue.scalarString` 拒绝绝对值达到或超过 2^53 的数值，避免将舍入后的账号或轮询 ID 发给服务端。边界 2^53 也拒绝，因为 2^53+1 会舍入到它。较大 ID 的 JSON 字符串保留原样；遥测仍可通过 `doubleValue` 读取。无安全轮询 ID 时仅报告受理，不宣称执行成功。
2. **真实截止时间**：接受控制指令后建立一个单调时钟的 24 秒预算，覆盖初始/轮询间隔、每次结果读取所需的凭据刷新，以及成功后的车况读取。截止或调用者取消时主动取消进行中的读取并释放等待界面；使用单次 continuation 完成机制，避免不及时响应取消的 transport 拖住调用者。迟到回复不能改变终态，控制 POST 从不自动重发。
3. **保留已确认结果**：结果接口确认完成后，车况刷新失败、超时、取消或认证过期都只产生独立错误提示，不再把指令改回“结果未知”。会话过期仍清理本地会话；原有代次检查防止旧结果覆盖新账号/演示状态。

真实 `URLSession` 读取支持任务取消。如果注入的 transport 完全忽略取消，API 的串行门禁会保留到该读取真正结束；这是避免并发车辆操作的失败关闭行为。UI 不继续等待，后续请求可能暂时得到“上一项请求尚未结束”，退出仍可使旧会话失效。

## 红绿回归

- 数值 ID：同一组 8 项测试在原实现下出现 3 个失败测试、34 个失败断言；修复后全部通过。正常/安全边界、JSON 字符串和遥测兼容用例同时保留。
- AppModel：先只加入依赖注入和等价时序参数，默认行为不变。19 项测试中 5 个回归测试产生 16 个失败断言，分别重现轮询挂起、凭据刷新挂起、已确认后的车况挂起、网络失败覆盖成功、认证注销覆盖成功。
- 完成修复并补充取消用例后，20 项实际 AppModel 源码测试全部通过，独立连续复跑三次一致。
- 新增 8 项核心截止机制测试覆盖零预算、预算短于首次延迟、持续 pending、pending 后成功、服务端失败、进行中取消、预先取消及超时取消。

## 最终聚合验证

运行：`./ios/scripts/validate.sh`，官方 Swift 6.4.1 Linux 工具链；完整输出见 [review-fixes-tests.log](validation/review-fixes-tests.log)。

- LeapCore：152 项，149 通过、3 个 Apple 专属密码测试跳过、0 失败
- 实际 AppModel 源码：20 项，20 通过、0 失败
- 工程源成员、App Group、权限与配置结构检查通过
- App/Widget/Shared/AppTests/UITests 的 Swift 语法解析通过
- 非敏感退出标记生产源码烟测通过
- Shell 语法及 `git diff --check` 通过

Linux 下新脚本 `scripts/test_app_model_portable.sh` 在隔离临时 SwiftPM 包中编译未经改写的 AppModel、DemoFixtures、SessionLifecycleStore 与同一 AppModelTests，链接真实 LeapCore。只有 Combine 类型表面和不可用的 Apple 系统适配器使用测试替身，默认认证/钥匙串操作失败关闭。系统适配器替身不会编入 App 或 Widget。

**这不证明 Apple SDK 类型检查、Combine 观察行为、Xcode 构建、模拟器、真机、钥匙串、生物认证、小组件、真实密码算法或实车行为通过。** 本轮未运行 Xcode，未发送真实 SMS/登录/车辆命令。仍需在具备 Xcode 的 Mac 运行 `./ios/scripts/validate_macos.sh`。
