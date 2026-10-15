import Foundation
import XCTest
import LeapCore
@testable import LeapNativeCrypto

/// All keys/certificates here are public synthetic fixtures; no backend or BLE.
final class BLEOpenSSLCryptoTests: XCTestCase {
    private let provider = BLEOpenSSLSM2Provider()

    func testRealCurveOperationsMatchArchivedAndroidFixtures() throws {
        XCTAssertEqual(try provider.publicPoint(privateScalar: Fixture.scalar), Fixture.local)
        XCTAssertEqual(try provider.publicPoint(certificateDER: XCTUnwrap(Data(base64Encoded: Fixture.certificate))), Fixture.peer)
        XCTAssertEqual(try provider.multiplyScalarsModuloOrder(Fixture.localFactor, Fixture.scalar), Fixture.localFactor)
        XCTAssertEqual(try provider.multiply(point: Fixture.peer, scalar: Fixture.peerFactor), Fixture.peerProduct)
        XCTAssertEqual(try provider.multiply(point: Fixture.peerProduct, scalar: Fixture.localFactor), Fixture.shared)
    }

    func testCustomAgreementNowUsesRealNativeProvider() throws {
        let agreement = try BLEOfflineSM2.agree(encodedCertificate: Fixture.certificate,
                                                privateScalar: Fixture.scalar, provider: provider)
        XCTAssertEqual(agreement.publicKey, Fixture.local)
        XCTAssertEqual(agreement.sharedSecret, Fixture.secret)
        let session = try BLEOfflineSessionDerivation.sm2(sessionID: 0x78563412,
            vin: Fixture.vin, passwordCard: Fixture.card, sharedSecret: agreement.sharedSecret)
        XCTAssertEqual(session.key, Fixture.key)
        XCTAssertEqual(session.iv, Fixture.iv)
        XCTAssertEqual(try BLEOpenSSLCrypto.encryptSM4CBC(Data("0;locked;".utf8), key: session.key, iv: session.iv),
                       Data(base64Encoded: "Zjj+LKhmbzHq5pKtEMd63g=="))
    }

    func testFullOfflineAuthenticationUsesNativePointProvider() throws {
        let identity = BLESessionIdentity(accountID: "test-account", vin: Fixture.vin,
                                          generation: 1, deviceID: "test-device")
        let certificate = try BLEOfflineKeyCertificate(ecdhPublicKey: Fixture.certificate, keyType: 1,
            passwordCard: Fixture.card,
            plainText: "v1;old-account;old-device;TESTVIN0000000001;1700000000;1900000000",
            signResult: Data((1...16).map(UInt8.init)).base64EncodedString(), vin: Fixture.vin, binding: identity)
        let session = try BLEOfflineSM2Session.create(certificate: certificate, currentIdentity: identity,
            connectionGeneration: 7, sessionID: 0x78563412, privateScalar: Fixture.scalar, provider: provider)
        defer { session.close() }
        let frame = try session.buildAuthentication(currentIdentity: identity, connectionGeneration: 7,
            protocolMinor: 9, epochSeconds: 1_800_000_000, nowMilliseconds: 1_000, profile: .legacyVersioned)
        XCTAssertEqual(frame, Data(base64Encoded: Fixture.authentication9))
        XCTAssertEqual(session.phase, .authenticating)
        XCTAssertFalse(BLEHardwareFeatureGate.isEnabled)
    }

    func testCompressedPointsNormalizeAndSlicesWork() throws {
        let compressed = Data([UInt8(2 | (Fixture.peer.last! & 1))]) + Fixture.peer.dropFirst().prefix(32)
        XCTAssertEqual(try provider.multiply(point: compressed, scalar: Fixture.scalar), Fixture.peer)
        let slicedScalar = (Data([255]) + Fixture.scalar).dropFirst()
        XCTAssertEqual(try provider.publicPoint(privateScalar: slicedScalar), Fixture.local)
    }

    func testInvalidScalarAndPointInputsFailClosed() {
        for scalar in [Data(), Data(repeating: 0, count: 32), Data(repeating: 255, count: 32), Data([1])] {
            XCTAssertThrowsError(try provider.publicPoint(privateScalar: scalar))
        }
        for point in [Data(), Data([0]), Data(repeating: 0, count: 65), Data([4]) + Data(repeating: 255, count: 64)] {
            XCTAssertThrowsError(try provider.multiply(point: point, scalar: Fixture.scalar))
        }
    }

    func testCertificateTrailingBytesTruncationAndWrongContainerFail() throws {
        let der = try XCTUnwrap(Data(base64Encoded: Fixture.certificate))
        for value in [Data(), der + Data([0]), Data(der.dropLast()), Fixture.peer] {
            XCTAssertThrowsError(try provider.publicPoint(certificateDER: value))
        }
    }

    func testSM3MatchesStandardAndOfflineReferenceAtBoundaries() throws {
        XCTAssertEqual(try BLEOpenSSLCrypto.sm3(Data("abc".utf8)),
                       hex("66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0"))
        for length in [0, 1, 55, 56, 63, 64, 65, 127, 128, 129] {
            let bytes = sequence(length)
            XCTAssertEqual(try BLEOpenSSLCrypto.sm3(bytes), BLEOfflineSM3.hash(bytes))
        }
    }

    func testSM4MatchesReferenceAllPaddingWidthsAndBoundaryLengths() throws {
        for length in 1...65 {
            let bytes = sequence(length)
            let cipher = try BLEOpenSSLCrypto.encryptSM4CBC(bytes, key: Fixture.key, iv: Fixture.iv)
            XCTAssertEqual(cipher, try BLEOfflineSM4.encrypt(bytes, key: Fixture.key, iv: Fixture.iv))
            XCTAssertEqual(try BLEOpenSSLCrypto.decryptSM4CBC(cipher, key: Fixture.key, iv: Fixture.iv), bytes)
        }
    }

    func testSM4RejectsMalformedInputAndPadding() throws {
        XCTAssertThrowsError(try BLEOpenSSLCrypto.encryptSM4CBC(Data(), key: Fixture.key, iv: Fixture.iv))
        XCTAssertThrowsError(try BLEOpenSSLCrypto.encryptSM4CBC(Data([1]), key: Data(), iv: Fixture.iv))
        XCTAssertThrowsError(try BLEOpenSSLCrypto.decryptSM4CBC(Data([1]), key: Fixture.key, iv: Fixture.iv))
        // Changing IV's last byte turns the known 7-byte pad into a nonuniform pad.
        let cipher = try BLEOpenSSLCrypto.encryptSM4CBC(Data("0;locked;".utf8), key: Fixture.key, iv: Fixture.iv)
        var badIV = Fixture.iv; badIV[15] ^= 1
        XCTAssertThrowsError(try BLEOpenSSLCrypto.decryptSM4CBC(cipher, key: Fixture.key, iv: badIV))
    }

    func testErrorsContainNoInputAndHardwareRemainsDisabled() {
        let marker = "SYNTHETIC_SECRET_MARKER"
        do {
            _ = try provider.publicPoint(certificateDER: Data(marker.utf8))
            XCTFail("Malformed certificate accepted")
        } catch {
            XCTAssertFalse(String(reflecting: error).contains(marker))
            XCTAssertEqual(error as? BLENativeCryptoError, .operationFailed)
        }
        XCTAssertFalse(BLEHardwareFeatureGate.isEnabled)
    }
}

private enum Fixture {
    static let authentication9 = "qq7zABI0VngEMsSuLB8ZgRlfmQRGajnJlI/jC7/yZgvhcVpFiTNMdMe8Nzai9PZ3nFm9zuNraSFT0KmHfMYqR0AC3zLlITnwoFVzVEJGcTJZRkxla3JyT1I4K2gwNXI4V2ozTXRhdjFlWkl5c2RXY3FrN3Z1bzNWeUVHMWhhWGF2YWt4bGdZTytmbklndC9nWVZRTnZiMkR2Q0t2U2lRWERnVDEyNkI5V0YwVzNpUUE1L1N5bjZCeCtDeG44L2pGUndjNTdudFRCdWU5dE1pNDhTalN6YXpXNUVMSkc5YXpzRzdrOHhGQUtkM2dDV0x5aVV1RT0BCQ=="
    // Source: API/fixtures/bluetooth/generate-sm2-vectors.cjs,
    // independently generated with Node/OpenSSL. Scalars 1 and 2 are PUBLIC test values.
    static let local = hex("0432c4ae2c1f1981195f9904466a39c9948fe30bbff2660be1715a4589334c74c7bc3736a2f4f6779c59bdcee36b692153d0a9877cc62a474002df32e52139f0a0")
    static let peer = hex("0456cefd60d7c87c000d58ef57fa73ba4d9c0dfa08c08a7331495c2e1da3f2bd5231b7e7e6cc8189f668535ce0f8eaf1bd6de84c182f6c8e716f780d3a970a23c3")
    static let peerProduct = hex("04fbb85d6b85a3acc548169d33bb35d0ca46c3ea89dbeb1bbfd2c9d635d1f7c16569f24f6fac6e72d91d383f1d500f8658a8e8bee17e008b1cdc84ade6470f8d96")
    static let shared = hex("0484bc6a2aa48bb01a485d83f235d53780e1dff6f8d24cef22601959b93c48555372314b7108a7dc87d3a9cf66f946aa744cab7c3c3928abe9024ce6aa5a27b08b")
    static let scalar = Data(repeating: 0, count: 31) + Data([1])
    static let localFactor = hex("000000000000000000000000000000008fe30bbff2660be1715a4589334c74c8")
    static let peerFactor = hex("000000000000000000000000000000009c0dfa08c08a7331495c2e1da3f2bd53")
    static let secret = hex("5f86e6b17708f60dfb5d8e3f3ce2b35d3d29744d51c46fc14cdb7bb95fdaf48b")
    static let key = Data("6fa340d39f4141fe".utf8), iv = Data("437410132db0dd25".utf8)
    static let vin = "TESTVIN0000000001", card = String(repeating: "0123456789abcdef", count: 5)
    // Synthetic ASN.1 matching upstream tests; placeholder signature, NO CA trust claim.
    static let certificate = "MIHcMIHJoAMCAQICAQEwCgYIKoEcz1UBg3UwGzEZMBcGA1UEAwwQQkxFIE9mZmxpbmUgVGVzdDAeFw0yMzExMTQyMjEzMjBaFw0zMDAzMTcxNzQ2NDBaMBsxGTAXBgNVBAMMEEJMRSBPZmZsaW5lIFRlc3QwWTATBgcqhkjOPQIBBggqgRzPVQGCLQNCAARWzv1g18h8AA1Y71f6c7pNnA36CMCKczFJXC4do/K9UjG35+bMgYn2aFNc4Pjq8b1t6EwYL2yOcW94DTqXCiPDMAoGCCqBHM9VAYN1AwIAAQ=="
}

private func hex(_ value: String) -> Data {
    var bytes = [UInt8](), index = value.startIndex
    while index < value.endIndex {
        let next = value.index(index, offsetBy: 2)
        bytes.append(UInt8(value[index..<next], radix: 16)!); index = next
    }
    return Data(bytes)
}
private func sequence(_ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: $0) }) }
