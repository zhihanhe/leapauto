import XCTest
@testable import LeapAuto
import LeapCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor
final class AppModelTests: XCTestCase {
    func testDemoNeverNeedsCredentialsAndDoesNotChangeVehicleState() async {
        let model = AppModel()
        model.enterDemo()
        XCTAssertEqual(model.mode, .demo)
        XCTAssertTrue(model.canControl)
        let locked = model.status?.locked
        model.request(.unlock)
        XCTAssertNotNil(model.pendingCommand)
        await model.executePendingCommand(pin: "0000")
        XCTAssertNil(model.pendingCommand)
        XCTAssertFalse(model.isCommandRunning)
        XCTAssertEqual(model.status?.locked, locked)
        XCTAssertTrue(model.operationMessage?.contains("没有发送指令") == true)
    }

    func testInvalidPINNeverSubmitsAndLeavesConfirmationOpen() async {
        let model = AppModel()
        model.enterDemo()
        model.request(.lock)
        await model.executePendingCommand(pin: "１２３４")
        XCTAssertNotNil(model.pendingCommand)
        XCTAssertFalse(model.isCommandRunning)
        XCTAssertNotNil(model.errorMessage)
        model.cancelPendingCommand()
        XCTAssertNil(model.pendingCommand)
    }

    func testRepeatedRequestsCannotReplacePendingTarget() {
        let model = AppModel()
        model.enterDemo()
        model.request(.lock)
        model.request(.unlock)
        XCTAssertEqual(model.pendingCommand?.title, LeapCommand.lock.title)
    }

    func testAutomationCannotRestoreOrImportRealSessions() async {
        XCTAssertTrue(AppModel.isOfflineTestRun, "The test scheme must force offline mode")
        let model = AppModel()
        await model.restore()
        XCTAssertEqual(model.mode, .signedOut)
        await model.importSession(from: URL(fileURLWithPath: "/nonexistent/never-read.json"))
        XCTAssertEqual(model.mode, .signedOut)
        XCTAssertEqual(model.errorMessage, "自动化测试模式仅允许离线演示。")
    }

    func testLogoutTombstonePersistsUntilSuccessfulCleanup() {
        let suite = "LeapAutoTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = SessionLifecycleStore(defaults: defaults)
        XCTAssertFalse(first.logoutRequested)
        first.markLogoutRequested()
        let restored = SessionLifecycleStore(defaults: defaults)
        XCTAssertTrue(restored.logoutRequested)
        restored.clearLogoutRequest()
        XCTAssertFalse(first.logoutRequested)
    }

    func testSignedOutBlocksControl() {
        let model = AppModel()
        XCTAssertFalse(model.canControl)
        model.request(.unlock)
        XCTAssertNil(model.pendingCommand)
        XCTAssertNotNil(model.errorMessage)
    }

    func testOfflineWidgetSynchronizationStaysInert() {
        XCTAssertTrue(AppModel.isOfflineTestRun)
        let model = AppModel()
        model.refreshWidgetSnapshot()
        XCTAssertNil(model.widgetMessage)
        model.enterDemo()
        model.refreshWidgetSnapshot()
        XCTAssertNil(model.widgetMessage)
        XCTAssertEqual(model.mode, .demo)
    }

    func testConfirmedCommandRefreshesStatusWithoutResending() async {
        let fixture = ConnectedModelFixture()
        let transport = ModelFixtureTransport([
            .status(fixture.parked), .accepted, .poll("{\"result\":0}"), .status(fixture.parked)
        ])
        let model = fixture.model(transport)
        model.request(.lock)
        await model.executePendingCommand(pin: "0000")
        assertConfirmed(model)
        XCTAssertTrue(model.operationMessage?.contains("车况已刷新") == true)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isCommandRunning)
        XCTAssertNil(model.pendingCommand)
        await assertSingleCommand(transport, expectedPolls: 1, expectedStatusReads: 2)
    }

    func testPendingPollThenSuccessPreservesSingleSubmission() async {
        let fixture = ConnectedModelFixture()
        let transport = ModelFixtureTransport([
            .status(fixture.parked), .accepted, .poll("{\"result\":7}"),
            .poll("{\"result\":0}"), .status(fixture.parked)
        ])
        let model = fixture.model(transport)
        model.request(.lock)
        await model.executePendingCommand(pin: "0000")
        assertConfirmed(model)
        XCTAssertNil(model.errorMessage)
        await assertSingleCommand(transport, expectedPolls: 2, expectedStatusReads: 2)
    }

    func testConfirmedSuccessSurvivesFailedTelemetryRefresh() async {
        let fixture = ConnectedModelFixture()
        let transport = ModelFixtureTransport([
            .status(fixture.parked), .accepted, .poll("{\"result\":0}"),
            .init(path: ModelFixtureTransport.statusPath, reply: .error(.networkUnavailable))
        ])
        let model = fixture.model(transport)
        model.request(.lock)
        await model.executePendingCommand(pin: "0000")
        assertConfirmed(model)
        XCTAssertEqual(model.mode, .connected)
        XCTAssertNotNil(model.errorMessage, "Telemetry failure is reported separately from confirmed execution")
        XCTAssertFalse(model.errorMessage?.isEmpty ?? true)
        XCTAssertNotNil(model.status, "Keep the last known telemetry when refresh fails")
        await assertSingleCommand(transport, expectedPolls: 1, expectedStatusReads: 2)
    }

    func testConfirmedSuccessSurvivesAuthenticationLogoutDuringRefresh() async {
        let fixture = ConnectedModelFixture()
        let transport = ModelFixtureTransport([
            .status(fixture.parked), .accepted, .poll("{\"result\":0}"),
            .init(path: ModelFixtureTransport.statusPath, reply: .error(.authenticationRequired)),
            .init(path: ModelFixtureTransport.refreshPath, reply: .error(.authenticationRequired)),
            .init(path: "/app-user/appuseroperate/getnewtoken", reply: .error(.authenticationRequired))
        ])
        let model = fixture.model(transport)
        model.request(.lock)
        await model.executePendingCommand(pin: "0000")
        XCTAssertEqual(model.mode, .signedOut)
        XCTAssertNil(model.status)
        XCTAssertNil(model.selectedVehicle)
        XCTAssertFalse(model.isCommandRunning)
        XCTAssertEqual(fixture.removalCount, 1)
        XCTAssertTrue(model.errorMessage?.contains("会话已失效") == true)
        assertConfirmed(model)
        await assertSingleCommand(transport, expectedPolls: 1, expectedStatusReads: 2)
    }

    func testSlowNonCooperativePollCannotOutliveDeadlineOrOverwriteTimeout() async {
        let fixture = ConnectedModelFixture()
        let transport = ModelFixtureTransport([
            .status(fixture.parked), .accepted,
            .init(path: ModelFixtureTransport.pollPath, reply: .suspended)
        ])
        let model = fixture.model(transport, policy: .init(timeout: 0.04, initialDelay: 0.005, interval: 0.005))
        model.request(.lock)
        let operation = Task { await model.executePendingCommand(pin: "0000") }
        let suspended = await waitUntilSuspended(transport)
        XCTAssertTrue(suspended)
        // The transport deliberately ignores cancellation. The model must stop
        // waiting independently; releasing below keeps even the RED run finite.
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(model.isCommandRunning, "An in-flight poll must not extend the polling deadline")
        XCTAssertTrue(model.operationMessage?.contains("超时") == true)
        let timedOutMessage = model.operationMessage
        await transport.release("{\"result\":0}")
        await operation.value
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(model.operationMessage, timedOutMessage, "Late replies must not replace the timeout result")
        XCTAssertFalse(model.operationMessage?.contains("已确认指令完成") == true)
        await assertSingleCommand(transport, expectedPolls: 1, expectedStatusReads: 1)
    }

    func testCredentialRefreshWithinPollAlsoObeysDeadline() async throws {
        let fixture = ConnectedModelFixture()
        let clock = fixture.clock
        let transport = ModelFixtureTransport([
            .status(fixture.parked), .accepted,
            .init(path: ModelFixtureTransport.refreshPath, reply: .suspended)
        ], onAcceptance: { clock.advance(70) })
        let model = fixture.model(transport, policy: .init(timeout: 0.04, initialDelay: 0.005, interval: 0.005),
                                  gatewayExpiry: fixture.clock.read().addingTimeInterval(360))
        model.request(.lock)
        let operation = Task { await model.executePendingCommand(pin: "0000") }
        let suspended = await waitUntilSuspended(transport)
        XCTAssertTrue(suspended, "Advancing only the API clock after acceptance must trigger pre-poll credential refresh")
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(model.isCommandRunning, "Credential refresh must be included in the result-observation deadline")
        XCTAssertTrue(model.operationMessage?.contains("超时") == true)
        let timedOutMessage = model.operationMessage
        await transport.release(try fixture.gatewayReply())
        await operation.value
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(model.operationMessage, timedOutMessage)
        await assertSingleCommand(transport, expectedPolls: 0, expectedStatusReads: 1)
    }

    func testConfirmedSuccessWithSlowTelemetryRefreshPreservesResultAtDeadline() async {
        let fixture = ConnectedModelFixture()
        let transport = ModelFixtureTransport([
            .status(fixture.parked), .accepted, .poll("{\"result\":0}"),
            .init(path: ModelFixtureTransport.statusPath, reply: .suspended)
        ])
        let model = fixture.model(transport, policy: .init(timeout: 0.04, initialDelay: 0.005, interval: 0.005))
        model.request(.lock)
        let operation = Task { await model.executePendingCommand(pin: "0000") }
        let suspended = await waitUntilSuspended(transport)
        XCTAssertTrue(suspended)
        let knownStatus = model.status
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(model.isCommandRunning, "Post-confirmation telemetry also shares the observation deadline")
        assertConfirmed(model)
        XCTAssertNotNil(model.errorMessage, "Report the telemetry timeout independently")
        let confirmedMessage = model.operationMessage
        let refreshError = model.errorMessage
        let lateStatus = "{\"code\":0,\"data\":{\"signalMap\":{\"gearStatus\":\"P\",\"speed\":0,\"soc\":12}}}"
        await transport.release(lateStatus)
        await operation.value
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(model.operationMessage, confirmedMessage)
        XCTAssertEqual(model.errorMessage, refreshError)
        XCTAssertEqual(model.status, knownStatus, "Late telemetry must not mutate the timed-out operation")
        await assertSingleCommand(transport, expectedPolls: 1, expectedStatusReads: 2)
    }

    func testCancelledPollDoesNotAcceptLateSuccess() async {
        let fixture = ConnectedModelFixture()
        let transport = ModelFixtureTransport([
            .status(fixture.parked), .accepted,
            .init(path: ModelFixtureTransport.pollPath, reply: .suspended)
        ])
        let model = fixture.model(transport)
        model.request(.lock)
        let operation = Task { await model.executePendingCommand(pin: "0000") }
        let suspended = await waitUntilSuspended(transport)
        XCTAssertTrue(suspended)
        operation.cancel()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(model.isCommandRunning, "Cancellation must release the UI without waiting for a non-cooperative reply")
        await transport.release("{\"result\":0}")
        await operation.value
        XCTAssertFalse(model.isCommandRunning)
        XCTAssertFalse(model.operationMessage?.contains("已确认") == true)
        XCTAssertNotNil(model.errorMessage)
        await assertSingleCommand(transport, expectedPolls: 1, expectedStatusReads: 1)
    }

    func testCancelledTelemetryRefreshPreservesAlreadyConfirmedSuccess() async {
        let fixture = ConnectedModelFixture()
        let transport = ModelFixtureTransport([
            .status(fixture.parked), .accepted, .poll("{\"result\":0}"),
            .init(path: ModelFixtureTransport.statusPath, reply: .suspended)
        ])
        let model = fixture.model(transport)
        model.request(.lock)
        let operation = Task { await model.executePendingCommand(pin: "0000") }
        let suspended = await waitUntilSuspended(transport)
        XCTAssertTrue(suspended)
        let knownStatus = model.status
        operation.cancel()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(model.isCommandRunning, "Cancellation must finish independently of the suspended telemetry reply")
        assertConfirmed(model)
        XCTAssertNotNil(model.errorMessage)
        let confirmedMessage = model.operationMessage
        let refreshError = model.errorMessage
        await transport.release("{\"code\":0,\"data\":{\"signalMap\":{\"soc\":12}}}")
        await operation.value
        try? await Task.sleep(nanoseconds: 20_000_000)
        assertConfirmed(model)
        XCTAssertEqual(model.operationMessage, confirmedMessage)
        XCTAssertEqual(model.errorMessage, refreshError)
        XCTAssertEqual(model.status, knownStatus)
        await assertSingleCommand(transport, expectedPolls: 1, expectedStatusReads: 2)
    }

    func testLogoutAndNewGenerationRejectLatePollReply() async {
        let fixture = ConnectedModelFixture()
        let transport = ModelFixtureTransport([
            .status(fixture.parked), .accepted,
            .init(path: ModelFixtureTransport.pollPath, reply: .suspended)
        ])
        let model = fixture.model(transport)
        model.request(.lock)
        let operation = Task { await model.executePendingCommand(pin: "0000") }
        let suspended = await waitUntilSuspended(transport)
        XCTAssertTrue(suspended)
        await model.logout()
        model.enterDemo()
        let demoStatus = model.status
        model.operationMessage = "New generation is active"
        model.errorMessage = "New generation error"
        await transport.release("{\"result\":0}")
        await operation.value
        XCTAssertEqual(model.mode, .demo)
        XCTAssertEqual(model.selectedVehicle, DemoFixtures.vehicle)
        XCTAssertEqual(model.status, demoStatus)
        XCTAssertEqual(model.operationMessage, "New generation is active")
        XCTAssertEqual(model.errorMessage, "New generation error")
        XCTAssertFalse(model.isCommandRunning)
        await assertSingleCommand(transport, expectedPolls: 1, expectedStatusReads: 1)
    }

    func testAcceptanceWithoutMessageIDRemainsUnconfirmed() async {
        let fixture = ConnectedModelFixture()
        let transport = ModelFixtureTransport([
            .status(fixture.parked), .init(path: ModelFixtureTransport.commandPath, reply: .json("{\"code\":0}", 200))
        ])
        let model = fixture.model(transport)
        model.request(.lock)
        await model.executePendingCommand(pin: "0000")
        XCTAssertTrue(model.operationMessage?.contains("尚未确认") == true)
        XCTAssertNil(model.errorMessage)
        await assertSingleCommand(transport, expectedPolls: 0, expectedStatusReads: 1)
    }

    func testSubmissionNetworkFailureNeverRetriesCommand() async {
        let fixture = ConnectedModelFixture()
        let transport = ModelFixtureTransport([
            .status(fixture.parked), .init(path: ModelFixtureTransport.commandPath, reply: .error(.networkUnavailable))
        ])
        let model = fixture.model(transport)
        model.request(.lock)
        await model.executePendingCommand(pin: "0000")
        XCTAssertTrue(model.operationMessage?.contains("尚未确认") == true)
        XCTAssertNotNil(model.errorMessage)
        await assertSingleCommand(transport, expectedPolls: 0, expectedStatusReads: 1)
    }

    func testLocalAuthenticationFailureDoesNotSendAnyRequest() async {
        let fixture = ConnectedModelFixture()
        let transport = ModelFixtureTransport([])
        let model = fixture.model(transport, authenticate: { throw CancellationError() })
        model.request(.lock)
        await model.executePendingCommand(pin: "0000")
        XCTAssertFalse(model.isCommandRunning)
        XCTAssertNotNil(model.errorMessage)
        let requests = await transport.paths()
        XCTAssertTrue(requests.isEmpty)
    }

    private func assertConfirmed(_ model: AppModel, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(model.operationMessage?.contains("已确认") == true, file: file, line: line)
        XCTAssertFalse(model.operationMessage?.contains("未知") == true, file: file, line: line)
        XCTAssertFalse(model.operationMessage?.contains("尚未确认") == true, file: file, line: line)
    }

    private func assertSingleCommand(_ transport: ModelFixtureTransport, expectedPolls: Int, expectedStatusReads: Int,
                                     file: StaticString = #filePath, line: UInt = #line) async {
        let paths = await transport.paths()
        XCTAssertEqual(paths.filter { $0 == ModelFixtureTransport.commandPath }.count, 1, file: file, line: line)
        XCTAssertEqual(paths.filter { $0 == ModelFixtureTransport.pollPath }.count, expectedPolls, file: file, line: line)
        XCTAssertEqual(paths.filter { $0 == ModelFixtureTransport.statusPath }.count, expectedStatusReads, file: file, line: line)
        let unused = await transport.unusedCount()
        XCTAssertEqual(unused, 0, "All expected fixture responses must be consumed", file: file, line: line)
    }

    private func waitUntilSuspended(_ transport: ModelFixtureTransport) async -> Bool {
        for _ in 0..<1000 {
            if await transport.isSuspended() { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return false
    }
}

// Synthetic, offline-only dependencies. These cannot open sockets or perform
// cryptography, local authentication, Keychain access, or widget publication.
private struct ModelFixtureCryptography: ProtocolCryptography {
    func md5Short(_ value: String) throws -> String { "fixture-md5" }
    func sha256Hex(_ value: String) throws -> String { "fixture-sha256" }
    func hmacSHA256Hex(key: Data, value: String) throws -> String { "fixture-hmac" }
    func encryptOperationPIN(_ pin: String, token: String) throws -> String { "fixture-ciphertext" }
    func rsaEncryptPhone(_ phone: String) throws -> String { "fixture-phone-ciphertext" }
}

private final class ModelFixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = Date()
    func read() -> Date { lock.lock(); defer { lock.unlock() }; return instant }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; instant.addTimeInterval(seconds) }
}

@MainActor
private final class ConnectedModelFixture {
    let clock = ModelFixtureClock()
    private let suite = "LeapAutoConnectedTests." + UUID().uuidString
    private let defaults: UserDefaults
    var removalCount = 0

    init() { defaults = UserDefaults(suiteName: suite)! }
    deinit { defaults.removePersistentDomain(forName: suite) }

    var parked: String {
        // Whole-second telemetry avoids floating-point JSON round-trips making
        // its timestamp a fraction of a millisecond newer than the fixed clock.
        "{\"code\":0,\"data\":{\"signalMap\":{\"gearStatus\":\"P\",\"speed\":0,\"sts\":\(floor(clock.read().timeIntervalSince1970) * 1000),\"soc\":70}}}"
    }

    func model(_ transport: ModelFixtureTransport,
               policy: ControlPollingPolicy = .init(timeout: 1, initialDelay: 0.005, interval: 0.005),
               gatewayExpiry: Date? = nil,
               authenticate: @escaping @MainActor () async throws -> Void = {}) -> AppModel {
        let clock = self.clock
        let session = Session(deviceID: String(repeating: "d", count: 32), phone: "13000000000", clientPlatform: .android,
            oldAuth: LegacyAuth(accountID: "fixture-account", token: String(repeating: "o", count: 32),
                                refreshToken: String(repeating: "l", count: 32)),
            newAuth: GatewayAuth(accountID: "fixture-account", accessToken: String(repeating: "g", count: 80),
                refreshToken: String(repeating: "r", count: 32), signKey: Data([1, 2, 3]), expiresAt: gatewayExpiry),
            selectedVIN: "FIXTUREVIN0000001", selectedCarType: "C16", route: RouteData(appRegion: TrustedEndpoints.global))
        let api = LeapAPI(session: session, transport: transport, crypto: ModelFixtureCryptography(), now: { clock.read() })
        let model = AppModel(api: api, pollingPolicy: policy, authenticate: authenticate,
            loadSession: { XCTFail("Connected command fixtures must not load a session"); return nil },
            saveSession: { _ in }, removeSession: { self.removalCount += 1 },
            lifecycle: SessionLifecycleStore(defaults: defaults))
        model.mode = .connected
        model.vehicles = [Vehicle(vin: session.selectedVIN, modelName: "Fixture C16", plateNumber: nil)]
        model.selectedVehicle = model.vehicles[0]
        model.status = DemoFixtures.status(now: clock.read())
        return model
    }

    func gatewayReply() throws -> String {
        func url64(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        }
        let payload = try JSONValue.object(["exp": .number(clock.read().addingTimeInterval(3600).timeIntervalSince1970)]).encodedData()
        let token = "fixture." + url64(payload) + "." + url64(Data([3, 4, 5, 6]))
        let value: JSONValue = .object(["code": .number(0), "data": .object([
            "accessToken": .string(token), "refreshToken": .string(String(repeating: "n", count: 32)),
            "signParam": .object(["r2": .string(Data([1, 2, 3, 4]).base64EncodedString()),
                                  "r3": .string(Data([5, 6, 7, 8]).base64EncodedString())])
        ])])
        return String(decoding: try value.encodedData(), as: UTF8.self)
    }
}

private actor ModelFixtureTransport: HTTPTransport {
    static let commandPath = "/app/app-control-service/v3/api/appremotectl"
    static let pollPath = commandPath + "/query"
    static let statusPath = "/app/app-signal-service/signal/info/query"
    static let refreshPath = "/base/base-user/token/v1/refresh"

    enum Reply: Sendable { case json(String, Int), error(LeapAPIError), suspended }
    struct Step: Sendable {
        let path: String
        let reply: Reply
        static func status(_ text: String) -> Self { .init(path: statusPath, reply: .json(text, 200)) }
        static var accepted: Self { .init(path: commandPath, reply: .json("{\"code\":0,\"data\":{\"msgID\":\"fixture-command\"}}", 200)) }
        static func poll(_ text: String) -> Self { .init(path: pollPath, reply: .json(text, 200)) }
    }
    private var steps: [Step]
    private var requests: [URLRequest] = []
    private var continuation: CheckedContinuation<HTTPResult, Error>?
    private var suspendedURL: URL?
    private let onAcceptance: @Sendable () -> Void

    init(_ steps: [Step], onAcceptance: @escaping @Sendable () -> Void = {}) {
        self.steps = steps
        self.onAcceptance = onAcceptance
    }

    func execute(_ request: URLRequest) async throws -> HTTPResult {
        requests.append(request)
        guard !steps.isEmpty else {
            XCTFail("Unexpected additional offline request: \(request.url?.path ?? "nil")")
            throw LeapAPIError.invalidResponse
        }
        let step = steps.removeFirst()
        XCTAssertEqual(request.url?.path, step.path)
        if step.path == Self.commandPath {
            XCTAssertEqual(request.httpMethod, "POST")
            onAcceptance()
        }
        switch step.reply {
        case .json(let body, let status): return HTTPResult(statusCode: status, body: Data(body.utf8), responseURL: request.url)
        case .error(let error): throw error
        case .suspended:
            suspendedURL = request.url
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
    }

    func release(_ body: String) {
        continuation?.resume(returning: HTTPResult(statusCode: 200, body: Data(body.utf8), responseURL: suspendedURL))
        continuation = nil
        suspendedURL = nil
    }
    func isSuspended() -> Bool { continuation != nil }
    func paths() -> [String] { requests.compactMap { $0.url?.path } }
    func unusedCount() -> Int { steps.count }
}
