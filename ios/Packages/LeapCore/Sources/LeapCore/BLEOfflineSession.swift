import Foundation

public enum BLEOfflineSessionError: Error, Equatable, Sendable {
    case invalidIdentity, identityChanged, unsupportedKeyType, invalidCertificate
    case invalidBase64, invalidCalibration, invalidTimestamp, invalidState
    case confirmationRequired, closed
}

/// Immutable protocol fields plus the identity of the certificate request. Binding
/// metadata is local only and MUST come from that request, never an advertisement.
/// This type does not validate CA trust, expiry, revocation or account entitlement.
public struct BLEOfflineKeyCertificate: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let ecdhPublicKey: String
    public let keyType: Int
    public let passwordCard: String
    public let plainText: String
    public let signResult: String
    public let vin: String
    public let binding: BLESessionIdentity

    public init(ecdhPublicKey: String, keyType: Int, passwordCard: String,
                plainText: String, signResult: String, vin: String, binding: BLESessionIdentity) throws {
        try BLEOfflineSessionBytes.validateIdentity(binding)
        guard keyType == 1 else { throw BLEOfflineSessionError.unsupportedKeyType }
        guard vin == binding.vin, !ecdhPublicKey.isEmpty, ecdhPublicKey.utf8.count <= 131_072,
              (80...4_096).contains(passwordCard.utf8.count), passwordCard.utf8.allSatisfy({ $0 <= 127 }),
              !plainText.isEmpty, plainText.utf8.count <= 32_768,
              !plainText.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              plainText.components(separatedBy: ";").count >= 6,
              !signResult.isEmpty, signResult.utf8.count <= 32_768 else {
            throw BLEOfflineSessionError.invalidCertificate
        }
        _ = try BLEOfflineSessionBytes.base64(signResult)
        self.ecdhPublicKey = ecdhPublicKey; self.keyType = keyType; self.passwordCard = passwordCard
        self.plainText = plainText; self.signResult = signResult; self.vin = vin; self.binding = binding
    }
    public var description: String { "BLEOfflineKeyCertificate(redacted, offline-only)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<Mirror.Child>()) }
}

public enum BLEOfflineAuthenticationProfile: Equatable, Sendable {
    /// Retains all proof fields and varies manual flags by advertised protocol minor.
    case legacyVersioned
    /// Recovered Android source default: exactly six proof fields and four flags.
    /// Selecting it is a fixture choice, not proof of C10 interoperability.
    case onePaoV010
}

/// Raw protocol calibration. Units/physical thresholds remain unverified.
public struct BLEOfflineCalibration: Equatable, Sendable {
    public let distance: UInt8
    public let coefficientHundredths: UInt16
    public let unlock: UInt8
    public let lock: UInt8
    public init(distance: Int, coefficientHundredths: Int, unlock: Int, lock: Int) throws {
        guard let distance = UInt8(exactly: distance), let coefficient = UInt16(exactly: coefficientHundredths),
              let unlock = UInt8(exactly: unlock), let lock = UInt8(exactly: lock) else {
            throw BLEOfflineSessionError.invalidCalibration
        }
        self.distance = distance; self.coefficientHundredths = coefficient; self.unlock = unlock; self.lock = lock
    }
    public static let standard = try! Self(distance: 56, coefficientHundredths: 200, unlock: 8, lock: 16)
    public static let c10C16 = try! Self(distance: 69, coefficientHundredths: 100, unlock: 4, lock: 21)
    public var protocolText: String {
        func two(_ value: Int) -> String { value < 10 ? "0\(value)" : String(value) }
        return "\(distance);\(coefficientHundredths / 100).\(two(Int(coefficientHundredths % 100)));\(two(Int(unlock)));\(two(Int(lock)))"
    }
}

public enum BLEOfflineSessionPhase: Equatable, Sendable { case prepared, authenticating, authenticated, commandPending, closed }
public enum BLEOfflineSessionEvent: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case ignored, authenticationAcknowledged, authenticationTimedOut
    case response(BLEResponse), rejected(UInt8), commandOutcome(BLECommandOutcome)
    public var description: String { "BLEOfflineSessionEvent(redacted, offline-only)" }
    public var debugDescription: String { description }
}

/// Deterministic OFFLINE state machine and SM4 frame construction. No RNG, key
/// persistence, CoreBluetooth or production-crypto claim. A fresh instance is
/// required per connection; never reuse supplied fixture scalars/session IDs live.
///
/// Single-owner reference semantics avoid accidentally copying a reusable session.
/// The caller must serialize access. A protocol authentication reply is not CA
/// trust: CBC is unauthenticated and hardware acceptance remains separately closed.
public final class BLEOfflineSM2Session: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public static let authenticationTimeoutMilliseconds: Int64 = 8_000
    public private(set) var phase: BLEOfflineSessionPhase = .prepared
    /// Retained even if closure was caused by a thrown crypto/context error. A
    /// caller must not reinterpret an uncertain written command as safely not sent.
    public private(set) var terminalCommandOutcome: BLECommandOutcome?
    private let identity: BLESessionIdentity
    private let connectionGeneration: UInt64
    private let sessionID: UInt32
    private var certificate: BLEOfflineKeyCertificate?
    private var publicKey: Data
    private var key: Data
    private var iv: Data
    private var writesStarted = false, writesCompleted = false, authenticationReply = false
    private var startedAt: Int64 = 0, deadline: Int64 = 0
    private var lastObservedAt: Int64?
    private var command = BLECommandTracker()

    public static func create(certificate: BLEOfflineKeyCertificate, currentIdentity: BLESessionIdentity,
                              connectionGeneration: UInt64, sessionID: UInt32, privateScalar: Data,
                              provider: any BLESM2Provider = BLEUnavailableSM2Provider()) throws -> BLEOfflineSM2Session {
        try BLEOfflineSessionBytes.validateIdentity(currentIdentity)
        guard certificate.binding.matches(currentIdentity) else { throw BLEOfflineSessionError.identityChanged }
        let agreement = try BLEOfflineSM2.agree(encodedCertificate: certificate.ecdhPublicKey,
                                               privateScalar: privateScalar, provider: provider)
        let material = try BLEOfflineSessionDerivation.sm2(sessionID: sessionID, vin: currentIdentity.vin,
            passwordCard: certificate.passwordCard, sharedSecret: agreement.sharedSecret)
        return BLEOfflineSM2Session(certificate: certificate, identity: currentIdentity,
            connectionGeneration: connectionGeneration, sessionID: sessionID, publicKey: agreement.publicKey, material: material)
    }

    private init(certificate: BLEOfflineKeyCertificate, identity: BLESessionIdentity, connectionGeneration: UInt64,
                 sessionID: UInt32, publicKey: Data, material: BLEOfflineSessionMaterial) {
        self.certificate = certificate; self.identity = identity; self.connectionGeneration = connectionGeneration
        self.sessionID = sessionID; self.publicKey = publicKey; key = material.key; iv = material.iv
    }

    /// Manual-only settings: master enabled, passive unlock/lock and button off.
    /// The immutable captured certificate cannot be swapped after key derivation.
    public func buildAuthentication(currentIdentity: BLESessionIdentity, connectionGeneration: UInt64,
                                    protocolMinor: UInt8, epochSeconds: Int64, nowMilliseconds: Int64,
                                    profile: BLEOfflineAuthenticationProfile,
                                    calibration: BLEOfflineCalibration = .standard) throws -> Data {
        try requireContext(currentIdentity, connectionGeneration)
        guard phase == .prepared, let certificate else { throw BLEOfflineSessionError.invalidState }
        try BLEOfflineSessionBytes.validateTime(epochSeconds)
        try BLEOfflineSessionBytes.validateDeadline(nowMilliseconds, Self.authenticationTimeoutMilliseconds)
        var fields = certificate.plainText.components(separatedBy: ";")
        fields[1] = identity.accountID; fields[2] = identity.deviceID
        if profile == .onePaoV010 { fields = Array(fields.prefix(6)) }
        let flags = profile == .onePaoV010 || protocolMinor >= 9 ? "1;0;0;0;" : "0;0;"
        let text = Data("\(epochSeconds);\(fields.joined(separator: ";"));\(calibration.protocolText);\(flags)".utf8)
        let signature = try BLEOfflineSessionBytes.base64(certificate.signResult)
        let plain = BLEOfflineSessionBytes.littleEndian(UInt64(text.count), size: 4) + text + signature
        // Bound the padded/Base64 output before encrypting or allocating a frame.
        let encodedSize = ((plain.count / 16 + 1) * 16 + 2) / 3 * 4
        guard encodedSize + 71 <= 65_535 else { throw BLEProtocolError.frameTooLarge }
        let encrypted = try encrypt(plain).base64EncodedData()
        let payload = BLEOfflineSessionBytes.littleEndian(UInt64(sessionID), size: 4) + publicKey + encrypted + Data([1, 9])
        let frame = Data([0xAA, 0xAE]) + BLEOfflineSessionBytes.littleEndian(UInt64(payload.count), size: 2) + payload
        try observeTime(nowMilliseconds)
        startedAt = nowMilliseconds; deadline = nowMilliseconds + Self.authenticationTimeoutMilliseconds
        phase = .authenticating
        return frame
    }

    public func markAuthenticationWriteStarted(currentIdentity: BLESessionIdentity, connectionGeneration: UInt64,
                                                nowMilliseconds: Int64) throws {
        try requireContext(currentIdentity, connectionGeneration)
        try requirePendingTime(nowMilliseconds)
        guard phase == .authenticating else { throw BLEOfflineSessionError.invalidState }
        writesStarted = true
    }

    /// A GATT ACK alone never advances authentication. A valid decrypted type-0
    /// response and completion of this exact authentication write are both required.
    @discardableResult public func markAuthenticationWritesCompleted(currentIdentity: BLESessionIdentity,
        connectionGeneration: UInt64, nowMilliseconds: Int64) throws -> Bool {
        try requireContext(currentIdentity, connectionGeneration)
        try requirePendingTime(nowMilliseconds)
        guard phase == .authenticating, writesStarted else { throw BLEOfflineSessionError.invalidState }
        writesCompleted = true
        return finishAuthenticationIfReady()
    }

    public func receive(_ frame: BLEFrame, currentIdentity: BLESessionIdentity, connectionGeneration: UInt64,
                        nowMilliseconds: Int64) throws -> BLEOfflineSessionEvent {
        try requireContext(currentIdentity, connectionGeneration)
        if phase == .authenticating || phase == .commandPending {
            if let expired = try expire(nowMilliseconds: nowMilliseconds) { return expired }
        } else { try observeTime(nowMilliseconds) }
        if frame.type == .event {
            let event = BLEKeyProtocol.parseEvent(frame)
            if case .rejected(let code) = event {
                let outcome = close()
                return outcome.map { .commandOutcome($0) } ?? .rejected(code)
            }
            if phase == .commandPending, let outcome = command.receive(event, nowMilliseconds: nowMilliseconds) {
                terminalCommandOutcome = outcome
                close(); return .commandOutcome(outcome)
            }
            return .ignored
        }
        guard frame.type == .encrypted else { return .ignored }
        guard phase == .authenticating || phase == .authenticated || phase == .commandPending else { return .ignored }
        let response: BLEResponse
        do {
            guard frame.payload.count <= BLEKeyProtocol.maximumFrameSize - 6,
                  let encoded = String(data: frame.payload, encoding: .ascii) else { throw BLEOfflineSessionError.invalidBase64 }
            let ciphertext = try BLEOfflineSessionBytes.base64(encoded.trimmingCharacters(in: .whitespacesAndNewlines))
            let plain = try BLEOfflineSM4.decrypt(ciphertext, key: key, iv: iv)
            response = try BLEKeyProtocol.parseDecryptedResponse(plain)
        } catch { close(); throw error }
        if case .authenticated = response {
            guard phase == .authenticating, writesStarted else { return .ignored }
            authenticationReply = true
            return finishAuthenticationIfReady() ? .authenticationAcknowledged : .ignored
        }
        // Reconnect credentials are deliberately discarded: no persistence or
        // adoption of unbound fast-reconnect secrets in this manual-only port.
        if case .reconnectCredential = response { return .ignored }
        return .response(response)
    }

    public func buildCommand(_ confirmation: BLEControlConfirmation, currentIdentity: BLESessionIdentity,
                             connectionGeneration: UInt64, foreground: Bool, managementVisible: Bool,
                             epochSeconds: Int64, nowMilliseconds: Int64) throws -> Data {
        try requireContext(currentIdentity, connectionGeneration)
        guard phase == .authenticated else { throw BLEOfflineSessionError.invalidState }
        guard confirmation.isCurrent(identity: currentIdentity, connectionGeneration: connectionGeneration,
            foreground: foreground, authenticated: true, managementVisible: managementVisible) else {
            throw BLEOfflineSessionError.confirmationRequired
        }
        try BLEOfflineSessionBytes.validateTime(epochSeconds)
        try BLEOfflineSessionBytes.validateDeadline(nowMilliseconds, BLECommandTracker.confirmationTimeoutMilliseconds)
        try observeTime(nowMilliseconds)
        let body = BLEOfflineSessionBytes.littleEndian(UInt64(epochSeconds), size: 8) + Data([confirmation.action.rawValue])
        let payload = try encrypt(Data([BLEKeyProtocol.crc8(body)]) + body).base64EncodedData()
        let frame = Data([0xAA, 0xAB]) + BLEOfflineSessionBytes.littleEndian(UInt64(payload.count), size: 4) + payload
        guard try command.begin(confirmation.action, nowMilliseconds: nowMilliseconds) else { throw BLEOfflineSessionError.invalidState }
        startedAt = nowMilliseconds; deadline = nowMilliseconds + BLECommandTracker.confirmationTimeoutMilliseconds
        phase = .commandPending
        return frame
    }

    public func markCommandWriteStarted(currentIdentity: BLESessionIdentity, connectionGeneration: UInt64,
                                         nowMilliseconds: Int64) throws {
        try requireContext(currentIdentity, connectionGeneration)
        try requirePendingTime(nowMilliseconds)
        guard phase == .commandPending else { throw BLEOfflineSessionError.invalidState }
        command.markWriteStarted()
    }

    /// Poll using a monotonic clock. Expiry is exclusive; backwards time fails closed.
    public func expire(nowMilliseconds: Int64) throws -> BLEOfflineSessionEvent? {
        guard phase == .authenticating || phase == .commandPending else { return nil }
        try observeTime(nowMilliseconds)
        guard nowMilliseconds >= startedAt else { close(); throw BLEProtocolError.invalidClock }
        guard nowMilliseconds >= deadline else { return nil }
        let wasAuthentication = phase == .authenticating
        let outcome = close()
        return wasAuthentication ? .authenticationTimedOut : outcome.map { .commandOutcome($0) }
    }

    /// Returns notSent/unknown for an interrupted command, never retries it.
    @discardableResult public func close() -> BLECommandOutcome? {
        let outcome = command.end()
        if let outcome { terminalCommandOutcome = outcome }
        phase = .closed; certificate = nil
        // Best-effort disposal only. Swift/Foundation copies cannot be guaranteed erased.
        key.resetBytes(in: 0..<key.count); key.removeAll(keepingCapacity: false)
        iv.resetBytes(in: 0..<iv.count); iv.removeAll(keepingCapacity: false)
        publicKey.resetBytes(in: 0..<publicKey.count); publicKey.removeAll(keepingCapacity: false)
        writesStarted = false; writesCompleted = false; authenticationReply = false; startedAt = 0; deadline = 0
        return outcome
    }
    deinit { close() }
    public var description: String { "BLEOfflineSM2Session(redacted, offline-only)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<Mirror.Child>()) }

    private func requireContext(_ currentIdentity: BLESessionIdentity, _ generation: UInt64) throws {
        guard phase != .closed else { throw BLEOfflineSessionError.closed }
        guard identity.matches(currentIdentity), generation == connectionGeneration else {
            close(); throw BLEOfflineSessionError.identityChanged
        }
    }
    private func requirePendingTime(_ now: Int64) throws {
        try observeTime(now)
        guard (phase == .authenticating || phase == .commandPending), now >= startedAt, now < deadline else {
            close(); throw BLEProtocolError.invalidClock
        }
    }
    private func observeTime(_ now: Int64) throws {
        guard now >= 0, lastObservedAt.map({ now >= $0 }) ?? true else {
            close(); throw BLEProtocolError.invalidClock
        }
        lastObservedAt = now
    }
    private func finishAuthenticationIfReady() -> Bool {
        guard phase == .authenticating, writesStarted, writesCompleted, authenticationReply else { return false }
        phase = .authenticated; startedAt = 0; deadline = 0
        return true
    }
    private func encrypt(_ value: Data) throws -> Data { try BLEOfflineSM4.encrypt(value, key: key, iv: iv) }
}

private enum BLEOfflineSessionBytes {
    static func validateIdentity(_ identity: BLESessionIdentity) throws {
        guard identity.generation >= 0, identity.matches(identity),
              [identity.accountID, identity.deviceID].allSatisfy({ value in
                  value.utf8.count <= 1_024 && !value.contains(";") &&
                      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
              }), identity.vin.utf8.count <= 128,
              identity.vin.utf8.allSatisfy({ (33...126).contains($0) && $0 != 59 }) else {
            throw BLEOfflineSessionError.invalidIdentity
        }
    }
    static func validateTime(_ value: Int64) throws {
        guard value >= 0 else { throw BLEOfflineSessionError.invalidTimestamp }
    }
    static func validateDeadline(_ now: Int64, _ duration: Int64) throws {
        guard now >= 0, now <= Int64.max - duration else { throw BLEProtocolError.invalidClock }
    }
    static func littleEndian(_ value: UInt64, size: Int) -> Data {
        Data((0..<size).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    /// Standard Base64 only. Like Java's decoder, omitted terminal padding is
    /// accepted; embedded whitespace, extra padding and URL alphabet are rejected.
    static func base64(_ value: String) throws -> Data {
        let bytes = Array(value.utf8), body = Array(value.utf8.prefix { $0 != 61 })
        let padding = bytes.count - body.count, needed = (4 - body.count % 4) % 4
        guard !body.isEmpty, body.count % 4 != 1, padding <= 2,
              bytes.suffix(padding).allSatisfy({ $0 == 61 }), padding == 0 || padding == needed,
              body.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 43 || $0 == 47 }),
              let decoded = Data(base64Encoded: Data(body + Array(repeating: UInt8(61), count: needed))), !decoded.isEmpty else {
            throw BLEOfflineSessionError.invalidBase64
        }
        return decoded
    }
}
