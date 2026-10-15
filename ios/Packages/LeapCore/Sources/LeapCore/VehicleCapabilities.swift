import Foundation

/// Only feature names verified in the vehicle-list contract belong here. Unknown
/// server keys are deliberately discarded rather than kept as raw diagnostics.
public enum VehicleFeature: String, CaseIterable, Codable, Sendable {
    case hvac = "HVAC"
    case fridge = "FRIDGE"

    public var title: String {
        switch self {
        case .hvac: return "空调"
        case .fridge: return "车载冰箱"
        }
    }
}

/// A server declaration, not an authorization or a successful hardware test.
/// Missing and malformed declarations must never become `.unsupported`.
public enum VehicleCapabilitySupport: String, Codable, Sendable {
    case unknown
    case supported
    case unsupported
}

public struct VehicleFeatureCapability: Equatable, Identifiable, Sendable {
    public let feature: VehicleFeature
    public let support: VehicleCapabilitySupport
    public let wasReported: Bool

    public var id: VehicleFeature { feature }
    public var title: String { feature.title }
    public var statusTitle: String {
        switch support {
        case .supported: return "服务端标记支持"
        case .unsupported: return "服务端标记不支持"
        case .unknown: return wasReported ? "服务端未确认支持状态" : "未提供能力信息"
        }
    }
}

/// Read-only vehicle-list diagnostics. This keeps only a fixed feature whitelist
/// and explicit Boolean support declarations from `funcConfig`; no raw response,
/// identifiers, credentials, capability parameters, or model guesses are stored.
///
/// Presence of an HVAC configuration does not prove support. Likewise, an absent
/// feature does not prove that a vehicle lacks it. These declarations must not
/// enable commands or bypass the independent BLE hardware acceptance gate.
public struct VehicleCapabilities: Codable, Equatable, Sendable {
    private let reportedSupport: [VehicleFeature: VehicleCapabilitySupport]

    public static let unknown = VehicleCapabilities()

    /// All known features in stable display order, including unreported ones.
    public var features: [VehicleFeatureCapability] {
        VehicleFeature.allCases.map { feature in
            VehicleFeatureCapability(
                feature: feature,
                support: reportedSupport[feature] ?? .unknown,
                wasReported: reportedSupport[feature] != nil
            )
        }
    }

    public var reportedFeatures: [VehicleFeatureCapability] {
        features.filter(\.wasReported)
    }

    public subscript(feature: VehicleFeature) -> VehicleCapabilitySupport {
        reportedSupport[feature] ?? .unknown
    }

    public init(funcConfig: JSONValue? = nil) {
        var support: [VehicleFeature: VehicleCapabilitySupport] = [:]
        guard let config = funcConfig?.objectValue else {
            reportedSupport = support
            return
        }

        for feature in VehicleFeature.allCases {
            // Lowercase HVAC is an existing upstream parser compatibility path.
            // A present uppercase value wins even if malformed; no optimistic
            // fallback to a conflicting alias is allowed.
            let raw = config[feature.rawValue] ?? (feature == .hvac ? config["hvac"] : nil)
            guard let raw else { continue }
            if case .bool(let supported)? = raw["supported"] {
                support[feature] = supported ? .supported : .unsupported
            } else {
                support[feature] = .unknown
            }
        }
        reportedSupport = support
    }

    public init(from decoder: Decoder) throws {
        self.init(funcConfig: try JSONValue(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try sanitizedFuncConfig.encode(to: encoder)
    }

    /// Re-encoding cannot reintroduce unrecognized fields or raw server values.
    /// An empty feature object preserves its reported-but-unconfirmed status.
    var sanitizedFuncConfig: JSONValue {
        var values: [String: JSONValue] = [:]
        for (feature, support) in reportedSupport {
            switch support {
            case .supported: values[feature.rawValue] = .object(["supported": .bool(true)])
            case .unsupported: values[feature.rawValue] = .object(["supported": .bool(false)])
            case .unknown: values[feature.rawValue] = .object([:])
            }
        }
        return .object(values)
    }
}
