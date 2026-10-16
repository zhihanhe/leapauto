import XCTest
@testable import LeapAuto
import LeapCore

@MainActor
final class AppModelMetadataTests: XCTestCase {
    private let listPath = "/app/app-global-service/v1/vehicle/list"
    private let configPath = "/carownerservice/v3/api/vehicleinfo/commonConfig"

    func testMetadataRefreshReplacesEntireVehicleListAndCapabilities() async {
        let fixture = ConnectedModelFixture()
        let response = """
        {"code":0,"data":[{"vin":"FIXTUREVIN0000001","carType":"C10","funcConfig":{"HVAC":{"supported":false}}},{"vin":"FIXTUREVIN0000002","carType":"C16","funcConfig":{"FRIDGE":{"supported":true}}}]}
        """
        let transport = ModelFixtureTransport([
            .init(path: listPath, reply: .json(response, 200)),
            .init(path: configPath, reply: .json("{\"code\":0,\"data\":{}}", 200))
        ])
        let model = fixture.model(transport)
        model.vehicles.append(Vehicle(vin: "REMOVEDFIXTUREVIN", modelName: "Old fixture", plateNumber: nil))
        await model.inspectConnectionConfiguration()
        XCTAssertEqual(model.vehicles.map(\.vin), ["FIXTUREVIN0000001", "FIXTUREVIN0000002"])
        XCTAssertEqual(model.selectedVehicle?.capabilities[.hvac], .unsupported)
        XCTAssertEqual(model.vehicles.last?.capabilities[.fridge], .supported)
        XCTAssertNotNil(model.vehicleMetadataUpdatedAt)
        XCTAssertNil(model.vehicleMetadataMessage)
        let paths = await transport.paths()
        XCTAssertEqual(paths, [listPath, configPath])
    }

    func testRemovedSelectedVehicleKeepsRefreshedAlternativesWithoutSelectingOne() async {
        let fixture = ConnectedModelFixture()
        let transport = ModelFixtureTransport([
            .init(path: listPath, reply: .json("{\"code\":0,\"data\":[{\"vin\":\"FIXTUREVIN0000002\",\"carType\":\"C16\"}]}", 200))
        ])
        let model = fixture.model(transport)
        await model.inspectConnectionConfiguration()
        XCTAssertEqual(model.vehicles.map(\.vin), ["FIXTUREVIN0000002"])
        XCTAssertNil(model.selectedVehicle)
        XCTAssertNil(model.status)
        XCTAssertFalse(model.canControl)
        XCTAssertNotNil(model.vehicleMetadataUpdatedAt)
        XCTAssertTrue(model.vehicleMetadataMessage?.contains("原车辆") == true)
        XCTAssertEqual(fixture.savedSessions.last?.selectedVIN, "")
        let paths = await transport.paths()
        XCTAssertEqual(paths, [listPath])
    }

    func testTelemetryFailureDoesNotBlockCapabilityRefresh() async {
        let fixture = ConnectedModelFixture()
        let transport = ModelFixtureTransport([
            .init(path: ModelFixtureTransport.statusPath, reply: .error(.networkUnavailable)), .metadata,
            .init(path: configPath, reply: .json("{\"code\":0,\"data\":{}}", 200))
        ])
        let model = fixture.model(transport)
        let previousTimestamp = model.status?.sourceTimestamp
        await model.refresh()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.status?.sourceTimestamp, previousTimestamp)
        XCTAssertEqual(model.selectedVehicle?.capabilities[.hvac], .supported)
        XCTAssertNotNil(model.vehicleMetadataUpdatedAt)
        XCTAssertNotNil(model.connectionConfiguration)
        let paths = await transport.paths()
        XCTAssertEqual(paths, [ModelFixtureTransport.statusPath, listPath, configPath])
    }

    func testAuthoritativeEmptyListClearsVehicleAndTelemetry() async {
        let fixture = ConnectedModelFixture()
        let transport = ModelFixtureTransport([
            .init(path: listPath, reply: .json("{\"code\":0,\"data\":[]}", 200))
        ])
        let model = fixture.model(transport)
        await model.inspectConnectionConfiguration()
        XCTAssertTrue(model.vehicles.isEmpty)
        XCTAssertNil(model.selectedVehicle)
        XCTAssertNil(model.status)
        XCTAssertFalse(model.canControl)
        XCTAssertNotNil(model.vehicleMetadataUpdatedAt)
        XCTAssertEqual(fixture.savedSessions.last?.selectedVIN, "")
    }

    func testMalformedListDoesNotBecomeVehicleRemovalOrFreshMetadata() async {
        let fixture = ConnectedModelFixture()
        let transport = ModelFixtureTransport([
            .init(path: listPath, reply: .json("{\"code\":0}", 200))
        ])
        let model = fixture.model(transport)
        let oldTimestamp = Date(timeIntervalSince1970: 1_700_000_000)
        model.vehicleMetadataUpdatedAt = oldTimestamp
        await model.inspectConnectionConfiguration()
        XCTAssertEqual(model.selectedVehicle?.vin, "FIXTUREVIN0000001")
        XCTAssertEqual(model.vehicles.count, 1)
        XCTAssertNotNil(model.status)
        XCTAssertEqual(model.vehicleMetadataUpdatedAt, oldTimestamp)
        XCTAssertTrue(model.vehicleMetadataMessage?.contains("未能更新") == true)
        XCTAssertNil(model.connectionConfiguration)
    }

    func testConfigurationFailureDoesNotMislabelSuccessfulMetadataRefresh() async {
        let fixture = ConnectedModelFixture()
        let transport = ModelFixtureTransport([.metadata,
            .init(path: configPath, reply: .error(.networkUnavailable))])
        let model = fixture.model(transport)
        model.vehicleMetadataMessage = "Old fixture failure"
        await model.inspectConnectionConfiguration()
        XCTAssertEqual(model.selectedVehicle?.capabilities[.hvac], .supported)
        XCTAssertNotNil(model.vehicleMetadataUpdatedAt)
        XCTAssertNil(model.vehicleMetadataMessage)
        XCTAssertNotNil(model.connectionConfigurationMessage)
    }

    func testAuthenticationFailureStopsFollowupMetadataReads() async {
        let fixture = ConnectedModelFixture()
        let legacyRefreshPath = "/app-user/appuseroperate/getnewtoken"
        // A read rejection first attempts the supported gateway/legacy recovery.
        // Reject both renewals to exercise terminal expiry and metadata isolation.
        let transport = ModelFixtureTransport([
            .init(path: ModelFixtureTransport.statusPath, reply: .error(.authenticationRequired)),
            .init(path: ModelFixtureTransport.refreshPath, reply: .error(.authenticationRequired)),
            .init(path: legacyRefreshPath, reply: .error(.authenticationRequired))])
        let model = fixture.model(transport)
        await model.refresh()
        XCTAssertEqual(model.mode, .signedOut)
        XCTAssertNil(model.vehicleMetadataMessage)
        let paths = await transport.paths()
        XCTAssertEqual(paths, [ModelFixtureTransport.statusPath,
                               ModelFixtureTransport.refreshPath, legacyRefreshPath])
    }
}
