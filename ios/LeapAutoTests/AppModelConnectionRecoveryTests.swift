import XCTest
@testable import LeapAuto
import LeapCore

@MainActor
final class AppModelConnectionRecoveryTests: XCTestCase {
    private let listPath = "/app/app-global-service/v1/vehicle/list"
    private let routePath = "/app/app-global-service/v1/vehicle/getCarRoute"
    private let configPath = "/carownerservice/v3/api/vehicleinfo/commonConfig"

    private var route: ModelFixtureTransport.Step {
        .init(path: routePath, reply: .json("{\"code\":0,\"data\":{\"appRegion\":\"\(TrustedEndpoints.global)\"}}", 200))
    }
    private var configuration: ModelFixtureTransport.Step {
        .init(path: configPath, reply: .json("{\"code\":0,\"data\":{}}", 200))
    }
    private var failedStatus: ModelFixtureTransport.Step {
        .init(path: ModelFixtureTransport.statusPath, reply: .error(.networkUnavailable))
    }
    private var revokedCapabilities: ModelFixtureTransport.Step {
        .init(path: listPath, reply: .json("""
        {"code":0,"data":[{"vin":"FIXTUREVIN0000001","isOwner":false,"carType":"C10","funcConfig":{"HVAC":{"supported":false}}}]}
        """, 200))
    }

    func testSelectionRefreshesOwnershipAndCapabilitiesAfterTelemetryFailure() async throws {
        let fixture = ConnectedModelFixture()
        let transport = ModelFixtureTransport([.metadata, route, failedStatus, revokedCapabilities, configuration])
        let model = fixture.model(transport)
        let list = try await fixture.client!.bootstrap()
        var selected = try XCTUnwrap(list.first)
        selected.ownership = .owner
        model.errorMessage = "Previous fixture failure"
        await model.selectVehicle(selected)
        XCTAssertEqual(model.mode, .connected)
        XCTAssertEqual(model.selectedVehicle?.ownership, .shared)
        XCTAssertEqual(model.selectedVehicle?.capabilities[.hvac], .unsupported)
        XCTAssertNotNil(model.vehicleMetadataUpdatedAt)
        XCTAssertNotNil(model.connectionConfiguration)
        XCTAssertNil(model.status)
        XCTAssertFalse(model.canControl)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNotEqual(model.errorMessage, "Previous fixture failure")
        XCTAssertNil(model.operationMessage)
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(fixture.savedSessions.last?.selectedVIN, selected.vin)
        await assertPaths(transport, [listPath, routePath, ModelFixtureTransport.statusPath, listPath, configPath])
    }

    func testSelectionRemovalAfterTelemetryFailureClearsSelectionWithoutConfigurationRead() async throws {
        let fixture = ConnectedModelFixture()
        let transport = ModelFixtureTransport([.metadata, route, failedStatus,
            .init(path: listPath, reply: .json("{\"code\":0,\"data\":[]}", 200))])
        let model = fixture.model(transport)
        let list = try await fixture.client!.bootstrap()
        await model.selectVehicle(try XCTUnwrap(list.first))
        XCTAssertNil(model.selectedVehicle)
        XCTAssertNil(model.status)
        XCTAssertNil(model.connectionConfiguration)
        XCTAssertTrue(model.vehicles.isEmpty)
        XCTAssertNotNil(model.vehicleMetadataMessage)
        XCTAssertEqual(fixture.savedSessions.last?.selectedVIN, "")
        await assertPaths(transport, [listPath, routePath, ModelFixtureTransport.statusPath, listPath])
    }

    // Import invokes this same post-bootstrap stage. Its security-scoped file
    // entrypoint stays disabled in offline tests and never creates a live client.
    func testBootstrapReadsConfigurationAfterTelemetryFailure() async {
        let fixture = ConnectedModelFixture()
        let transport = ModelFixtureTransport([.metadata, failedStatus, configuration])
        let model = fixture.model(transport)
        model.selectedVehicle = nil
        model.status = nil
        await model.refresh()
        XCTAssertEqual(model.mode, .connected)
        XCTAssertNotNil(model.selectedVehicle)
        XCTAssertNotNil(model.connectionConfiguration)
        XCTAssertNotNil(model.vehicleMetadataUpdatedAt)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(model.operationMessage)
        XCTAssertNil(model.status)
        XCTAssertFalse(model.isBusy)
        await assertPaths(transport, [listPath, ModelFixtureTransport.statusPath, configPath])
    }

    func testBootstrapSuccessfulTelemetryStillReadsConfiguration() async {
        let fixture = ConnectedModelFixture()
        let transport = ModelFixtureTransport([.metadata, .status(fixture.parked), configuration])
        let model = fixture.model(transport)
        model.selectedVehicle = nil
        model.status = nil
        model.errorMessage = "Previous fixture failure"
        await model.refresh()
        XCTAssertEqual(model.status?.batterySOC, 70)
        XCTAssertNotNil(model.connectionConfiguration)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(fixture.savedSessions.isEmpty)
        await assertPaths(transport, [listPath, ModelFixtureTransport.statusPath, configPath])
    }

    func testBootstrapListFailureDoesNotStartTelemetryOrConfiguration() async {
        let fixture = ConnectedModelFixture()
        let transport = ModelFixtureTransport([.init(path: listPath, reply: .error(.networkUnavailable))])
        let model = fixture.model(transport)
        model.selectedVehicle = nil
        await model.refresh()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(model.selectedVehicle)
        await assertPaths(transport, [listPath])
    }

    func testFailedSelectionDoesNotStartTelemetryOrMetadata() async throws {
        let fixture = ConnectedModelFixture()
        let transport = ModelFixtureTransport([.metadata,
            .init(path: routePath, reply: .error(.networkUnavailable))])
        let model = fixture.model(transport)
        let list = try await fixture.client!.bootstrap()
        await model.selectVehicle(try XCTUnwrap(list.first))
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(model.selectedVehicle)
        XCTAssertNil(model.connectionConfiguration)
        await assertPaths(transport, [listPath, routePath])
    }

    func testBootstrapAuthenticationFailureStopsConfigurationAndLogsOut() async {
        let fixture = ConnectedModelFixture()
        let legacyPath = "/app-user/appuseroperate/getnewtoken"
        let transport = ModelFixtureTransport([.metadata,
            .init(path: ModelFixtureTransport.statusPath, reply: .error(.authenticationRequired)),
            .init(path: ModelFixtureTransport.refreshPath, reply: .error(.authenticationRequired)),
            .init(path: legacyPath, reply: .error(.authenticationRequired))])
        let model = fixture.model(transport)
        model.selectedVehicle = nil
        await model.refresh()
        XCTAssertEqual(model.mode, .signedOut)
        XCTAssertNil(model.connectionConfiguration)
        XCTAssertNil(model.operationMessage)
        XCTAssertEqual(fixture.removalCount, 1)
        await assertPaths(transport, [listPath, ModelFixtureTransport.statusPath,
                                      ModelFixtureTransport.refreshPath, legacyPath])
    }

    func testBootstrapCancellationDuringTelemetryStopsConfiguration() async {
        let fixture = ConnectedModelFixture()
        let transport = ModelFixtureTransport([.metadata,
            .init(path: ModelFixtureTransport.statusPath, reply: .suspended)])
        let model = fixture.model(transport)
        model.selectedVehicle = nil
        model.status = nil
        let task = Task { await model.refresh() }
        await waitForSuspension(transport)
        task.cancel()
        await transport.release(fixture.parked)
        await task.value
        XCTAssertNil(model.status)
        XCTAssertNil(model.connectionConfiguration)
        XCTAssertNil(model.operationMessage)
        XCTAssertFalse(model.isBusy)
        await assertPaths(transport, [listPath, ModelFixtureTransport.statusPath])
    }

    func testLogoutDuringBootstrapTelemetryRejectsLateStateAndConfiguration() async {
        let fixture = ConnectedModelFixture()
        let transport = ModelFixtureTransport([.metadata,
            .init(path: ModelFixtureTransport.statusPath, reply: .suspended)])
        let model = fixture.model(transport)
        model.selectedVehicle = nil
        let task = Task { await model.refresh() }
        await waitForSuspension(transport)
        await model.logout()
        await transport.release(fixture.parked)
        await task.value
        XCTAssertEqual(model.mode, .signedOut)
        XCTAssertNil(model.selectedVehicle)
        XCTAssertNil(model.status)
        XCTAssertNil(model.connectionConfiguration)
        XCTAssertTrue(fixture.savedSessions.isEmpty)
        await assertPaths(transport, [listPath, ModelFixtureTransport.statusPath])
    }

    func testRotatedCredentialsSurviveBootstrapTelemetryFailure() async throws {
        let fixture = ConnectedModelFixture()
        let reply = try fixture.gatewayReply()
        let expected = try JSONValue(data: Data(reply.utf8))["data"]?["accessToken"]?.stringValue
        let transport = ModelFixtureTransport([
            .init(path: ModelFixtureTransport.refreshPath, reply: .json(reply, 200)),
            .metadata, failedStatus, configuration])
        let model = fixture.model(transport, gatewayExpiry: fixture.clock.read().addingTimeInterval(30))
        model.selectedVehicle = nil
        await model.refresh()
        XCTAssertEqual(fixture.savedSessions.last?.newAuth?.accessToken, expected)
        XCTAssertNotNil(model.connectionConfiguration)
        XCTAssertNotNil(model.errorMessage)
        await assertPaths(transport, [ModelFixtureTransport.refreshPath, listPath,
                                      ModelFixtureTransport.statusPath, configPath])
    }

    func testSelectionCancellationDuringMetadataStopsConfiguration() async throws {
        let fixture = ConnectedModelFixture()
        let transport = ModelFixtureTransport([.metadata, route, failedStatus,
            .init(path: listPath, reply: .suspended)])
        let model = fixture.model(transport)
        let list = try await fixture.client!.bootstrap()
        let selected = try XCTUnwrap(list.first)
        let task = Task { await model.selectVehicle(selected) }
        await waitForSuspension(transport)
        task.cancel()
        await transport.release("{\"code\":0,\"data\":[]}")
        await task.value
        XCTAssertNil(model.connectionConfiguration)
        XCTAssertNil(model.vehicleMetadataUpdatedAt)
        XCTAssertFalse(model.isBusy)
        await assertPaths(transport, [listPath, routePath, ModelFixtureTransport.statusPath, listPath])
    }

    func testSuccessfulSelectionClearsPreviousError() async throws {
        let fixture = ConnectedModelFixture()
        let transport = ModelFixtureTransport([.metadata, route, .status(fixture.parked), .metadata, configuration])
        let model = fixture.model(transport)
        let list = try await fixture.client!.bootstrap()
        model.errorMessage = "Previous fixture failure"
        await model.selectVehicle(try XCTUnwrap(list.first))
        XCTAssertNil(model.errorMessage)
        XCTAssertNotNil(model.status)
        XCTAssertNotNil(model.connectionConfiguration)
        await assertPaths(transport, [listPath, routePath, ModelFixtureTransport.statusPath, listPath, configPath])
    }

    func testEmptyBootstrapListDoesNotReadTelemetryOrConfiguration() async {
        let fixture = ConnectedModelFixture()
        let transport = ModelFixtureTransport([
            .init(path: listPath, reply: .json("{\"code\":0,\"data\":[]}", 200))])
        let model = fixture.model(transport)
        model.selectedVehicle = nil
        model.status = nil
        model.errorMessage = "Previous fixture failure"
        await model.refresh()
        XCTAssertTrue(model.vehicles.isEmpty)
        XCTAssertNil(model.selectedVehicle)
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.connectionConfiguration)
        XCTAssertEqual(fixture.savedSessions.last?.selectedVIN, "")
        await assertPaths(transport, [listPath])
    }

    func testCancellationPreservesRotatedCredentialsWithoutConfigurationRead() async throws {
        let fixture = ConnectedModelFixture()
        let reply = try fixture.gatewayReply()
        let expected = try JSONValue(data: Data(reply.utf8))["data"]?["accessToken"]?.stringValue
        let transport = ModelFixtureTransport([
            .init(path: ModelFixtureTransport.refreshPath, reply: .json(reply, 200)), .metadata,
            .init(path: ModelFixtureTransport.statusPath, reply: .suspended)])
        let model = fixture.model(transport, gatewayExpiry: fixture.clock.read().addingTimeInterval(30))
        model.selectedVehicle = nil
        model.status = nil
        let task = Task { await model.refresh() }
        await waitForSuspension(transport)
        task.cancel()
        await transport.release(fixture.parked)
        await task.value
        XCTAssertEqual(model.mode, .connected)
        XCTAssertEqual(fixture.savedSessions.last?.newAuth?.accessToken, expected)
        XCTAssertNil(model.status)
        XCTAssertNil(model.connectionConfiguration)
        await assertPaths(transport, [ModelFixtureTransport.refreshPath, listPath, ModelFixtureTransport.statusPath])
    }

    private func assertPaths(_ transport: ModelFixtureTransport, _ expected: [String],
                             file: StaticString = #filePath, line: UInt = #line) async {
        let paths = await transport.paths()
        let remaining = await transport.unusedCount()
        XCTAssertEqual(paths, expected, file: file, line: line)
        XCTAssertEqual(remaining, 0, file: file, line: line)
    }

    private func waitForSuspension(_ transport: ModelFixtureTransport) async {
        for _ in 0..<1000 {
            if await transport.isSuspended() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Offline transport did not suspend")
    }
}
