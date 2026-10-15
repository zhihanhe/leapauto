import Foundation

/// Vehicle-list relationship only; never inferred from VIN, model, session
/// presence, or absence of shared-account markers. The dispatch layer must fetch
/// current metadata for the selected VIN before using this to authorize sentry.
public enum VehicleOwnership: String, Codable, Equatable, Sendable {
    case owner
    case shared
    case unknown

    public init(vehicleMetadata: JSONValue) {
        guard let fields = vehicleMetadata.objectValue else { self = .unknown; return }
        var ownerReported = false
        var sharedReported = false
        var malformed = false
        for key in ["isOwner", "owner"] {
            guard let raw = fields[key] else { continue }
            if case .bool(let value) = raw {
                if value { ownerReported = true } else { sharedReported = true }
            } else { malformed = true }
        }
        // Restrictive compatibility markers from Android LeapmotorApi.listVehicles.
        // False/missing markers cannot establish ownership.
        for key in ["isShare", "isShared", "share"] {
            guard let raw = fields[key] else { continue }
            if case .bool(let value) = raw {
                if value { sharedReported = true }
            } else { malformed = true }
        }
        for (key, sharedValue) in [("bindType", 2), ("userType", 2), ("shareType", 1), ("isMaster", 0)] {
            guard let raw = fields[key] else { continue }
            // Exact integers or their canonical strings only. Unknown codes do
            // not establish either relationship; malformed data fails closed.
            let code: Int?
            switch raw {
            case .number(let value): code = Int(exactly: value)
            case .string(let value): code = Int(value).flatMap { String($0) == value ? $0 : nil }
            default: code = nil
            }
            guard let code else { malformed = true; continue }
            if code == sharedValue { sharedReported = true }
        }
        guard !malformed, !(ownerReported && sharedReported) else { self = .unknown; return }
        if sharedReported { self = .shared }
        else if fields["isOwner"] == .bool(true) { self = .owner }
        else { self = .unknown }
    }
}

public enum SentryControlError: Error, Equatable, LocalizedError, Sendable {
    case unknownOwnership
    case sharedAccountCannotEnable

    public var errorDescription: String? {
        switch self {
        case .unknownOwnership: return "尚未确认当前账号与车辆的所属关系，请刷新车辆信息后再操作哨兵。"
        case .sharedAccountCannotEnable: return "当前子账号不支持开启哨兵操作。"
        }
    }
}

/// Independent from PIN, local authentication, fresh parked telemetry and explicit
/// confirmation. Android permits shared-account disable, but never enable. Unknown
/// ownership blocks both directions rather than silently treating it as owner.
public enum SentryControlPolicy {
    public static func validate(command: LeapCommand, ownership: VehicleOwnership) throws {
        guard let target = command.sentryTarget else { return }
        switch ownership {
        case .owner: return
        case .shared:
            if target { throw SentryControlError.sharedAccountCannotEnable }
        case .unknown: throw SentryControlError.unknownOwnership
        }
    }

    /// A POST acceptance or a missing signal is never execution confirmation.
    public static func isConfirmed(targetEnabled: Bool, telemetryEnabled: Bool?) -> Bool {
        telemetryEnabled == targetEnabled
    }
}
