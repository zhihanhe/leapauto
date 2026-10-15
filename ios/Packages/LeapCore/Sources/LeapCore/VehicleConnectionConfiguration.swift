import Foundation

/// A deliberately minimal, memory-only view of commonConfig. A server-side
/// Bluetooth entry is advisory metadata, not a paired or authenticated key.
/// MAC addresses, certificates and account/vehicle identifiers are not retained.
public struct VehicleConnectionConfiguration: Equatable, Sendable {
    public let hasBluetoothConfiguration: Bool
    public let controllerVersion: String?
    public let fetchedAt: Date

    public init(response: JSONValue, expectedVIN: String, fetchedAt: Date) throws {
        guard WireJSON.isIdentifier(expectedVIN, min: 8, max: 32),
              fetchedAt.timeIntervalSince1970.isFinite,
              fetchedAt.timeIntervalSince1970 >= 0,
              response["code"]?.scalarString == "0",
              response["result"] == nil || response["result"]?.scalarString == "0",
              response["success"] == nil || response["success"] == .bool(true),
              let data = response["data"]?.objectValue else { throw LeapAPIError.invalidResponse }
        if let vin = data["vin"], vin.stringValue != expectedVIN { throw LeapAPIError.invalidResponse }
        self.fetchedAt = fetchedAt
        guard let config = try Self.optionalObject(data["config"]),
              let bluetooth = try Self.optionalObject(config["4"]) else {
            hasBluetoothConfiguration = false
            controllerVersion = nil
            return
        }
        guard let address = bluetooth["mac"]?.stringValue,
              Self.isValidAddress(address),
              let version = bluetooth["version"]?.stringValue,
              !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              version.count <= 64,
              !version.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw LeapAPIError.invalidResponse
        }
        hasBluetoothConfiguration = true
        controllerVersion = version
    }

    private static func optionalObject(_ value: JSONValue?) throws -> [String: JSONValue]? {
        guard let value, !value.isNull else { return nil }
        guard let object = value.objectValue else { throw LeapAPIError.invalidResponse }
        return object
    }

    private static func isValidAddress(_ address: String) -> Bool {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: "^(?:[0-9a-fA-F]{12}|(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2})$", options: .regularExpression) != nil else { return false }
        let compact = value.replacingOccurrences(of: ":", with: "").uppercased()
        return compact != "000000000000" && compact != "FFFFFFFFFFFF"
    }
}
