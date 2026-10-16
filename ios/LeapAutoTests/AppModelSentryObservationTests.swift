import XCTest
@testable import LeapAuto
import LeapCore

@MainActor
final class AppModelSentryObservationTests: XCTestCase {
    private let short = ControlPollingPolicy(timeout: 0.08, initialDelay: 0.005, interval: 1)

    func testSentryWaitsForLaterTargetAndNewTimestampWithoutResubmission() async throws {
        let fixture = ConnectedModelFixture()
        let baseline = sentryStatus(fixture, enabled: false, age: 20)
        let transport = ModelFixtureTransport([
            owner, .status(baseline), owner, .accepted, .poll("{\"result\":0}"),
            .status(baseline), .status(sentryStatus(fixture, enabled: true, age: 20)),
            .status(sentryStatus(fixture, enabled: true, age: 10))
        ])
        let model = try await model(fixture, transport, initial: baseline)
        model.request(.sentryOn)
        await model.executePendingCommand(pin: "0000")
        XCTAssertEqual(model.operationMessage, "已读取到更新车况，哨兵状态已确认为开启。")
        XCTAssertEqual(model.status?.sentryMode, true)
        XCTAssertFalse(model.isCommandRunning)
        XCTAssertNil(model.errorMessage)
        await assertRequests(transport, commands: 1, polls: 1, statusReads: 4)
    }

    func testSentryOffConfirmsOnlyAfterNewDisabledSignal() async throws {
        let fixture = ConnectedModelFixture()
        let baseline = sentryStatus(fixture, enabled: true, age: 20)
        let transport = ModelFixtureTransport([
            owner, .status(baseline), owner, .accepted, .poll("{\"result\":0}"),
            .status(sentryStatus(fixture, enabled: false, age: 10))
        ])
        let model = try await model(fixture, transport, initial: baseline)
        model.request(.sentryOff)
        await model.executePendingCommand(pin: "0000")
        XCTAssertEqual(model.operationMessage, "已读取到更新车况，哨兵状态已确认为关闭。")
        XCTAssertEqual(model.status?.sentryMode, false)
        await assertRequests(transport, commands: 1, polls: 1, statusReads: 2)
    }

    func testManualRefreshResolvesTimedOutSentryObservationWithoutResubmission() async throws {
        let fixture = ConnectedModelFixture()
        let baseline = sentryStatus(fixture, enabled: false, age: 20)
        let transport = ModelFixtureTransport([
            owner, .status(baseline), owner, .accepted, .poll("{\"result\":0}"), .status(baseline),
            .status(sentryStatus(fixture, enabled: true, age: 10)), owner, configuration
        ])
        let model = try await model(fixture, transport, initial: baseline, policy: short)
        model.request(.sentryOn)
        await model.executePendingCommand(pin: "0000")
        XCTAssertTrue(model.operationMessage?.contains("状态未确认") == true)
        XCTAssertFalse(model.isCommandRunning)
        await model.refresh()
        XCTAssertEqual(model.operationMessage, "已读取到更新车况，哨兵状态已确认为开启。")
        XCTAssertNil(model.errorMessage)
        await assertRequests(transport, commands: 1, polls: 1, statusReads: 3)
    }

    func testManualRefreshRequiresKnownTargetAndStrictlyNewerTimestamp() async throws {
        let fixture = ConnectedModelFixture()
        let baseline = sentryStatus(fixture, enabled: false, age: 20)
        let transport = ModelFixtureTransport([
            owner, .status(baseline), owner, .accepted, .poll("{\"result\":0}"), .status(baseline),
            .status(sentryStatus(fixture, enabled: true, age: 20)), owner, configuration,
            .status(sentryStatus(fixture, enabled: nil, age: 10)), owner, configuration,
            .status(sentryStatus(fixture, enabled: true, age: 5)), owner, configuration
        ])
        let model = try await model(fixture, transport, initial: baseline, policy: short)
        model.request(.sentryOn)
        await model.executePendingCommand(pin: "0000")
        let pending = model.operationMessage
        await model.refresh()
        XCTAssertEqual(model.operationMessage, pending, "Matching cached state must remain unconfirmed")
        await model.refresh()
        XCTAssertEqual(model.operationMessage, pending, "Unknown sentry state must remain unconfirmed")
        await model.refresh()
        XCTAssertEqual(model.operationMessage, "已读取到更新车况，哨兵状态已确认为开启。")
        await assertRequests(transport, commands: 1, polls: 1, statusReads: 5)
    }

    func testRecoverableTelemetryFailureCanBeResolvedByExplicitRefresh() async throws {
        let fixture = ConnectedModelFixture()
        let baseline = sentryStatus(fixture, enabled: false, age: 20)
        let transport = ModelFixtureTransport([
            owner, .status(baseline), owner, .accepted, .poll("{\"result\":0}"),
            .init(path: ModelFixtureTransport.statusPath, reply: .error(.networkUnavailable)),
            .status(sentryStatus(fixture, enabled: true, age: 10)), owner, configuration
        ])
        let model = try await model(fixture, transport, initial: baseline)
        model.request(.sentryOn)
        await model.executePendingCommand(pin: "0000")
        XCTAssertTrue(model.operationMessage?.contains("状态仍待核对") == true)
        XCTAssertNotNil(model.errorMessage)
        await model.refresh()
        XCTAssertEqual(model.operationMessage, "已读取到更新车况，哨兵状态已确认为开启。")
        XCTAssertNil(model.errorMessage)
        await assertRequests(transport, commands: 1, polls: 1, statusReads: 3)
    }

    func testLateSentryTelemetryAfterDeadlineCannotConfirmOrReplaceStatus() async throws {
        let fixture = ConnectedModelFixture()
        let baseline = sentryStatus(fixture, enabled: false, age: 20)
        let transport = ModelFixtureTransport([
            owner, .status(baseline), owner, .accepted, .poll("{\"result\":0}"),
            .init(path: ModelFixtureTransport.statusPath, reply: .suspended)
        ])
        let model = try await model(fixture, transport, initial: baseline, policy: short)
        model.request(.sentryOn)
        let operation = Task { await model.executePendingCommand(pin: "0000") }
        let suspended = await waitUntilSuspended(transport)
        XCTAssertTrue(suspended)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(model.isCommandRunning)
        XCTAssertTrue(model.operationMessage?.contains("状态未确认") == true)
        let message = model.operationMessage
        let oldStatus = model.status
        await transport.release(sentryStatus(fixture, enabled: true, age: 10))
        await operation.value
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(model.operationMessage, message)
        XCTAssertEqual(model.status, oldStatus)
        await assertRequests(transport, commands: 1, polls: 1, statusReads: 2)
    }

    func testLogoutDiscardsLateSentryObservation() async throws {
        let fixture = ConnectedModelFixture()
        let baseline = sentryStatus(fixture, enabled: false, age: 20)
        let transport = ModelFixtureTransport([
            owner, .status(baseline), owner, .accepted, .poll("{\"result\":0}"),
            .init(path: ModelFixtureTransport.statusPath, reply: .suspended)
        ])
        let model = try await model(fixture, transport, initial: baseline)
        model.request(.sentryOn)
        let operation = Task { await model.executePendingCommand(pin: "0000") }
        let suspended = await waitUntilSuspended(transport)
        XCTAssertTrue(suspended)
        await model.logout()
        await transport.release(sentryStatus(fixture, enabled: true, age: 10))
        await operation.value
        XCTAssertEqual(model.mode, .signedOut)
        XCTAssertNil(model.status)
        XCTAssertNil(model.operationMessage)
        XCTAssertFalse(model.isCommandRunning)
        await assertRequests(transport, commands: 1, polls: 1, statusReads: 2)
    }

    func testRotatedCredentialsPersistBeforeTimedOutSentryTelemetryReturns() async throws {
        try await assertRotatedCredentialsPersistBeforeLateTelemetry(cancel: false)
    }

    func testRotatedCredentialsPersistBeforeCancelledSentryTelemetryReturns() async throws {
        try await assertRotatedCredentialsPersistBeforeLateTelemetry(cancel: true)
    }

    func testNewCommandPreventsOldSentryMessageFromReappearing() async throws {
        let fixture = ConnectedModelFixture()
        let baseline = sentryStatus(fixture, enabled: false, age: 20)
        let transport = ModelFixtureTransport([
            owner, .status(baseline), owner, .accepted, .poll("{\"result\":0}"), .status(baseline),
            .status(baseline), .accepted, .poll("{\"result\":0}"), .status(baseline),
            .status(sentryStatus(fixture, enabled: true, age: 10)), owner, configuration
        ])
        let model = try await model(fixture, transport, initial: baseline, policy: short)
        model.request(.sentryOn)
        await model.executePendingCommand(pin: "0000")
        XCTAssertTrue(model.operationMessage?.contains("状态未确认") == true)
        model.request(.lock)
        await model.executePendingCommand(pin: "0000")
        let lockResult = model.operationMessage
        XCTAssertEqual(lockResult, "车辆接口已确认指令完成，车况已刷新。")
        await model.refresh()
        XCTAssertEqual(model.operationMessage, lockResult)
        await assertRequests(transport, commands: 2, polls: 2, statusReads: 5)
    }

    func testSentryPreflightRemovalClearsVisibleSelectionWithoutSubmitting() async throws {
        let fixture = ConnectedModelFixture()
        let baseline = sentryStatus(fixture, enabled: false, age: 20)
        let transport = ModelFixtureTransport([
            owner, .status(baseline),
            .init(path: "/app/app-global-service/v1/vehicle/list", reply: .json("{\"code\":0,\"data\":[]}", 200))
        ])
        let model = try await model(fixture, transport, initial: baseline)
        model.request(.sentryOn)
        await model.executePendingCommand(pin: "0000")
        XCTAssertEqual(model.mode, .connected)
        XCTAssertNil(model.selectedVehicle)
        XCTAssertNil(model.status)
        XCTAssertTrue(model.vehicles.isEmpty)
        XCTAssertFalse(model.canControl)
        XCTAssertNil(model.operationMessage)
        XCTAssertNotNil(model.vehicleMetadataUpdatedAt)
        XCTAssertTrue(model.vehicleMetadataMessage?.contains("原车辆已不在") == true)
        XCTAssertEqual(model.errorMessage, SentryControlError.unknownOwnership.errorDescription)
        await assertRequests(transport, commands: 0, polls: 0, statusReads: 1)
    }

    func testSentryPreflightSharedAccountKeepsVehicleButUpdatesOwnership() async throws {
        let fixture = ConnectedModelFixture()
        let baseline = sentryStatus(fixture, enabled: false, age: 20)
        let transport = ModelFixtureTransport([
            owner, .status(baseline),
            .init(path: "/app/app-global-service/v1/vehicle/list", reply: .json(
                "{\"code\":0,\"data\":[{\"vin\":\"FIXTUREVIN0000001\",\"isOwner\":false}]}", 200))
        ])
        let model = try await model(fixture, transport, initial: baseline)
        let oldUpdate = fixture.clock.read().addingTimeInterval(-30)
        model.vehicleMetadataUpdatedAt = oldUpdate
        model.request(.sentryOn)
        await model.executePendingCommand(pin: "0000")
        XCTAssertEqual(model.selectedVehicle?.ownership, .shared)
        XCTAssertNotNil(model.status)
        XCTAssertEqual(model.vehicles.first?.ownership, .shared)
        XCTAssertEqual(model.vehicleMetadataUpdatedAt, oldUpdate)
        XCTAssertNil(model.operationMessage)
        XCTAssertFalse(model.canRequest(.sentryOn))
        XCTAssertTrue(model.canRequest(.sentryOff))
        XCTAssertEqual(model.errorMessage, SentryControlError.sharedAccountCannotEnable.errorDescription)
        await assertRequests(transport, commands: 0, polls: 0, statusReads: 1)
    }

    private var owner: ModelFixtureTransport.Step {
        .init(path: "/app/app-global-service/v1/vehicle/list", reply: .json(
            "{\"code\":0,\"data\":[{\"vin\":\"FIXTUREVIN0000001\",\"isOwner\":true}]}", 200))
    }

    private var configuration: ModelFixtureTransport.Step {
        .init(path: "/carownerservice/v3/api/vehicleinfo/commonConfig", reply: .json("{\"code\":0,\"data\":{}}", 200))
    }

    private func sentryStatus(_ fixture: ConnectedModelFixture, enabled: Bool?, age: TimeInterval) -> String {
        let signal = enabled.map { ",\"3636\":\($0 ? 1 : 0)" } ?? ""
        let timestamp = (floor(fixture.clock.read().timeIntervalSince1970) - age) * 1000
        return "{\"code\":0,\"data\":{\"signalMap\":{\"gearStatus\":\"P\",\"speed\":0,\"sts\":\(timestamp),\"soc\":70\(signal)}}}"
    }

    private func model(_ fixture: ConnectedModelFixture, _ transport: ModelFixtureTransport, initial: String,
                       policy: ControlPollingPolicy = .init(timeout: 1, initialDelay: 0.005, interval: 0.005),
                       gatewayExpiry: Date? = nil) async throws -> AppModel {
        let model = fixture.model(transport, policy: policy, gatewayExpiry: gatewayExpiry)
        model.selectedVehicle?.ownership = .owner
        model.status = VehicleStatus(raw: try JSONValue(data: Data(initial.utf8)), receivedAt: fixture.clock.read())
        _ = try await fixture.client?.bootstrap()
        return model
    }

    private func assertRotatedCredentialsPersistBeforeLateTelemetry(cancel: Bool,
                                                                    file: StaticString = #filePath,
                                                                    line: UInt = #line) async throws {
        let fixture = ConnectedModelFixture()
        let clock = fixture.clock
        let baseline = sentryStatus(fixture, enabled: false, age: 20)
        // Construct a genuinely newer, fresh matching observation before the API
        // clock advances; receipt time must never become the vehicle source time.
        let lateTarget = sentryStatus(fixture, enabled: true, age: 10)
        let gatewayReply = try fixture.gatewayReply()
        let rotatedAccess = try XCTUnwrap(JSONValue(data: Data(gatewayReply.utf8))["data"]?["accessToken"]?.stringValue)
        let transport = ModelFixtureTransport([
            owner, .status(baseline), owner, .accepted, .poll("{\"result\":0}"),
            .init(path: ModelFixtureTransport.refreshPath, reply: .json(gatewayReply, 200)),
            .init(path: ModelFixtureTransport.statusPath, reply: .suspended)
        ], onPoll: { clock.advance(70) })
        let policy = cancel ? ControlPollingPolicy(timeout: 1, initialDelay: 0.005, interval: 1) : short
        let model = try await model(fixture, transport, initial: baseline, policy: policy,
                                    gatewayExpiry: clock.read().addingTimeInterval(360))
        model.request(.sentryOn)
        let operation = Task { await model.executePendingCommand(pin: "0000") }
        let suspended = await waitUntilSuspended(transport)
        XCTAssertTrue(suspended, "Rotation must complete inside the post-result telemetry read", file: file, line: line)
        if cancel { operation.cancel() }
        for _ in 0..<1000 {
            if !model.isCommandRunning { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertFalse(model.isCommandRunning, "UI must finish before the non-cooperative read returns", file: file, line: line)
        XCTAssertEqual(model.mode, .connected, file: file, line: line)
        XCTAssertEqual(fixture.savedSessions.last?.newAuth?.accessToken, rotatedAccess,
                       "Persist the successful rotation before releasing late telemetry", file: file, line: line)
        XCTAssertEqual(fixture.savedSessions.last?.newAuth?.refreshToken, String(repeating: "n", count: 32),
                       file: file, line: line)
        let message = model.operationMessage
        let error = model.errorMessage
        let oldStatus = model.status
        XCTAssertTrue(message?.contains(cancel ? "状态仍待核对" : "状态未确认") == true, file: file, line: line)
        let savedBeforeRelease = fixture.savedSessions
        await transport.release(lateTarget)
        await operation.value
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(model.operationMessage, message, file: file, line: line)
        XCTAssertEqual(model.errorMessage, error, file: file, line: line)
        XCTAssertEqual(model.status, oldStatus, file: file, line: line)
        XCTAssertEqual(fixture.savedSessions, savedBeforeRelease, "Late callbacks must not alter persistence", file: file, line: line)
        let paths = await transport.paths()
        XCTAssertEqual(paths.filter { $0 == ModelFixtureTransport.refreshPath }.count, 1, file: file, line: line)
        await assertRequests(transport, commands: 1, polls: 1, statusReads: 2, file: file, line: line)
    }

    private func waitUntilSuspended(_ transport: ModelFixtureTransport) async -> Bool {
        for _ in 0..<1000 {
            if await transport.isSuspended() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    private func assertRequests(_ transport: ModelFixtureTransport, commands: Int, polls: Int, statusReads: Int,
                                file: StaticString = #filePath, line: UInt = #line) async {
        let paths = await transport.paths()
        XCTAssertEqual(paths.filter { $0 == ModelFixtureTransport.commandPath }.count, commands, file: file, line: line)
        XCTAssertEqual(paths.filter { $0 == ModelFixtureTransport.pollPath }.count, polls, file: file, line: line)
        XCTAssertEqual(paths.filter { $0 == ModelFixtureTransport.statusPath }.count, statusReads, file: file, line: line)
        let unused = await transport.unusedCount()
        XCTAssertEqual(unused, 0, file: file, line: line)
    }
}
