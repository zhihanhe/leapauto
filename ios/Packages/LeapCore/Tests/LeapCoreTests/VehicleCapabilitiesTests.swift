import Foundation
import XCTest
@testable import LeapCore

final class VehicleCapabilitiesTests: XCTestCase {
    func testDocumentedVehicleListRetainsOnlyExplicitSupportAndFeaturePresence() throws {
        let vehicle = try decodeVehicle(#"{"vin":"FIXTURE","carType":"C10","funcConfig":{"HVAC":{"temperature":{"min":16,"max":32},"fan":{"min":1,"max":7}},"FRIDGE":{"supported":true}}}"#)

        XCTAssertEqual(vehicle.capabilities[.hvac], .unknown)
        XCTAssertEqual(vehicle.capabilities[.fridge], .supported)
        XCTAssertEqual(vehicle.capabilities.reportedFeatures.map(\.feature), [.hvac, .fridge])
        XCTAssertEqual(vehicle.capabilities.features.map(\.title), ["空调", "车载冰箱"])
        XCTAssertEqual(vehicle.capabilities.features[0].statusTitle, "服务端未确认支持状态")
        XCTAssertEqual(vehicle.capabilities.features[1].statusTitle, "服务端标记支持")
    }

    func testMissingConfigurationAndModelNamesNeverImplySupportOrLackOfSupport() throws {
        for model in ["C10", "C16", "C16 6座", "Unknown"] {
            let vehicle = Vehicle(vin: "FIXTURE", modelName: model)
            XCTAssertEqual(vehicle.capabilities, .unknown)
            XCTAssertTrue(vehicle.capabilities.reportedFeatures.isEmpty)
            XCTAssertTrue(vehicle.capabilities.features.allSatisfy { $0.support == .unknown && !$0.wasReported })
            XCTAssertTrue(vehicle.capabilities.features.allSatisfy { $0.statusTitle == "未提供能力信息" })
        }

        let oldVehicle = try decodeVehicle(#"{"vin":"FIXTURE","modelName":"C10"}"#)
        XCTAssertEqual(oldVehicle.capabilities, .unknown)
        let encoded = try JSONValue(data: JSONEncoder().encode(oldVehicle))
        XCTAssertNil(encoded["funcConfig"])
    }

    func testExplicitFalseIsDistinctFromAbsentOrUnconfirmed() {
        let unsupported = VehicleCapabilities(funcConfig: .object(["FRIDGE": .object(["supported": .bool(false)])]))
        let unconfirmed = VehicleCapabilities(funcConfig: .object(["FRIDGE": .object([:])]))

        XCTAssertEqual(unsupported[.fridge], .unsupported)
        XCTAssertEqual(unsupported.reportedFeatures.first?.statusTitle, "服务端标记不支持")
        XCTAssertEqual(unconfirmed[.fridge], .unknown)
        XCTAssertEqual(unconfirmed.reportedFeatures.first?.wasReported, true)
        XCTAssertNotEqual(unsupported, unconfirmed)
        XCTAssertNotEqual(unconfirmed, .unknown)
    }

    func testOnlyLiteralBooleanSupportDeclarationsAreAccepted() {
        let malformed: [JSONValue] = [.null, .number(0), .number(1), .number(2), .string("true"), .string("false"), .array([]), .object([:])]
        for raw in malformed {
            let capabilities = VehicleCapabilities(funcConfig: .object(["FRIDGE": .object(["supported": raw])]))
            XCTAssertEqual(capabilities[.fridge], .unknown)
            XCTAssertEqual(capabilities.reportedFeatures.first?.wasReported, true)
        }

        for raw in malformed + [.bool(true), .bool(false)] {
            let capabilities = VehicleCapabilities(funcConfig: .object(["FRIDGE": raw]))
            XCTAssertEqual(capabilities[.fridge], .unknown)
            XCTAssertEqual(capabilities.reportedFeatures.first?.wasReported, true)
        }
    }

    func testInvalidConfigurationContainerDoesNotInventFeatures() {
        for raw in [JSONValue.null, .bool(false), .string("FRIDGE"), .array([.string("HVAC")])] {
            let capabilities = VehicleCapabilities(funcConfig: raw)
            XCTAssertEqual(capabilities, .unknown)
            XCTAssertTrue(capabilities.reportedFeatures.isEmpty)
        }
    }

    func testLowercaseHVACCompatibilityAndConservativeAliasPrecedence() {
        let lowercase = VehicleCapabilities(funcConfig: .object(["hvac": .object(["supported": .bool(true)])]))
        XCTAssertEqual(lowercase[.hvac], .supported)
        XCTAssertEqual(lowercase.reportedFeatures.map(\.feature), [.hvac])

        let conflicted = VehicleCapabilities(funcConfig: .object([
            "HVAC": .null,
            "hvac": .object(["supported": .bool(true)])
        ]))
        XCTAssertEqual(conflicted[.hvac], .unknown)
        XCTAssertEqual(conflicted.reportedFeatures.first?.wasReported, true)
    }

    func testUnknownFeaturesAndSensitiveFieldsAreNotRetainedOrEncoded() throws {
        let vehicle = try decodeVehicle(#"{"vin":"FIXTURE","funcConfig":{"HVAC":{"supported":true,"token":"DO-NOT-RETAIN"},"FRIDGE":{"supported":false,"accountId":"DO-NOT-RETAIN"},"BLE":{"supported":true,"certificate":"DO-NOT-RETAIN"},"unrecognized-secret-name":{"supported":true},"token":"DO-NOT-RETAIN"}}"#)
        let encoded = try JSONEncoder().encode(vehicle)
        let json = try JSONValue(data: encoded)

        XCTAssertEqual(json["funcConfig"], .object([
            "HVAC": .object(["supported": .bool(true)]),
            "FRIDGE": .object(["supported": .bool(false)])
        ]))
        let text = String(decoding: encoded, as: UTF8.self)
        for forbidden in ["DO-NOT-RETAIN", "token", "accountId", "certificate", "BLE", "unrecognized-secret-name"] {
            XCTAssertFalse(text.contains(forbidden))
        }
        XCTAssertFalse(BLEHardwareFeatureGate.isEnabled)
    }

    func testCapabilityAndVehicleRoundTripsPreserveReportedUnknown() throws {
        let capabilities = VehicleCapabilities(funcConfig: .object([
            "HVAC": .object(["temperature": .object(["min": .number(16), "max": .number(32)])]),
            "FRIDGE": .object(["supported": .bool(false)])
        ]))
        let data = try JSONEncoder().encode(capabilities)
        XCTAssertEqual(try JSONDecoder().decode(VehicleCapabilities.self, from: data), capabilities)
        XCTAssertEqual(try JSONValue(data: data)["HVAC"], .object([:]))

        let vehicle = Vehicle(vin: "FIXTURE", modelName: "C10", capabilities: capabilities)
        XCTAssertEqual(try JSONDecoder().decode(Vehicle.self, from: JSONEncoder().encode(vehicle)), vehicle)
    }

    private func decodeVehicle(_ text: String) throws -> Vehicle {
        try JSONDecoder().decode(Vehicle.self, from: Data(text.utf8))
    }
}
