import Foundation
import CoreVideo
import LeapCore

/// A pull-source boundary for synthetic diagnostics. No ReplayKit session is created here.
/// A future capture adapter needs explicit user consent and its own bounded handoff.
protocol LocalVideoFrameSource: AnyObject {
    var configuration: LocalVideoCodecConfiguration { get }
    func makeFrame(sequence: Int64) throws -> CVPixelBuffer
}

enum LocalVideoCodecFailure: Error {
    case operation(String, Int32)
    case invalidFrame

    var message: String {
        switch self {
        case let .operation(stage, status): return "\(stage)失败（OSStatus \(status)）。"
        case .invalidFrame: return "图像缓冲区格式或尺寸不符合本机诊断要求。"
        }
    }
}

final class SyntheticVideoFrameSource: LocalVideoFrameSource {
    let configuration: LocalVideoCodecConfiguration
    private let pool: CVPixelBufferPool
    // BGRA in little-endian memory: white, yellow, cyan, green, magenta, red, blue, black.
    static let colors: [UInt32] = [0xffffffff, 0xffffff00, 0xff00ffff, 0xff00ff00,
                                   0xffff00ff, 0xffff0000, 0xff0000ff, 0xff000000]
    private static let digits: [[String]] = [
        ["111", "101", "101", "101", "111"], ["010", "110", "010", "010", "111"],
        ["111", "001", "111", "100", "111"], ["111", "001", "111", "001", "111"],
        ["101", "101", "111", "001", "001"], ["111", "100", "111", "001", "111"],
        ["111", "100", "111", "101", "111"], ["111", "001", "001", "001", "001"],
        ["111", "101", "111", "101", "111"], ["111", "101", "111", "001", "111"]
    ]

    init(configuration: LocalVideoCodecConfiguration) throws {
        guard configuration.validationError == nil else { throw LocalVideoCodecFailure.invalidFrame }
        self.configuration = configuration
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: configuration.width,
            kCVPixelBufferHeightKey as String: configuration.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        var created: CVPixelBufferPool?
        let result = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &created)
        guard result == kCVReturnSuccess, let created else {
            throw LocalVideoCodecFailure.operation("分配合成图像池", result)
        }
        pool = created
    }

    func makeFrame(sequence: Int64) throws -> CVPixelBuffer {
        var output: CVPixelBuffer?
        let limits = [kCVPixelBufferPoolAllocationThresholdKey as String:
                        configuration.maximumInFlightFrames + 1] as CFDictionary
        let result = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, limits, &output)
        guard result == kCVReturnSuccess, let output else {
            throw LocalVideoCodecFailure.operation("分配合成帧", result)
        }
        let lockResult = CVPixelBufferLockBaseAddress(output, [])
        guard lockResult == kCVReturnSuccess else { throw LocalVideoCodecFailure.operation("锁定合成帧", lockResult) }
        defer { CVPixelBufferUnlockBaseAddress(output, []) }
        guard let base = CVPixelBufferGetBaseAddress(output) else { throw LocalVideoCodecFailure.invalidFrame }
        let stride = CVPixelBufferGetBytesPerRow(output) / MemoryLayout<UInt32>.size
        let pixels = base.assumingMemoryBound(to: UInt32.self)
        let width = configuration.width, height = configuration.height
        for y in 0..<height {
            for x in 0..<width { pixels[y * stride + x] = Self.colors[min(7, x * 8 / width)] }
        }
        // Small bitmap counter, drawn only into synthetic pixels. No fonts, files or screen content.
        let scale = max(1, min(width / 80, height / 25))
        let text = String(format: "%06lld", sequence % 1_000_000)
        for y in 0..<min(height, 7 * scale) {
            for x in 0..<min(width, 26 * scale) { pixels[y * stride + x] = 0xff202020 }
        }
        for (index, character) in text.enumerated() {
            guard let value = character.wholeNumberValue else { continue }
            for (row, line) in Self.digits[value].enumerated() {
                for (column, bit) in line.enumerated() where bit == "1" {
                    for sy in 0..<scale {
                        for sx in 0..<scale {
                            let x = (1 + index * 4 + column) * scale + sx
                            let y = (1 + row) * scale + sy
                            if x < width && y < height { pixels[y * stride + x] = 0xffffffff }
                        }
                    }
                }
            }
        }
        return output
    }

    /// Check actual decompressed pixels, with a generous tolerance for lossy H.264 / color conversion.
    static func matchesColorBars(_ buffer: CVPixelBuffer, configuration: LocalVideoCodecConfiguration) -> Bool {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetWidth(buffer) == configuration.width,
              CVPixelBufferGetHeight(buffer) == configuration.height,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let row = (configuration.height / 2) * CVPixelBufferGetBytesPerRow(buffer)
        for bar in 0..<8 {
            let x = (2 * bar + 1) * configuration.width / 16
            let expected = colors[bar]
            for channel in 0..<3 {
                let component = Int((expected >> (channel * 8)) & 0xff)
                if abs(Int(bytes[row + x * 4 + channel]) - component) > 48 { return false }
            }
        }
        return true
    }
}
