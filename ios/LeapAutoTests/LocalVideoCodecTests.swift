#if canImport(VideoToolbox) && canImport(CoreVideo)
import XCTest
import CoreVideo
import LeapCore
@testable import LeapAuto

/// These tests require an actual Apple H.264 encoder and decoder. A failure or unsupported
/// runtime is reported as a failure, never replaced with a mock or claimed as device coverage.
@MainActor
final class LocalVideoCodecTests: XCTestCase {
    func testSyntheticSourceProducesExpectedPixelsAndChangingCounter() throws {
        let source = try SyntheticVideoFrameSource(configuration: .standard)
        let first = try source.makeFrame(sequence: 0)
        let second = try source.makeFrame(sequence: 1)
        XCTAssertTrue(SyntheticVideoFrameSource.matchesColorBars(first, configuration: .standard))
        XCTAssertTrue(SyntheticVideoFrameSource.matchesColorBars(second, configuration: .standard))
        XCTAssertFalse(SyntheticVideoFrameSource.matchesColorBars(first, configuration: .hd))
        XCTAssertNotEqual(try counterPixels(first), try counterPixels(second))
    }

    func testSyntheticPoolDoesNotAllocatePastBound() throws {
        let configuration = LocalVideoCodecConfiguration(maximumInFlightFrames: 1)
        let source = try SyntheticVideoFrameSource(configuration: configuration)
        let held = try (0..<2).map { try source.makeFrame(sequence: Int64($0)) }
        XCTAssertThrowsError(try source.makeFrame(sequence: 2))
        XCTAssertEqual(held.count, 2)
        withExtendedLifetime(held) {}
    }

    func testRealH264RoundTripHasDecodedPixelsAndFiniteStatistics() async throws {
        let model = LocalVideoCodecDiagnosticsModel()
        defer { model.stop() }
        let configuration = LocalVideoCodecConfiguration(framesPerSecond: 20, frameLimit: 12)
        model.start(configuration: configuration)
        try await waitUntilFinished(model)
        XCTAssertEqual(model.snapshot.phase, .completed, model.snapshot.errorMessage ?? "No codec error supplied")
        XCTAssertEqual(model.snapshot.submittedFrames, 12)
        XCTAssertEqual(model.snapshot.encodedFrames, 12)
        XCTAssertEqual(model.snapshot.decodedFrames, 12, "Only actual decoded and color-validated pixels count")
        XCTAssertGreaterThan(model.snapshot.encodedBytes, 0)
        XCTAssertEqual(model.snapshot.failedFrames, 0)
        XCTAssertEqual(model.snapshot.cancelledFrames, 0)
        XCTAssertEqual(model.snapshot.codecDrops, 0)
        XCTAssertEqual(model.snapshot.inFlightFrames, 0)
        XCTAssertLessThanOrEqual(model.snapshot.peakInFlightFrames, configuration.maximumInFlightFrames)
        XCTAssertTrue(model.snapshot.meanLatencyMilliseconds.isFinite)
        XCTAssertGreaterThan(model.snapshot.maximumLatencyMilliseconds, 0)
        let preview = try XCTUnwrap(model.preview)
        XCTAssertEqual(preview.width, configuration.width)
        XCTAssertEqual(preview.height, configuration.height)
    }

    func testRealCodecMakesProgressWithOnlyOneAdmissionSlot() async throws {
        let model = LocalVideoCodecDiagnosticsModel()
        defer { model.stop() }
        model.start(configuration: LocalVideoCodecConfiguration(framesPerSecond: 20,
            maximumInFlightFrames: 1, frameLimit: 6))
        try await waitUntilFinished(model)
        XCTAssertEqual(model.snapshot.phase, .completed, model.snapshot.errorMessage ?? "No codec error supplied")
        XCTAssertEqual(model.snapshot.decodedFrames, 6)
        XCTAssertEqual(model.snapshot.peakInFlightFrames, 1)
    }

    func testStopThenResizeRestartRejectsOldCallbacks() async throws {
        let model = LocalVideoCodecDiagnosticsModel()
        defer { model.stop() }
        model.start(configuration: LocalVideoCodecConfiguration(framesPerSecond: 30))
        try await waitForDecodedFrame(model)
        model.stop()
        XCTAssertFalse(model.isRunning)
        XCTAssertNil(model.preview)
        let resized = LocalVideoCodecConfiguration(width: 1280, height: 720,
            framesPerSecond: 20, bitRate: 2_000_000, frameLimit: 8)
        model.start(configuration: resized)
        try await waitUntilFinished(model)
        XCTAssertEqual(model.snapshot.phase, .completed, model.snapshot.errorMessage ?? "No codec error supplied")
        XCTAssertEqual(model.snapshot.decodedFrames, 8)
        XCTAssertEqual(model.snapshot.cancelledFrames, 0)
        XCTAssertEqual(model.preview?.width, 1280)
        XCTAssertEqual(model.preview?.height, 720)
    }

    func testRepeatedStartThenImmediateStopStaysStopped() async throws {
        let model = LocalVideoCodecDiagnosticsModel()
        for _ in 0..<5 {
            model.start()
            model.stop()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while model.isStopping && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(model.isStopping, "Stop must be acknowledged after native session cleanup")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(model.snapshot.phase, .stopped)
        XCTAssertNil(model.preview)
        XCTAssertEqual(model.snapshot.inFlightFrames, 0)
    }

    func testInvalidConfigurationReportsErrorWithoutCodecFrames() async throws {
        let model = LocalVideoCodecDiagnosticsModel()
        defer { model.stop() }
        model.start(configuration: LocalVideoCodecConfiguration(width: 641))
        try await waitUntilFinished(model)
        XCTAssertEqual(model.snapshot.phase, .failed)
        XCTAssertNotNil(model.snapshot.errorMessage)
        XCTAssertEqual(model.snapshot.submittedFrames, 0)
        XCTAssertNil(model.preview)
    }

    private func waitUntilFinished(_ model: LocalVideoCodecDiagnosticsModel) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        while model.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(model.isRunning, "Timed out waiting for real VideoToolbox callbacks")
    }

    private func waitForDecodedFrame(_ model: LocalVideoCodecDiagnosticsModel) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while model.snapshot.decodedFrames == 0 && model.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertGreaterThan(model.snapshot.decodedFrames, 0, model.snapshot.errorMessage ?? "No decoded frame")
    }

    private func counterPixels(_ buffer: CVPixelBuffer) throws -> [UInt8] {
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, .readOnly), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        return Array(UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self),
            count: CVPixelBufferGetBytesPerRow(buffer) * 56))
    }
}
#endif
