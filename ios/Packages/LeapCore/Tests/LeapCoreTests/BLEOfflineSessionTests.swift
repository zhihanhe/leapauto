import Foundation
import XCTest
@testable import LeapCore

final class BLEOfflineSessionTests: XCTestCase {
    func testDefaultSM2BackendAndHardwareFailClosed() throws {
        XCTAssertFalse(BLEHardwareFeatureGate.isEnabled)
        XCTAssertThrowsError(try BLEOfflineSM2Session.create(certificate: fixtureCertificate(), currentIdentity: identity,
            connectionGeneration: 7, sessionID: 0x78563412, privateScalar: SessionFixture.scalar)) {
            XCTAssertEqual($0 as? BLECryptoError, .sm2BackendUnavailable)
        }
    }

    func testAuthenticationMatchesIndependentLegacyMinorEightAndNineVectors() throws {
        for (minor, expected) in [(UInt8(8), SessionFixture.authentication8), (9, SessionFixture.authentication9)] {
            let session = try makeSession()
            XCTAssertEqual(try authentication(session, minor: minor), Data(base64Encoded: expected))
            XCTAssertEqual(session.phase, .authenticating)
        }
    }

    func testC10FixedLayoutUsesExplicitCalibrationAndManualOnlyFlags() throws {
        for minor: UInt8 in [0, 8, 9, 255] {
            let session = try makeSession()
            XCTAssertEqual(try authentication(session, minor: minor, profile: .onePaoV010, calibration: .c10C16),
                           Data(base64Encoded: SessionFixture.onePaoC10))
        }
        XCTAssertEqual(BLEOfflineCalibration.c10C16.protocolText, "69;1.00;04;21")
    }

    func testLegacyRetainsExtraAndEmptyProofFieldsWhileFixedLayoutUsesSix() throws {
        let certificate = try fixtureCertificate(text: SessionFixture.proof + ";extra;;")
        XCTAssertEqual(try authentication(makeSession(certificate), minor: 8), Data(base64Encoded: SessionFixture.legacyExtraFields))
        XCTAssertEqual(try authentication(makeSession(certificate), minor: 8, profile: .onePaoV010),
                       Data(base64Encoded: SessionFixture.authentication9))
    }

    func testEmptyAccountAndDeviceProofPlaceholdersAreReplacedFromBoundIdentity() throws {
        let text = SessionFixture.proof.replacingOccurrences(of: "old-account;old-device", with: ";")
        XCTAssertEqual(try authentication(makeSession(fixtureCertificate(text: text)), minor: 9),
                       Data(base64Encoded: SessionFixture.authentication9))
    }

    func testCertificateCreationRequiresBoundIdentityAndSM2KeyType() throws {
        for changed in changedIdentities {
            XCTAssertThrowsError(try BLEOfflineSM2Session.create(certificate: fixtureCertificate(), currentIdentity: changed,
                connectionGeneration: 7, sessionID: 0, privateScalar: SessionFixture.scalar, provider: SessionFixtureProvider()))
        }
        XCTAssertThrowsError(try fixtureCertificate(type: 0))
        XCTAssertThrowsError(try fixtureCertificate(vin: "OTHER"))
        for bad in ["", "a;b", "\nname", String(repeating: "a", count: 1_025)] {
            let invalid = BLESessionIdentity(accountID: bad, vin: identity.vin, generation: 1, deviceID: "device")
            XCTAssertThrowsError(try fixtureCertificate(binding: invalid))
        }
        let negative = BLESessionIdentity(accountID: "a", vin: identity.vin, generation: -1, deviceID: "d")
        XCTAssertThrowsError(try fixtureCertificate(binding: negative))
    }

    func testMalformedProofSignatureAndCardAreRejected() throws {
        for text in ["", "v1;one;two", SessionFixture.proof + "\n", String(repeating: "x", count: 32_769)] {
            XCTAssertThrowsError(try fixtureCertificate(text: text))
        }
        for signature in ["", "%%%", "AQ==junk", "AQ===", "AQ=", "A", " AQ==", "AQ\n==", "AA-_"] {
            XCTAssertThrowsError(try fixtureCertificate(signature: signature))
        }
        for card in ["", String(repeating: "x", count: 79), String(repeating: "x", count: 4_097), String(repeating: "🙂", count: 80)] {
            XCTAssertThrowsError(try fixtureCertificate(card: card))
        }
        XCTAssertNoThrow(try fixtureCertificate(signature: "AQ"))
    }

    func testOversizedAuthFrameIsRejectedBeforeStateChanges() throws {
        let certificate = try fixtureCertificate(text: SessionFixture.proof + ";" + String(repeating: "x", count: 32_000),
                                                  signature: Data(repeating: 1, count: 24_000).base64EncodedString())
        let session = try makeSession(certificate)
        XCTAssertThrowsError(try authentication(session)) { XCTAssertEqual($0 as? BLEProtocolError, .frameTooLarge) }
        XCTAssertEqual(session.phase, .prepared)
    }

    func testCalibrationUsesProtocolWidthsAndLocaleIndependentDecimalText() throws {
        XCTAssertEqual(try BLEOfflineCalibration(distance: 255, coefficientHundredths: 65_535, unlock: 0, lock: 255).protocolText,
                       "255;655.35;00;255")
        for values in [(-1, 0, 0, 0), (256, 0, 0, 0), (0, -1, 0, 0), (0, 65_536, 0, 0), (0, 0, 256, 0), (0, 0, 0, -1)] {
            XCTAssertThrowsError(try BLEOfflineCalibration(distance: values.0, coefficientHundredths: values.1,
                                                           unlock: values.2, lock: values.3))
        }
    }

    func testWritesAloneCannotAuthenticateAndAuthAttemptCannotBeRepeated() throws {
        let session = try makeSession(); _ = try authentication(session)
        try started(session)
        XCTAssertFalse(try writesComplete(session))
        XCTAssertEqual(session.phase, .authenticating)
        XCTAssertThrowsError(try authentication(session))
        XCTAssertEqual(try receive(session, SessionFixture.authReply), .authenticationAcknowledged)
        XCTAssertEqual(session.phase, .authenticated)
        XCTAssertEqual(try receive(session, SessionFixture.authReply), .ignored)
    }

    func testResponseBeforeWriteStartedCannotAuthenticate() throws {
        let session = try makeSession(); _ = try authentication(session)
        XCTAssertEqual(try receive(session, SessionFixture.authReply), .ignored)
        try started(session); XCTAssertFalse(try writesComplete(session))
        XCTAssertEqual(session.phase, .authenticating)
    }

    func testResponseBeforeFinalGattACKWaitsForBothEvidencePaths() throws {
        let session = try makeSession(); _ = try authentication(session); try started(session)
        XCTAssertEqual(try receive(session, SessionFixture.authReply), .ignored)
        XCTAssertEqual(session.phase, .authenticating)
        XCTAssertTrue(try writesComplete(session))
        XCTAssertEqual(session.phase, .authenticated)
    }

    func testUnknownAndReconnectRepliesCannotAuthenticateOrPersistCredentials() throws {
        let session = try makeSession(); _ = try authentication(session); try started(session); _ = try writesComplete(session)
        XCTAssertEqual(try receive(session, "aaab18000000726e6b436878633845583564777443465767634e52673d3d"), .response(.unknown))
        XCTAssertEqual(try receive(session, "aaab18000000523555335a59674c6961396c477564472b577a3070773d3d"), .ignored)
        XCTAssertEqual(session.phase, .authenticating)
    }

    func testMalformedCiphertextBase64AndUTF8CloseSession() throws {
        for bytes in ["aaab0400000059513d3d", "aaab0400000025252525",
                      "aaab1800000042366f694b4c7473546a6744764231564770684141773d3d",
                      "aaab18000000414141414141414141414141414141414141414141413d3d"] {
            let session = try makeSession(); _ = try authentication(session); try started(session)
            XCTAssertThrowsError(try receive(session, bytes)); XCTAssertEqual(session.phase, .closed)
        }
    }

    func testAuthenticationDeadlineIsExclusiveAndClockRollbackClosesSession() throws {
        let session = try makeSession(); _ = try authentication(session); try started(session)
        XCTAssertNil(try session.expire(nowMilliseconds: 8_099))
        XCTAssertEqual(try session.expire(nowMilliseconds: 8_100), .authenticationTimedOut)
        XCTAssertEqual(session.phase, .closed)
        let rollback = try makeSession(); _ = try authentication(rollback); try started(rollback)
        XCTAssertThrowsError(try rollback.expire(nowMilliseconds: 99)); XCTAssertEqual(rollback.phase, .closed)
    }

    func testLateAuthenticationReplyNeverSucceeds() throws {
        let session = try makeSession(); _ = try authentication(session); try started(session); _ = try writesComplete(session)
        XCTAssertEqual(try receive(session, SessionFixture.authReply, now: 8_100), .authenticationTimedOut)
        XCTAssertEqual(session.phase, .closed)
    }

    func testIdentityAndConnectionGenerationChangeClosesAllSessionPhases() throws {
        for changed in changedIdentities {
            let session = try makeSession(); _ = try authentication(session)
            XCTAssertThrowsError(try session.markAuthenticationWriteStarted(currentIdentity: changed, connectionGeneration: 7, nowMilliseconds: 101))
            XCTAssertEqual(session.phase, .closed)
        }
        let session = try authenticatedSession()
        XCTAssertThrowsError(try session.receive(frame(SessionFixture.authReply), currentIdentity: identity, connectionGeneration: 8, nowMilliseconds: 102))
        XCTAssertEqual(session.phase, .closed)
    }

    func testNegativeTimestampAndOverflowingClockDoNotConsumeAuthAttempt() throws {
        let session = try makeSession()
        for (epoch, now) in [(Int64(-1), Int64(100)), (1, -1), (1, Int64.max)] {
            XCTAssertThrowsError(try session.buildAuthentication(currentIdentity: identity, connectionGeneration: 7, protocolMinor: 9,
                epochSeconds: epoch, nowMilliseconds: now, profile: .onePaoV010))
            XCTAssertEqual(session.phase, .prepared)
        }
        XCTAssertNoThrow(try authentication(session))
    }

    func testCommandsMatchIndependentOpenSSLFramesAfterBoundAuthentication() throws {
        for (action, expected) in [(BLELockAction.unlock, SessionFixture.unlock), (.lock, SessionFixture.lock)] {
            let session = try authenticatedSession()
            XCTAssertEqual(try command(session, action: action), sessionHex(expected))
            XCTAssertEqual(session.phase, .commandPending)
            XCTAssertThrowsError(try command(session, action: action))
        }
    }

    func testCommandRequiresAuthenticationCurrentConfirmationAndVisibleForeground() throws {
        let unauthenticated = try makeSession()
        XCTAssertThrowsError(try command(unauthenticated))
        for (foreground, visible) in [(false, true), (true, false)] {
            let session = try authenticatedSession()
            XCTAssertThrowsError(try session.buildCommand(confirmation(), currentIdentity: identity, connectionGeneration: 7,
                foreground: foreground, managementVisible: visible, epochSeconds: 1_800_000_000, nowMilliseconds: 102))
            XCTAssertEqual(session.phase, .authenticated)
        }
        let session = try authenticatedSession()
        XCTAssertThrowsError(try session.buildCommand(confirmation(generation: 6), currentIdentity: identity, connectionGeneration: 7,
            foreground: true, managementVisible: true, epochSeconds: 1_800_000_000, nowMilliseconds: 102))
        XCTAssertThrowsError(try session.buildCommand(BLEControlConfirmation(action: .unlock, identity: changedIdentities[0], connectionGeneration: 7),
            currentIdentity: identity, connectionGeneration: 7, foreground: true, managementVisible: true,
            epochSeconds: 1_800_000_000, nowMilliseconds: 102))
    }

    func testOnlyActiveMatchingEventAfterWriteCanConfirmAndConnectionIsClosed() throws {
        let session = try authenticatedSession(); _ = try command(session)
        XCTAssertEqual(try receive(session, "aaac00000002030000007c0101", now: 102), .ignored)
        try session.markCommandWriteStarted(currentIdentity: identity, connectionGeneration: 7, nowMilliseconds: 102)
        for event in ["aaac00000002030000007c0201", "aaac00000002030000007c0102"] {
            XCTAssertEqual(try receive(session, event, now: 103), .ignored)
        }
        XCTAssertEqual(try receive(session, "aaab18000000574e444634653936644c36785a554e69672b634131513d3d", now: 103),
                       .response(.commandResult(identifier: "3", result: "00")))
        XCTAssertEqual(try receive(session, "aaac00000002030000007c0101", now: 103), .commandOutcome(.confirmed))
        XCTAssertEqual(session.phase, .closed)
        XCTAssertEqual(session.terminalCommandOutcome, .confirmed)
        XCTAssertThrowsError(try command(session))
    }

    func testUncertainCommandsAreNeverRetriedAndDisconnectDistinguishesNotSent() throws {
        for started in [false, true] {
            let session = try authenticatedSession(); _ = try command(session)
            if started { try session.markCommandWriteStarted(currentIdentity: identity, connectionGeneration: 7, nowMilliseconds: 102) }
            XCTAssertEqual(session.close(), started ? .unknown : .notSent)
            XCTAssertNil(session.close())
            XCTAssertThrowsError(try command(session))
        }
        let session = try authenticatedSession(); _ = try command(session)
        try session.markCommandWriteStarted(currentIdentity: identity, connectionGeneration: 7, nowMilliseconds: 102)
        XCTAssertEqual(try receive(session, "aaac00000002030000007c0101", now: 6_102), .commandOutcome(.unknown))
        XCTAssertEqual(session.phase, .closed)
    }

    func testRejectionClosesWithoutInventingMeaningForResultCodeNine() throws {
        let session = try makeSession(); _ = try authentication(session)
        XCTAssertEqual(try receive(session, "aaac000000010100000009"), .rejected(9))
        XCTAssertEqual(session.phase, .closed)
    }

    func testCommandRejectionPreservesNotSentOrUnknownWithoutRetry() throws {
        for started in [false, true] {
            let session = try authenticatedSession(); _ = try command(session)
            if started { try session.markCommandWriteStarted(currentIdentity: identity, connectionGeneration: 7, nowMilliseconds: 102) }
            XCTAssertEqual(try receive(session, "aaac000000010100000009", now: 103),
                           .commandOutcome(started ? .unknown : .notSent))
            XCTAssertEqual(session.phase, .closed)
        }
    }

    func testThrownCiphertextFailureRetainsTerminalCommandOutcome() throws {
        for started in [false, true] {
            let session = try authenticatedSession(); _ = try command(session)
            if started { try session.markCommandWriteStarted(currentIdentity: identity, connectionGeneration: 7, nowMilliseconds: 102) }
            XCTAssertThrowsError(try receive(session, "aaab0400000025252525", now: 103))
            XCTAssertEqual(session.phase, .closed)
            XCTAssertEqual(session.terminalCommandOutcome, started ? .unknown : .notSent)
            XCTAssertNil(session.close())
            XCTAssertEqual(session.terminalCommandOutcome, started ? .unknown : .notSent)
        }
    }

    func testIdentityChangeRetainsUncertainWrittenCommandOutcome() throws {
        let session = try authenticatedSession(); _ = try command(session)
        try session.markCommandWriteStarted(currentIdentity: identity, connectionGeneration: 7, nowMilliseconds: 102)
        XCTAssertThrowsError(try session.receive(frame(SessionFixture.authReply), currentIdentity: changedIdentities[0],
                                                connectionGeneration: 7, nowMilliseconds: 103))
        XCTAssertEqual(session.phase, .closed)
        XCTAssertEqual(session.terminalCommandOutcome, .unknown)
    }

    func testClockMustRemainMonotonicAcrossAuthenticationAndCommand() throws {
        let session = try authenticatedSession()
        XCTAssertThrowsError(try session.buildCommand(confirmation(), currentIdentity: identity, connectionGeneration: 7,
            foreground: true, managementVisible: true, epochSeconds: 1_800_000_000, nowMilliseconds: 99))
        XCTAssertEqual(session.phase, .closed)
    }

    func testSecretBearingTypesRedactDescriptionAndReflection() throws {
        let certificate = try fixtureCertificate(), session = try makeSession(certificate)
        for value: Any in [certificate, session] {
            XCTAssertTrue(String(describing: value).contains("redacted"))
            XCTAssertTrue(String(reflecting: value).contains("redacted"))
            XCTAssertTrue(Mirror(reflecting: value).children.isEmpty)
        }
        XCTAssertFalse(String(describing: BLEOfflineSessionEvent.response(.authenticated(lockState: "secret"))).contains("secret"))
    }
}

private let identity = BLESessionIdentity(accountID: "test-account", vin: "TESTVIN0000000001", generation: 1, deviceID: "test-device")
private let changedIdentities = [
    BLESessionIdentity(accountID: "other-account", vin: identity.vin, generation: 1, deviceID: identity.deviceID),
    BLESessionIdentity(accountID: identity.accountID, vin: "OTHER", generation: 1, deviceID: identity.deviceID),
    BLESessionIdentity(accountID: identity.accountID, vin: identity.vin, generation: 2, deviceID: identity.deviceID),
    BLESessionIdentity(accountID: identity.accountID, vin: identity.vin, generation: 1, deviceID: "other-device")
]
private func fixtureCertificate(text: String = SessionFixture.proof, signature: String = "AQIDBAUGBwgJCgsMDQ4PEA==",
                                card: String = String(repeating: "0123456789abcdef", count: 5),
                                type: Int = 1, vin: String = identity.vin, binding: BLESessionIdentity = identity) throws -> BLEOfflineKeyCertificate {
    try BLEOfflineKeyCertificate(ecdhPublicKey: SessionFixture.certificate, keyType: type, passwordCard: card,
        plainText: text, signResult: signature, vin: vin, binding: binding)
}
private func makeSession(_ certificate: BLEOfflineKeyCertificate? = nil) throws -> BLEOfflineSM2Session {
    try BLEOfflineSM2Session.create(certificate: certificate ?? fixtureCertificate(), currentIdentity: identity,
        connectionGeneration: 7, sessionID: 0x78563412, privateScalar: SessionFixture.scalar, provider: SessionFixtureProvider())
}
@discardableResult private func authentication(_ session: BLEOfflineSM2Session, minor: UInt8 = 9,
    profile: BLEOfflineAuthenticationProfile = .legacyVersioned, calibration: BLEOfflineCalibration = .standard) throws -> Data {
    try session.buildAuthentication(currentIdentity: identity, connectionGeneration: 7, protocolMinor: minor,
        epochSeconds: 1_800_000_000, nowMilliseconds: 100, profile: profile, calibration: calibration)
}
private func started(_ session: BLEOfflineSM2Session) throws {
    try session.markAuthenticationWriteStarted(currentIdentity: identity, connectionGeneration: 7, nowMilliseconds: 101)
}
@discardableResult private func writesComplete(_ session: BLEOfflineSM2Session) throws -> Bool {
    try session.markAuthenticationWritesCompleted(currentIdentity: identity, connectionGeneration: 7, nowMilliseconds: 101)
}
private func frame(_ hex: String) throws -> BLEFrame {
    var decoder = try BLEFrameDecoder()
    return try XCTUnwrap(decoder.append(sessionHex(hex)).first)
}
private func receive(_ session: BLEOfflineSM2Session, _ hex: String, now: Int64 = 101) throws -> BLEOfflineSessionEvent {
    try session.receive(frame(hex), currentIdentity: identity, connectionGeneration: 7, nowMilliseconds: now)
}
private func authenticatedSession() throws -> BLEOfflineSM2Session {
    let session = try makeSession(); _ = try authentication(session); try started(session); _ = try writesComplete(session)
    XCTAssertEqual(try receive(session, SessionFixture.authReply), .authenticationAcknowledged)
    return session
}
private func confirmation(action: BLELockAction = .unlock, generation: UInt64 = 7) -> BLEControlConfirmation {
    BLEControlConfirmation(action: action, identity: identity, connectionGeneration: generation)
}
private func command(_ session: BLEOfflineSM2Session, action: BLELockAction = .unlock) throws -> Data {
    try session.buildCommand(confirmation(action: action), currentIdentity: identity, connectionGeneration: 7,
        foreground: true, managementVisible: true, epochSeconds: 1_800_000_000, nowMilliseconds: 102)
}

/// Exact synthetic replay only. This fixture is intentionally not a crypto backend.
private struct SessionFixtureProvider: BLESM2Provider {
    func publicPoint(certificateDER: Data) throws -> Data {
        guard certificateDER == Data(base64Encoded: SessionFixture.certificate) else { throw BLECryptoError.invalidCertificateEncoding }
        return SessionFixture.peer
    }
    func publicPoint(privateScalar: Data) throws -> Data {
        guard privateScalar == SessionFixture.scalar else { throw BLECryptoError.invalidPrivateScalar }
        return SessionFixture.local
    }
    func multiplyScalarsModuloOrder(_ lhs: Data, _ rhs: Data) throws -> Data {
        guard lhs == SessionFixture.localFactor, rhs == SessionFixture.scalar else { throw BLECryptoError.invalidProviderResult }
        return SessionFixture.localFactor
    }
    func multiply(point: Data, scalar: Data) throws -> Data {
        if point == SessionFixture.peer, scalar == SessionFixture.peerFactor { return SessionFixture.peerProduct }
        if point == SessionFixture.peerProduct, scalar == SessionFixture.localFactor { return SessionFixture.shared }
        throw BLECryptoError.invalidProviderResult
    }
}

private func sessionHex(_ text: String) -> Data {
    let bytes = Array(text.utf8)
    func digit(_ byte: UInt8) -> UInt8 { byte <= 57 ? byte - 48 : byte - 87 }
    return Data(stride(from: 0, to: bytes.count, by: 2).map { digit(bytes[$0]) << 4 | digit(bytes[$0 + 1]) })
}

private enum SessionFixture {
    // Source: API/fixtures/bluetooth/generate-sm2-vectors.cjs,
    // independently generated with Node/OpenSSL. Scalars 1 and 2 are PUBLIC test values.
    static let local = sessionHex("0432c4ae2c1f1981195f9904466a39c9948fe30bbff2660be1715a4589334c74c7bc3736a2f4f6779c59bdcee36b692153d0a9877cc62a474002df32e52139f0a0")
    static let peer = sessionHex("0456cefd60d7c87c000d58ef57fa73ba4d9c0dfa08c08a7331495c2e1da3f2bd5231b7e7e6cc8189f668535ce0f8eaf1bd6de84c182f6c8e716f780d3a970a23c3")
    static let peerProduct = sessionHex("04fbb85d6b85a3acc548169d33bb35d0ca46c3ea89dbeb1bbfd2c9d635d1f7c16569f24f6fac6e72d91d383f1d500f8658a8e8bee17e008b1cdc84ade6470f8d96")
    static let shared = sessionHex("0484bc6a2aa48bb01a485d83f235d53780e1dff6f8d24cef22601959b93c48555372314b7108a7dc87d3a9cf66f946aa744cab7c3c3928abe9024ce6aa5a27b08b")
    static let scalar = Data(repeating: 0, count: 31) + Data([1])
    static let localFactor = sessionHex("000000000000000000000000000000008fe30bbff2660be1715a4589334c74c8")
    static let peerFactor = sessionHex("000000000000000000000000000000009c0dfa08c08a7331495c2e1da3f2bd53")
    static let secret = sessionHex("5f86e6b17708f60dfb5d8e3f3ce2b35d3d29744d51c46fc14cdb7bb95fdaf48b")
    static let key = Data("6fa340d39f4141fe".utf8), iv = Data("437410132db0dd25".utf8)
    static let vin = "TESTVIN0000000001", card = String(repeating: "0123456789abcdef", count: 5)
    // Synthetic ASN.1 matching upstream tests; placeholder signature, NO CA trust claim.
    static let certificate = "MIHcMIHJoAMCAQICAQEwCgYIKoEcz1UBg3UwGzEZMBcGA1UEAwwQQkxFIE9mZmxpbmUgVGVzdDAeFw0yMzExMTQyMjEzMjBaFw0zMDAzMTcxNzQ2NDBaMBsxGTAXBgNVBAMMEEJMRSBPZmZsaW5lIFRlc3QwWTATBgcqhkjOPQIBBggqgRzPVQGCLQNCAARWzv1g18h8AA1Y71f6c7pNnA36CMCKczFJXC4do/K9UjG35+bMgYn2aFNc4Pjq8b1t6EwYL2yOcW94DTqXCiPDMAoGCCqBHM9VAYN1AwIAAQ=="
    static let proof = "v1;old-account;old-device;TESTVIN0000000001;1700000000;1900000000"
    static let authentication8 = "qq7zABI0VngEMsSuLB8ZgRlfmQRGajnJlI/jC7/yZgvhcVpFiTNMdMe8Nzai9PZ3nFm9zuNraSFT0KmHfMYqR0AC3zLlITnwoHk4SVRiLzFHUUFNVzhyOHh1MWYxWDNpeStOUWxNZ2Z4M2loMjhTRlZwTkZWT0tEZnYxbVFlRjd4ajJhTWg3MDkzVDRMRXZmbDEzcGgzek14SEFEQ1d0TDVTOXQyNHV6eWtOb0ZRNEd3dUluVlRid0hKdHpId2t5b0Y0cFBnRjhTNzhzVFNIVXpmaW5DS2JNc0FMa2l3aUJLNmllelNUaGJDUTZnZ2IxK0EzOD0BCQ=="
    static let authentication9 = "qq7zABI0VngEMsSuLB8ZgRlfmQRGajnJlI/jC7/yZgvhcVpFiTNMdMe8Nzai9PZ3nFm9zuNraSFT0KmHfMYqR0AC3zLlITnwoFVzVEJGcTJZRkxla3JyT1I4K2gwNXI4V2ozTXRhdjFlWkl5c2RXY3FrN3Z1bzNWeUVHMWhhWGF2YWt4bGdZTytmbklndC9nWVZRTnZiMkR2Q0t2U2lRWERnVDEyNkI5V0YwVzNpUUE1L1N5bjZCeCtDeG44L2pGUndjNTdudFRCdWU5dE1pNDhTalN6YXpXNUVMSkc5YXpzRzdrOHhGQUtkM2dDV0x5aVV1RT0BCQ=="
    static let unlock = "aaab1800000065447542464750772f3477547866484335386b3336773d3d"
    static let lock = "aaab18000000594c565a4144765a4155776d6433354a394855584e773d3d"
    static let authReply = "aaab180000005a6a6a2b4c4b686d627a487135704b74454d643633673d3d"
    static let onePaoC10 = "qq7zABI0VngEMsSuLB8ZgRlfmQRGajnJlI/jC7/yZgvhcVpFiTNMdMe8Nzai9PZ3nFm9zuNraSFT0KmHfMYqR0AC3zLlITnwoFVzVEJGcTJZRkxla3JyT1I4K2gwNXI4V2ozTXRhdjFlWkl5c2RXY3FrN3Z1bzNWeUVHMWhhWGF2YWt4bGdZTytmbklndC9nWVZRTnZiMkR2Q0t2U2lRWERnVDEyNkI5V0YwVzNpUUE1L1N6LzlaUEwwRHBBWm5zMkorei82RXhtSmllNjR4bUpzcTRmTFF6YTh6cFRJRGdiQ2Y2VmF3bTBuTnp3NnN4cUxEND0BCQ=="
    static let legacyExtraFields = "qq7zABI0VngEMsSuLB8ZgRlfmQRGajnJlI/jC7/yZgvhcVpFiTNMdMe8Nzai9PZ3nFm9zuNraSFT0KmHfMYqR0AC3zLlITnwoFJvVklqZ0dSQ1FQcUtBcmpFaExWdTVCSFE2Y1JwbFl0MjZhQ2RBTzBHYlprMU12UGhKNkZsUGpwbGl1WXVFYndUbThTU0hmREYwbHNyZ2p1UmJqMmdJSTJ6bmJvbmdZZTFUWTN4bUlkVHpxckFBRngwQ0luTTZjSE5mN2Z5SDBDTktiWkJaVmJSemdvTnVUNGZhYmVVb2x3UEVPRWdWT1V5VXVpMTI2N2dXYz0BCQ=="
}
