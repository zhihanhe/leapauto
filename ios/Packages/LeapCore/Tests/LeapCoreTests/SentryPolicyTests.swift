import Foundation
import XCTest
@testable import LeapCore

final class SentryPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func status(_ values: [String: JSONValue] = [:]) -> VehicleStatus {
        var signals: [String: JSONValue] = ["sts": .number(now.timeIntervalSince1970), "1010": .string("P"), "1319": .number(0)]
        signals.merge(values) { _, new in new }
        return VehicleStatus(raw: .object(signals), receivedAt: now)
    }

    func testSentryPayloadsMatchDocumentedAndAndroidCommands() throws {
        for (command, operation, target) in [(LeapCommand.sentryOn, "on", true), (.sentryOff, "off", false)] {
            let payload = try command.build()
            XCTAssertEqual(payload.commandID, "400")
            XCTAssertEqual(payload.state, ["operation": .string(operation)])
            XCTAssertEqual(try JSONValue(data: Data(payload.stateJSON.utf8)), .object(payload.state))
            XCTAssertEqual(command.sentryTarget, target)
            XCTAssertFalse(command.isClimate)
        }
        XCTAssertNil(LeapCommand.lock.sentryTarget)
        XCTAssertEqual(LeapCommand.sentryOn.title, "开启哨兵模式")
        XCTAssertEqual(LeapCommand.sentryOff.title, "关闭哨兵模式")
    }

    func testOwnerCanEnableAndDisableButSharedAccountCanOnlyDisable() throws {
        for command in [LeapCommand.sentryOn, .sentryOff] {
            XCTAssertNoThrow(try SentryControlPolicy.validate(command: command, ownership: .owner))
            XCTAssertThrowsError(try SentryControlPolicy.validate(command: command, ownership: .unknown)) {
                XCTAssertEqual($0 as? SentryControlError, .unknownOwnership)
            }
        }
        XCTAssertNoThrow(try SentryControlPolicy.validate(command: .sentryOff, ownership: .shared))
        XCTAssertThrowsError(try SentryControlPolicy.validate(command: .sentryOn, ownership: .shared)) {
            XCTAssertEqual($0 as? SentryControlError, .sharedAccountCannotEnable)
        }
        XCTAssertNoThrow(try SentryControlPolicy.validate(command: .lock, ownership: .unknown))
    }

    func testSentryRequiresKnownSignalInAdditionToFreshParkedStatus() throws {
        for command in [LeapCommand.sentryOn, .sentryOff] {
            for signal in [JSONValue.number(0), .number(1)] {
                XCTAssertNoThrow(try command.validate(status: status(["3636": signal]), now: now))
            }
            XCTAssertThrowsError(try command.validate(status: status(), now: now)) {
                XCTAssertEqual($0 as? CommandValidationError, .sentryCapabilityUnknown)
            }
            XCTAssertThrowsError(try command.validate(status: status(["3636": .number(2)]), now: now)) {
                XCTAssertEqual($0 as? CommandValidationError, .sentryCapabilityUnknown)
            }
            XCTAssertThrowsError(try command.validate(status: nil, now: now))
            for invalid in [
                ["sts": JSONValue.null],
                ["sts": .number(now.timeIntervalSince1970 - 301)],
                ["sts": .number(now.timeIntervalSince1970 + 1)],
                ["1010": .string("D")],
                ["1319": .number(1)],
                ["1010": .null],
                ["1319": .null]
            ] {
                var signals = invalid
                signals["3636"] = .number(1)
                XCTAssertThrowsError(try command.validate(status: status(signals), now: now))
            }
            XCTAssertNoThrow(try command.validate(status: status(["3636": .number(1), "sts": .number(now.timeIntervalSince1970 - 300)]), now: now))
        }
    }

    func testSentryTelemetryPreservesUnknownAndNamedValuePrecedence() {
        XCTAssertNil(status().sentryMode)
        for raw in [JSONValue.number(0), .string("0"), .bool(false), .string("false")] {
            XCTAssertEqual(status(["3636": raw]).sentryMode, false)
        }
        for raw in [JSONValue.number(1), .string("1"), .bool(true), .string("true")] {
            XCTAssertEqual(status(["3636": raw]).sentryMode, true)
        }
        for raw in [JSONValue.null, .number(2), .number(-1), .number(0.5), .string("unknown"), .object([:]), .array([])] {
            XCTAssertNil(status(["3636": raw]).sentryMode)
            XCTAssertNil(status(["sentryMode": raw, "3636": .number(1)]).sentryMode)
        }
        XCTAssertEqual(status(["sentryMode": .bool(false), "3636": .number(1)]).sentryMode, false)
        XCTAssertNil(status(["sentryEnabled": .bool(true), "3637": .number(1)]).sentryMode)
    }

    func testSentryConfirmationRequiresExplicitMatchingTelemetry() {
        for target in [false, true] {
            XCTAssertTrue(SentryControlPolicy.isConfirmed(targetEnabled: target, telemetryEnabled: target))
            XCTAssertFalse(SentryControlPolicy.isConfirmed(targetEnabled: target, telemetryEnabled: !target))
            XCTAssertFalse(SentryControlPolicy.isConfirmed(targetEnabled: target, telemetryEnabled: nil))
        }
    }

    func testOnlyLiteralIsOwnerTrueEstablishesOwner() {
        XCTAssertEqual(VehicleOwnership(vehicleMetadata: .object(["isOwner": .bool(true)])), .owner)
        XCTAssertEqual(VehicleOwnership(vehicleMetadata: .object(["isOwner": .bool(false)])), .shared)
        for raw in [JSONValue.null, .number(0), .number(1), .string("true"), .string("false"), .object([:]), .array([])] {
            XCTAssertEqual(VehicleOwnership(vehicleMetadata: .object(["isOwner": raw])), .unknown)
        }
        let unconfirmed: [[String: JSONValue]] = [[:], ["owner": .bool(true)], ["isShare": .bool(false)], ["isMaster": .number(1)], ["bindType": .number(1)], ["ownership": .string("owner")]]
        for fields in unconfirmed {
            XCTAssertEqual(VehicleOwnership(vehicleMetadata: .object(fields)), .unknown)
        }
        for model in ["C10", "C16", "Unknown"] {
            XCTAssertEqual(Vehicle(vin: "SYNTHETIC-VIN", modelName: model).ownership, .unknown)
        }
        XCTAssertEqual(VehicleOwnership(vehicleMetadata: .null), .unknown)
    }

    func testAndroidRestrictiveSharedMarkersAndContradictionsFailClosed() {
        let sharedMarkers: [[String: JSONValue]] = [
            ["isOwner": .bool(false)], ["owner": .bool(false)],
            ["isShare": .bool(true)], ["isShared": .bool(true)], ["share": .bool(true)],
            ["bindType": .number(2)], ["bindType": .string("2")],
            ["userType": .number(2)], ["userType": .string("2")],
            ["shareType": .number(1)], ["shareType": .string("1")],
            ["isMaster": .number(0)], ["isMaster": .string("0")]
        ]
        for fields in sharedMarkers {
            XCTAssertEqual(VehicleOwnership(vehicleMetadata: .object(fields)), .shared)
            guard fields["isOwner"] == nil else { continue }
            var contradictory = fields
            contradictory["isOwner"] = .bool(true)
            XCTAssertEqual(VehicleOwnership(vehicleMetadata: .object(contradictory)), .unknown)
        }
        XCTAssertEqual(VehicleOwnership(vehicleMetadata: .object(["isOwner": .bool(false), "owner": .bool(true)])), .unknown)
        for key in ["owner", "isShare", "isShared", "share", "bindType", "userType", "shareType", "isMaster"] {
            XCTAssertEqual(VehicleOwnership(vehicleMetadata: .object(["isOwner": .bool(true), key: .string("invalid")])), .unknown)
            XCTAssertEqual(VehicleOwnership(vehicleMetadata: .object(["isOwner": .bool(false), key: .null])), .unknown)
        }
    }

    func testVehicleOwnershipRoundTripStoresOnlyCanonicalRelationship() throws {
        for ownership in [VehicleOwnership.owner, .shared, .unknown] {
            let vehicle = Vehicle(vin: "SYNTHETIC-VIN", modelName: "C10", ownership: ownership)
            let encoded = try JSONEncoder().encode(vehicle)
            XCTAssertEqual(try JSONDecoder().decode(Vehicle.self, from: encoded), vehicle)
            if ownership == .unknown { XCTAssertNil(try JSONValue(data: encoded)["isOwner"]) }
        }
        let data = Data(#"{"vin":"SYNTHETIC-VIN","bindType":2,"accountId":"DO-NOT-RETAIN","share":{"token":"DO-NOT-RETAIN"}}"#.utf8)
        let malformed = try JSONDecoder().decode(Vehicle.self, from: data)
        XCTAssertEqual(malformed.ownership, .unknown)
        let text = String(decoding: try JSONEncoder().encode(malformed), as: UTF8.self)
        for excluded in ["bindType", "accountId", "token", "DO-NOT-RETAIN", "share"] {
            XCTAssertFalse(text.contains(excluded))
        }
    }
}
