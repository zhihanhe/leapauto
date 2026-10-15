import Combine
import Foundation
import LeapCore

enum AppMode: Equatable { case signedOut, demo, connected }

@MainActor
final class AppModel: ObservableObject {
    @Published var mode: AppMode = .signedOut
    @Published var vehicles: [Vehicle] = []
    @Published var selectedVehicle: Vehicle?
    @Published var status: VehicleStatus?
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published var operationMessage: String?
    @Published var pendingCommand: LeapCommand?
    @Published var isCommandRunning = false
    @Published var sessionDeletionFailed = false
    @Published var widgetMessage: String?
    @Published var connectionConfiguration: VehicleConnectionConfiguration?
    @Published var connectionConfigurationMessage: String?
    @Published var vehicleMetadataUpdatedAt: Date?

    private var api: LeapAPI?
    private let lifecycle: SessionLifecycleStore
    private let pollingPolicy: ControlPollingPolicy
    private let authenticate: @MainActor () async throws -> Void
    private let loadSession: () throws -> Session?
    private let saveSession: (Session) throws -> Void
    private let removeSession: () throws -> Void
    private var generation = UUID()
    private var didRestore = false
    private lazy var widgetPublisher: WidgetSnapshotPublisher? = Self.isOfflineTestRun ? nil : WidgetSnapshotPublisher()

    // Production defaults retain local authentication and device-only Keychain.
    // Tests inject only offline transports and isolated persistence.
    init(api: LeapAPI? = nil, pollingPolicy: ControlPollingPolicy = .app,
         authenticate: @escaping @MainActor () async throws -> Void = { try await LocalControlAuthentication().verify() },
         loadSession: @escaping () throws -> Session? = { try KeychainStore().load(Session.self, account: "session") },
         saveSession: @escaping (Session) throws -> Void = { try KeychainStore().save($0, account: "session") },
         removeSession: @escaping () throws -> Void = { try KeychainStore().remove(account: "session") },
         lifecycle: SessionLifecycleStore = SessionLifecycleStore()) {
        self.api = api
        self.pollingPolicy = pollingPolicy
        self.authenticate = authenticate
        self.loadSession = loadSession
        self.saveSession = saveSession
        self.removeSession = removeSession
        self.lifecycle = lifecycle
    }

    static var isOfflineTestRun: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["LEAPAUTO_OFFLINE_TESTS"] == "1"
            || env["XCTestConfigurationFilePath"] != nil
            || env["XCTestBundlePath"] != nil
            || ProcessInfo.processInfo.arguments.contains("--offline-tests")
    }

    var canControl: Bool {
        guard !isBusy, !isCommandRunning, selectedVehicle != nil else { return false }
        if mode == .demo { return true }
        guard mode == .connected else { return false }
        do { try LeapCommand.lock.validate(status: status); return true }
        catch { return false }
    }

    func canRequest(_ command: LeapCommand) -> Bool {
        guard canControl else { return false }
        if mode == .demo { return true }
        do {
            try command.validate(status: status)
            try SentryControlPolicy.validate(command: command, ownership: selectedVehicle?.ownership ?? .unknown)
            return true
        } catch { return false }
    }

    func restore() async {
        guard !Self.isOfflineTestRun, !didRestore, mode == .signedOut else { return }
        didRestore = true
        clearWidgetSnapshot()
        guard !lifecycle.logoutRequested else {
            sessionDeletionFailed = true
            errorMessage = "上次退出尚未完成本机会话清理，请点击“重试清除会话”。"
            return
        }
        do {
            guard let session = try loadSession(), session.isAuthenticated else { return }
            api = LeapAPI(session: session)
            beginWidgetSession(source: .vehicle)
            mode = .connected
            await bootstrap()
        } catch {
            sessionDeletionFailed = true
            errorMessage = "本机会话无法读取。请解锁设备后点击“重试清除会话”，再重新导入。"
        }
    }

    func enterDemo() {
        guard !isBusy, !isCommandRunning else { return }
        generation = UUID()
        connectionConfiguration = nil
        connectionConfigurationMessage = nil
        vehicleMetadataUpdatedAt = nil
        api = nil
        mode = .demo
        beginWidgetSession(source: .demo)
        vehicles = [DemoFixtures.vehicle]
        selectedVehicle = DemoFixtures.vehicle
        status = DemoFixtures.status()
        if let status { publishWidgetStatus(status) }
        errorMessage = nil
        operationMessage = nil
    }

    func importSession(from url: URL) async {
        guard !Self.isOfflineTestRun else {
            errorMessage = "自动化测试模式仅允许离线演示。"
            return
        }
        guard !isBusy, !isCommandRunning else { return }
        isBusy = true
        errorMessage = nil
        generation = UUID()
        let scope = generation
        connectionConfiguration = nil
        connectionConfigurationMessage = nil
        vehicleMetadataUpdatedAt = nil
        var importedClientCommitted = false
        beginWidgetSession(source: mode == .demo ? .demo : .vehicle)
        defer { if generation == scope { isBusy = false } }
        do {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 131_072 else { throw AppError.invalidImport }
            let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
            guard bytes.count <= 131_072, let raw = String(data: bytes, encoding: .utf8) else {
                throw AppError.invalidImport
            }
            let client = LeapAPI()
            try await client.importLegacyAuth(rawJSON: raw)
            let imported = await client.snapshot()
            guard generation == scope else { return }
            // Save successful credential rotation before any subsequent read can fail.
            try saveSession(imported)
            api = client
            importedClientCommitted = true
            beginWidgetSession(source: .vehicle)
            lifecycle.clearLogoutRequest()
            mode = .connected
            vehicles = []
            selectedVehicle = nil
            status = nil
            sessionDeletionFailed = false
            let list = try await client.bootstrap()
            let snapshot = await client.snapshot()
            guard generation == scope else { return }
            vehicles = list
            vehicleMetadataUpdatedAt = Date()
            selectedVehicle = list.first(where: { $0.vin == snapshot.selectedVIN }) ?? list.first
            if selectedVehicle != nil {
                let fresh = try await client.refreshStatus()
                guard generation == scope else { return }
                status = fresh
                publishWidgetStatus(fresh)
            }
            await updateConnectionDetails(client: client, scope: scope, reloadVehicleMetadata: false)
            await persistCurrentSession(scope: scope)
            guard generation == scope else { return }
            operationMessage = "会话已导入本机钥匙串。请先核对所选车辆与车况。"
        } catch {
            guard generation == scope else { return }
            if importedClientCommitted { await handleConnectedFailure(error, scope: scope) }
            else {
                errorMessage = safeMessage(error)
                if mode == .signedOut { clearWidgetSnapshot() }
                else if let status { publishWidgetStatus(status) }
            }
        }
    }

    private func bootstrap() async {
        guard let client = api, !isBusy else { return }
        isBusy = true
        let scope = generation
        defer { if generation == scope { isBusy = false } }
        do {
            let list = try await client.bootstrap()
            let snapshot = await client.snapshot()
            guard generation == scope else { return }
            vehicles = list
            vehicleMetadataUpdatedAt = Date()
            selectedVehicle = list.first(where: { $0.vin == snapshot.selectedVIN }) ?? list.first
            if selectedVehicle != nil {
                let fresh = try await client.refreshStatus()
                guard generation == scope else { return }
                status = fresh
                publishWidgetStatus(fresh)
            }
            await updateConnectionDetails(client: client, scope: scope, reloadVehicleMetadata: false)
            await persistCurrentSession(scope: scope)
            guard generation == scope else { return }
        } catch {
            guard generation == scope else { return }
            await handleConnectedFailure(error, scope: scope)
        }
    }

    func refresh() async {
        guard !isBusy, !isCommandRunning else { return }
        if mode == .demo {
            status = DemoFixtures.status()
            if let status { publishWidgetStatus(status) }
            operationMessage = "演示数据已刷新；没有网络请求。"
            return
        }
        guard let client = api else { return }
        if selectedVehicle == nil { await bootstrap(); return }
        let scope = generation
        isBusy = true
        errorMessage = nil
        defer { if generation == scope { isBusy = false } }
        do {
            let fresh = try await client.refreshStatus()
            guard generation == scope else { return }
            status = fresh
            publishWidgetStatus(fresh)
            await updateConnectionDetails(client: client, scope: scope, reloadVehicleMetadata: true)
            await persistCurrentSession(scope: scope)
            guard generation == scope else { return }
        } catch {
            guard generation == scope else { return }
            await handleConnectedFailure(error, scope: scope)
        }
    }

    func selectVehicle(_ vehicle: Vehicle) async {
        guard !isBusy, !isCommandRunning, pendingCommand == nil, mode == .connected, let client = api else { return }
        generation = UUID()
        connectionConfiguration = nil
        connectionConfigurationMessage = nil
        vehicleMetadataUpdatedAt = nil
        let scope = generation
        isBusy = true
        status = nil
        selectedVehicle = nil
        beginWidgetSession(source: .vehicle)
        operationMessage = nil
        defer { if generation == scope { isBusy = false } }
        do {
            try await client.selectVehicle(vehicle)
            guard generation == scope else { return }
            selectedVehicle = vehicle
            let fresh = try await client.refreshStatus()
            guard generation == scope else { return }
            status = fresh
            publishWidgetStatus(fresh)
            await updateConnectionDetails(client: client, scope: scope, reloadVehicleMetadata: true)
            await persistCurrentSession(scope: scope)
            guard generation == scope else { return }
        } catch {
            guard generation == scope else { return }
            await handleConnectedFailure(error, scope: scope)
        }
    }

    /// User-initiated metadata read; no pairing, certificate provisioning or BLE
    /// side effects. A failed optional read does not invalidate good telemetry.
    func inspectConnectionConfiguration() async {
        guard !isBusy, !isCommandRunning, pendingCommand == nil else { return }
        guard mode == .connected, selectedVehicle != nil, let client = api else {
            connectionConfigurationMessage = "请先导入本人会话并选择车辆；离线演示不会查询真实配置。"
            return
        }
        let scope = generation
        isBusy = true
        connectionConfiguration = nil
        connectionConfigurationMessage = nil
        defer { if generation == scope { isBusy = false } }
        await updateConnectionDetails(client: client, scope: scope, reloadVehicleMetadata: true)
        // A valid metadata refresh can remove the selected VIN after rotating
        // credentials. Persist that rotation while the same session is active.
        guard generation == scope else { return }
        await persistCurrentSession(scope: scope)
    }

    /// Best-effort metadata refresh after connection/selection/status refresh.
    /// Failures stay separate from valid telemetry and never start BLE hardware.
    private func updateConnectionDetails(client: LeapAPI, scope: UUID, reloadVehicleMetadata: Bool) async {
        guard generation == scope, mode == .connected, let vin = selectedVehicle?.vin else { return }
        connectionConfigurationMessage = nil
        do {
            if reloadVehicleMetadata {
                let vehicle = try await client.refreshSelectedVehicleMetadata()
                guard generation == scope, selectedVehicle?.vin == vin else { return }
                selectedVehicle = vehicle
                if let index = vehicles.firstIndex(where: { $0.vin == vin }) { vehicles[index] = vehicle }
                vehicleMetadataUpdatedAt = Date()
            }
            let configuration = try await client.connectionConfiguration()
            guard generation == scope, selectedVehicle?.vin == vin else { return }
            connectionConfiguration = configuration
        } catch {
            guard generation == scope, selectedVehicle?.vin == vin else { return }
            connectionConfiguration = nil
            if let failure = error as? LeapAPIError,
               failure == .authenticationRequired || failure == .invalidSession {
                await handleConnectedFailure(error, scope: scope)
            } else {
                if error as? LeapAPIError == .unknownVehicle {
                    selectedVehicle = nil
                    status = nil
                    vehicleMetadataUpdatedAt = nil
                    clearWidgetSnapshot()
                }
                connectionConfigurationMessage = safeMessage(error)
            }
        }
    }

    func request(_ command: LeapCommand) {
        guard !isCommandRunning, !isBusy, pendingCommand == nil else { return }
        errorMessage = nil
        do {
            guard selectedVehicle != nil else { throw AppError.noVehicle }
            if mode != .demo {
                try command.validate(status: status)
                try SentryControlPolicy.validate(command: command, ownership: selectedVehicle?.ownership ?? .unknown)
            }
            pendingCommand = command
        } catch { errorMessage = safeMessage(error) }
    }

    func cancelPendingCommand() {
        guard !isCommandRunning else { return }
        pendingCommand = nil
    }

    func executePendingCommand(pin: String) async {
        guard let command = pendingCommand, !isCommandRunning, !isBusy else { return }
        guard pin.utf8.count == 4, pin.utf8.allSatisfy({ (48...57).contains($0) }) else {
            errorMessage = "操作密码必须为四位数字。"
            return
        }
        isCommandRunning = true
        let scope = generation
        let vin = selectedVehicle?.vin
        var submitted = false
        defer {
            if generation == scope {
                isCommandRunning = false
                pendingCommand = nil
            }
        }
        if mode == .demo {
            operationMessage = "演示：已模拟“\(command.title)”流程。没有发送指令，样例车况保持不变。"
            return
        }
        do {
            guard let client = api else { throw AppError.noVehicle }
            try await authenticate()
            guard generation == scope, selectedVehicle?.vin == vin else { return }
            let fresh = try await client.refreshStatus()
            guard generation == scope, selectedVehicle?.vin == vin else { return }
            status = fresh
            publishWidgetStatus(fresh)
            try command.validate(status: fresh)
            try SentryControlPolicy.validate(command: command, ownership: selectedVehicle?.ownership ?? .unknown)
            // Once this call starts, a network error does not prove that the
            // vehicle did not receive the instruction. Never automatically resend.
            try Task.checkCancellation()
            submitted = true
            let receipt = try await client.send(command: command, pin: pin)
            let deadline = ControlObservationDeadline(timeout: pollingPolicy.timeout)
            guard generation == scope else { return }
            await persistCurrentSession(scope: scope)
            guard generation == scope else { return }
            guard let messageID = receipt.messageID, !messageID.isEmpty else {
                operationMessage = "服务端已受理，尚未确认车辆执行。请刷新车况，勿重复操作。"
                return
            }
            operationMessage = "服务端已受理，正在确认车辆执行结果…"
            try await pollResult(client: client, messageID: messageID, command: command,
                                 sentryBaselineTimestamp: fresh.sourceTimestamp, scope: scope, deadline: deadline)
            await persistCurrentSession(scope: scope)
        } catch {
            guard generation == scope else { return }
            if error is SentryControlError {
                // Ownership is checked before the command POST. A policy denial
                // is not an ambiguous vehicle execution outcome.
                submitted = false
                operationMessage = nil
                selectedVehicle?.ownership = .unknown
            }
            if submitted {
                operationMessage = "执行结果尚未确认。请刷新车况核对，勿重复操作。"
            }
            await handleConnectedFailure(error, scope: scope, submitted: submitted)
        }
    }

    private func pollResult(client: LeapAPI, messageID: String, command: LeapCommand,
                            sentryBaselineTimestamp: Date?, scope: UUID,
                            deadline: ControlObservationDeadline) async throws {
        // The same deadline bounds every awaited read, including credential
        // refresh and the final telemetry query. No command POST is replayed.
        let outcome = try await ControlResultObserver.observe(policy: pollingPolicy, deadline: deadline) {
            try await client.pollResult(messageID: messageID)
        }
        guard generation == scope else { return }
        switch outcome {
        case .verified:
            operationMessage = command.sentryTarget == nil
                ? "车辆接口已确认指令完成。正在刷新车况…"
                : "接口已返回结果，正在核对哨兵状态…"
            do {
                let fresh = try await deadline.run { try await client.refreshStatus() }
                guard generation == scope else { return }
                status = fresh
                publishWidgetStatus(fresh)
                let hasNewSentryObservation: Bool
                if let baseline = sentryBaselineTimestamp, let observed = fresh.sourceTimestamp {
                    hasNewSentryObservation = observed > baseline
                } else { hasNewSentryObservation = false }
                if let target = command.sentryTarget,
                   !hasNewSentryObservation || !fresh.isFreshForControl()
                    || !SentryControlPolicy.isConfirmed(targetEnabled: target, telemetryEnabled: fresh.sentryMode) {
                    operationMessage = "接口返回完成，但哨兵状态未确认达到目标。请稍后刷新核对，勿重复操作。"
                } else {
                    operationMessage = "车辆接口已确认指令完成，车况已刷新。"
                }
            } catch {
                guard generation == scope else { return }
                // Execution confirmation is terminal. A separate telemetry or
                // authentication failure cannot turn it back into uncertainty.
                let confirmed = command.sentryTarget == nil
                    ? "车辆接口已确认指令完成。车况刷新未完成，请稍后核对。"
                    : "接口返回完成，但哨兵车况刷新未完成，状态仍待核对。请勿重复操作。"
                operationMessage = confirmed
                await handleConnectedFailure(error, scope: scope, confirmedCommandMessage: confirmed)
            }
        case .failed(let message):
            operationMessage = message
        case .timedOut:
            operationMessage = "等待结果超时，执行状态未知。请刷新车况核对，勿重复操作。"
        case .accepted:
            // Observer currently returns only terminal outcomes. Fail closed if
            // a future implementation returns acceptance without confirmation.
            operationMessage = "服务端已受理，尚未确认车辆执行。请刷新车况，勿重复操作。"
        }
    }

    @discardableResult
    func logout(preservingOperationMessage: String? = nil) async -> UUID {
        // Invalidate late responses before crossing an actor boundary.
        lifecycle.markLogoutRequested()
        generation = UUID()
        let logoutScope = generation
        clearWidgetSnapshot()
        let old = api
        api = nil
        mode = .signedOut
        vehicles = []
        selectedVehicle = nil
        status = nil
        connectionConfiguration = nil
        connectionConfigurationMessage = nil
        vehicleMetadataUpdatedAt = nil
        pendingCommand = nil
        isCommandRunning = false
        isBusy = false
        operationMessage = preservingOperationMessage
        errorMessage = nil
        do {
            try removeSession()
            lifecycle.clearLogoutRequest()
            sessionDeletionFailed = false
        } catch {
            sessionDeletionFailed = true
            errorMessage = "本机会话未能从钥匙串删除。请解锁设备后点击“重试清除会话”。"
        }
        await old?.logout()
        return logoutScope
    }

    private func handleConnectedFailure(_ error: Error, scope: UUID, submitted: Bool = false,
                                        confirmedCommandMessage: String? = nil) async {
        guard generation == scope else { return }
        if let apiError = error as? LeapAPIError,
           apiError == .authenticationRequired || apiError == .invalidSession {
            let logoutScope = await logout(preservingOperationMessage: confirmedCommandMessage)
            guard generation == logoutScope else { return }
            errorMessage = sessionDeletionFailed
                ? "会话已失效，本机清理未完成。请解锁后点击“重试清除会话”。"
                : "会话已失效，已退出。请重新导入本人有效会话。"
            if let confirmedCommandMessage { operationMessage = confirmedCommandMessage }
            else if submitted { operationMessage = "已提交指令的执行状态仍未知，请通过车辆实际状态核对，勿重复操作。" }
            return
        }
        errorMessage = safeMessage(error)
        if !Self.isOfflineTestRun {
            do { try widgetPublisher?.markRefreshFailed(generation: scope) }
            catch { widgetMessage = "小组件快照不可更新，请检查 App Group 配置或解锁设备。" }
        }
        await persistCurrentSession(scope: scope)
    }

    private func persistCurrentSession(scope: UUID) async {
        guard generation == scope, mode == .connected, let client = api else { return }
        let snapshot = await client.snapshot()
        guard generation == scope else { return }
        do { try saveSession(snapshot) }
        catch { errorMessage = "会话更新未能保存到本机钥匙串，请解锁设备后重试。" }
    }

    func refreshWidgetSnapshot() {
        guard !Self.isOfflineTestRun else { return }
        if mode == .signedOut { clearWidgetSnapshot(); return }
        beginWidgetSession(source: mode == .demo ? .demo : .vehicle)
        if let status { publishWidgetStatus(status) }
    }

    private func beginWidgetSession(source: WidgetSnapshot.Source) {
        guard !Self.isOfflineTestRun else { return }
        do {
            try widgetPublisher?.beginSession(generation: generation, source: source)
            widgetMessage = nil
        } catch { widgetMessage = "小组件共享未配置或暂不可写，请检查 App Group 配置。" }
    }

    private func publishWidgetStatus(_ fresh: VehicleStatus) {
        guard !Self.isOfflineTestRun else { return }
        do {
            try widgetPublisher?.publish(status: fresh, generation: generation)
            widgetMessage = nil
        } catch { widgetMessage = "小组件快照不可更新，请检查 App Group 配置或解锁设备。" }
    }

    private func clearWidgetSnapshot() {
        guard !Self.isOfflineTestRun else { return }
        do {
            try widgetPublisher?.clear()
            widgetMessage = nil
        } catch {
            widgetMessage = "小组件缓存清理未完成，请解锁后重试；系统缓存可能暂时保留旧卡片。"
        }
    }

    private func safeMessage(_ error: Error) -> String {
        if error is CancellationError { return "操作已取消。已发送指令的执行状态请刷新车况核对。" }
        // All domain errors have controlled, non-sensitive descriptions. Never
        // surface URLs, raw responses, or arbitrary NSError.userInfo.
        switch error {
        case let value as LeapAPIError: return value.errorDescription ?? "接口请求失败。"
        case let value as SessionImportError: return value.errorDescription ?? "会话文件无效。"
        case let value as ProtocolCryptoError: return value.errorDescription ?? "协议加密失败。"
        case let value as ControlObservationError: return value.errorDescription ?? "车况刷新超时。"
        case let value as SentryControlError: return value.errorDescription ?? "当前账号不能执行该操作。"
        case let value as CommandValidationError: return value.errorDescription ?? "当前不能控制车辆。"
        case let value as KeychainStore.StoreError: return value.errorDescription ?? "钥匙串不可用。"
        case let value as LocalControlAuthentication.AuthenticationError: return value.errorDescription ?? "身份验证未通过。"
        case let value as AppError: return value.errorDescription ?? "操作失败。"
        default: break
        }
        return "操作失败，请检查网络或稍后重试。"
    }

    enum AppError: LocalizedError {
        case invalidImport, noVehicle
        var errorDescription: String? {
            switch self {
            case .invalidImport: return "请选择不超过 128 KB 的有效 JSON 会话文件。"
            case .noVehicle: return "请先连接并选择自己的车辆。"
            }
        }
    }
}
