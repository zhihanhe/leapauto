import Foundation
import CLeapNativeCrypto
import LeapCore

/// Native primitive adapter for isolated offline interoperability tests.
/// No I/O, credential provisioning, persistence, or hardware activation.
/// Swift Data copies are not guaranteed to be securely erased; this API is not
/// a production secret-lifetime container or a claim of independent audit.
public struct BLEOpenSSLSM2Provider: BLESM2Provider, Sendable {
    public init() {}

    public func publicPoint(certificateDER: Data) throws -> Data {
        try output(count: 65) { destination in
            certificateDER.withUnsafeBytes { source in
                leap_sm2_certificate_public_key(source.bindMemory(to: UInt8.self).baseAddress,
                                                certificateDER.count, destination)
            }
        }
    }

    public func publicPoint(privateScalar: Data) throws -> Data {
        guard privateScalar.count == 32 else { throw BLENativeCryptoError.invalidInput }
        return try output(count: 65) { destination in
            privateScalar.withUnsafeBytes { source in
                leap_sm2_public_key(source.bindMemory(to: UInt8.self).baseAddress, destination)
            }
        }
    }

    public func multiply(point: Data, scalar: Data) throws -> Data {
        guard scalar.count == 32 else { throw BLENativeCryptoError.invalidInput }
        return try output(count: 65) { destination in
            scalar.withUnsafeBytes { scalarBytes in
                point.withUnsafeBytes { pointBytes in
                    leap_sm2_multiply_point(scalarBytes.bindMemory(to: UInt8.self).baseAddress,
                                            pointBytes.bindMemory(to: UInt8.self).baseAddress,
                                            point.count, destination)
                }
            }
        }
    }

    public func multiplyScalarsModuloOrder(_ lhs: Data, _ rhs: Data) throws -> Data {
        guard lhs.count == 32, rhs.count == 32 else { throw BLENativeCryptoError.invalidInput }
        return try output(count: 32) { destination in
            lhs.withUnsafeBytes { left in
                rhs.withUnsafeBytes { right in
                    leap_sm2_multiply_scalars(left.bindMemory(to: UInt8.self).baseAddress,
                                             right.bindMemory(to: UInt8.self).baseAddress, destination)
                }
            }
        }
    }
}

/// Fixed, non-sensitive errors. Never include OpenSSL's error queue or inputs.
public enum BLENativeCryptoError: Error, Equatable, Sendable {
    case invalidInput
    case operationFailed
}

public enum BLEOpenSSLCrypto {
    public static func sm3(_ data: Data) throws -> Data {
        try output(count: 32) { destination in
            data.withUnsafeBytes { source in
                leap_sm3(source.bindMemory(to: UInt8.self).baseAddress, data.count, destination)
            }
        }
    }

    public static func encryptSM4CBC(_ data: Data, key: Data, iv: Data) throws -> Data {
        try crypt(data, key: key, iv: iv, encrypt: true)
    }

    public static func decryptSM4CBC(_ data: Data, key: Data, iv: Data) throws -> Data {
        try crypt(data, key: key, iv: iv, encrypt: false)
    }

    private static func crypt(_ data: Data, key: Data, iv: Data, encrypt: Bool) throws -> Data {
        // Bound allocations before entering C; BLE payloads are much smaller.
        guard key.count == 16, iv.count == 16, !data.isEmpty,
              data.count <= 1_048_576, encrypt || data.count % 16 == 0 else {
            throw BLENativeCryptoError.invalidInput
        }
        let capacity = data.count + 16
        var written = 0
        var result = Data(count: capacity)
        let status: Int32 = result.withUnsafeMutableBytes { destination in
            key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    data.withUnsafeBytes { source in
                        let k = keyBytes.bindMemory(to: UInt8.self).baseAddress
                        let v = ivBytes.bindMemory(to: UInt8.self).baseAddress
                        let s = source.bindMemory(to: UInt8.self).baseAddress
                        let d = destination.bindMemory(to: UInt8.self).baseAddress
                        if encrypt {
                            return leap_sm4_cbc_encrypt(k, v, s, data.count, d, capacity, &written)
                        }
                        return leap_sm4_cbc_decrypt(k, v, s, data.count, d, capacity, &written)
                    }
                }
            }
        }
        guard status == 1, written >= 0, written <= capacity else {
            result.resetBytes(in: 0..<result.count)
            throw BLENativeCryptoError.operationFailed
        }
        result.removeSubrange(written..<result.count)
        return result
    }
}

private func output(count: Int, operation: (UnsafeMutablePointer<UInt8>?) -> Int32) throws -> Data {
    var result = Data(count: count)
    let status = result.withUnsafeMutableBytes { destination in
        operation(destination.bindMemory(to: UInt8.self).baseAddress)
    }
    guard status == 1 else {
        result.resetBytes(in: 0..<result.count)
        throw BLENativeCryptoError.operationFailed
    }
    return result
}
