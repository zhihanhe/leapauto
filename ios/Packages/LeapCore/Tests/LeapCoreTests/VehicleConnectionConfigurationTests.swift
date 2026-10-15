import XCTest
@testable import LeapCore

final class VehicleConnectionConfigurationTests: XCTestCase {
    private let vin = "FIXTUREVIN0000001"
    private func parse(_ json: String) throws -> VehicleConnectionConfiguration {
        try VehicleConnectionConfiguration(response: JSONValue(data: Data(json.utf8)), expectedVIN: vin,
                                           fetchedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testMissingConfigurationRemainsUnknownNotAnUnsupportedModel() throws {
        for json in ["{\"code\":0,\"data\":{}}", "{\"code\":\"0\",\"data\":{\"config\":null}}",
                     "{\"code\":0,\"data\":{\"config\":{\"4\":null}}}"] {
            let value = try parse(json)
            XCTAssertFalse(value.hasBluetoothConfiguration)
            XCTAssertNil(value.controllerVersion)
        }
    }

    func testMalformedAndContradictorySuccessResponsesFailClosed() {
        for json in ["{\"code\":0,\"success\":false,\"data\":{}}",
                     "{\"code\":0,\"result\":1,\"data\":{}}",
                     "{\"code\":200,\"data\":{}}", "{\"code\":0,\"data\":[]}",
                     "{\"code\":0,\"data\":{\"config\":\"invalid\"}}",
                     "{\"code\":0,\"data\":{\"config\":{\"4\":true}}}",
                     "{\"code\":0,\"data\":{\"vin\":null}}"] {
            XCTAssertThrowsError(try parse(json), json)
        }
    }

    func testHardwareMetadataValidatedButAddressNotRetained() throws {
        let value = try parse("{\"code\":0,\"data\":{\"config\":{\"4\":{\"mac\":\"123456789abc\",\"version\":\"fixture-1\"}}}}")
        XCTAssertTrue(value.hasBluetoothConfiguration)
        XCTAssertEqual(value.controllerVersion, "fixture-1")
        XCTAssertFalse(String(reflecting: value).contains("123456789abc"))
        XCTAssertFalse(String(reflecting: value).contains(vin))
        for address in ["000000000000", "FFFFFFFFFFFF", "12-34-56-78-9A-BC", "123456789abc00", ""] {
            let json: JSONValue = .object(["code": .number(0), "data": .object(["config": .object([
                "4": .object(["mac": .string(address), "version": .string("fixture-1")])])])])
            XCTAssertThrowsError(try VehicleConnectionConfiguration(response: json, expectedVIN: vin, fetchedAt: Date()))
        }
    }
}
