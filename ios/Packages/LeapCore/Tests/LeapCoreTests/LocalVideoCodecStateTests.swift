import XCTest
@testable import LeapCore

final class LocalVideoCodecStateTests: XCTestCase {
    func testConfigurationBoundsRejectBeforeStarting() {
        let invalid = [
            LocalVideoCodecConfiguration(width: 0), LocalVideoCodecConfiguration(width: 641),
            LocalVideoCodecConfiguration(height: Int.max), LocalVideoCodecConfiguration(framesPerSecond: 0),
            LocalVideoCodecConfiguration(framesPerSecond: 31), LocalVideoCodecConfiguration(bitRate: -1),
            LocalVideoCodecConfiguration(maximumInFlightFrames: 0), LocalVideoCodecConfiguration(maximumInFlightFrames: 9),
            LocalVideoCodecConfiguration(frameLimit: 0), LocalVideoCodecConfiguration(frameLimit: 1801)
        ]
        for configuration in invalid {
            var state = LocalVideoCodecState()
            XCTAssertFalse(state.begin(runID: UUID(), configuration: configuration))
            XCTAssertEqual(state.snapshot.phase, .failed)
            XCTAssertNotNil(state.snapshot.errorMessage)
            XCTAssertNil(state.admit(at: 0))
        }
        XCTAssertNil(LocalVideoCodecConfiguration.standard.validationError)
        XCTAssertNil(LocalVideoCodecConfiguration.hd.validationError)
    }

    func testBackpressureRemainsBoundedThroughEncodingAndDecoding() throws {
        var state = running(maximumInFlightFrames: 2)
        let first = try XCTUnwrap(state.admit(at: 0))
        let second = try XCTUnwrap(state.admit(at: 0.01))
        for _ in 0..<1000 { XCTAssertNil(state.admit(at: 0.02)) }
        XCTAssertTrue(state.encoded(first, byteCount: 100))
        XCTAssertNil(state.admit(at: 0.03), "Encoding completion must not release capacity")
        XCTAssertEqual(state.snapshot.inFlightFrames, 2)
        XCTAssertEqual(state.snapshot.peakInFlightFrames, 2)
        XCTAssertEqual(state.snapshot.backpressureDrops, 1001)
        XCTAssertTrue(state.decoded(first, at: 0.04))
        XCTAssertNotNil(state.admit(at: 0.05))
        XCTAssertTrue(state.isPending(second))
    }

    func testOldAndDuplicateCallbacksCannotModifyNewRun() throws {
        var state = running()
        let old = try XCTUnwrap(state.admit(at: 0))
        state.stop()
        XCTAssertFalse(state.encoded(old, byteCount: 1))
        state.begin(runID: UUID(), configuration: .hd)
        let current = try XCTUnwrap(state.admit(at: 1))
        let snapshot = state.snapshot
        XCTAssertFalse(state.encoded(old, byteCount: 1))
        XCTAssertFalse(state.drop(old))
        XCTAssertFalse(state.fail(old))
        XCTAssertFalse(state.decoded(old, at: 2))
        XCTAssertEqual(state.snapshot, snapshot)
        XCTAssertTrue(state.encoded(current, byteCount: 100))
        XCTAssertFalse(state.encoded(current, byteCount: 100))
        XCTAssertTrue(state.decoded(current, at: 1.1))
        XCTAssertFalse(state.decoded(current, at: 1.2))
        XCTAssertFalse(state.drop(current))
        XCTAssertEqual(state.snapshot.decodedFrames, 1)
    }

    func testStopAndRestartResetCountersDimensionsAndCapacity() throws {
        var state = running()
        _ = try XCTUnwrap(state.admit(at: 0))
        state.stop()
        state.stop()
        XCTAssertEqual(state.snapshot.phase, .stopped)
        XCTAssertEqual(state.snapshot.cancelledFrames, 1)
        XCTAssertEqual(state.snapshot.inFlightFrames, 0)
        XCTAssertNil(state.admit(at: 1))
        XCTAssertTrue(state.begin(runID: UUID(), configuration: .hd))
        XCTAssertEqual(state.configuration.width, 1280)
        XCTAssertEqual(state.snapshot.cancelledFrames, 0)
        XCTAssertEqual(state.snapshot.submittedFrames, 0)
        XCTAssertEqual(state.admit(at: 2)?.sequence, 0)
    }

    func testLatencyAndByteStatisticsUseOnlySuccessfulDecodes() throws {
        var state = running()
        let first = try XCTUnwrap(state.admit(at: 10))
        let second = try XCTUnwrap(state.admit(at: 10))
        XCTAssertFalse(state.decoded(first, at: 10.01), "Decode cannot precede encode")
        XCTAssertFalse(state.encoded(first, byteCount: 0))
        XCTAssertTrue(state.encoded(first, byteCount: 100))
        XCTAssertTrue(state.encoded(second, byteCount: 200))
        XCTAssertFalse(state.decoded(first, at: .nan))
        XCTAssertFalse(state.decoded(first, at: 9))
        XCTAssertTrue(state.decoded(first, at: 10.01))
        XCTAssertTrue(state.decoded(second, at: 10.03))
        XCTAssertEqual(state.snapshot.encodedBytes, 300)
        XCTAssertEqual(state.snapshot.meanLatencyMilliseconds, 20, accuracy: 0.0001)
        XCTAssertEqual(state.snapshot.maximumLatencyMilliseconds, 30, accuracy: 0.0001)
    }

    func testDropsAndFailuresReleaseExactlyOneSlot() throws {
        var state = running()
        let first = try XCTUnwrap(state.admit(at: 0))
        let second = try XCTUnwrap(state.admit(at: 0))
        XCTAssertTrue(state.drop(first))
        XCTAssertFalse(state.drop(first))
        XCTAssertTrue(state.fail(second))
        XCTAssertFalse(state.fail(second))
        XCTAssertEqual(state.snapshot.codecDrops, 1)
        XCTAssertEqual(state.snapshot.failedFrames, 1)
        XCTAssertEqual(state.snapshot.inFlightFrames, 0)
    }

    func testWatchdogDoesNotReleaseCapacityUntilWholeRunStops() throws {
        var state = running(maximumInFlightFrames: 1)
        _ = try XCTUnwrap(state.admit(at: 10))
        XCTAssertFalse(state.hasTimedOut(at: 12.99, timeout: 3))
        XCTAssertTrue(state.hasTimedOut(at: 13, timeout: 3))
        XCTAssertNil(state.admit(at: 13))
        state.stop(error: "视频处理超时。")
        XCTAssertEqual(state.snapshot.phase, .failed)
        XCTAssertEqual(state.snapshot.cancelledFrames, 1)
        XCTAssertFalse(state.hasTimedOut(at: 20, timeout: 3))
    }

    func testFrameLimitRequiresDrainBeforeCompletion() throws {
        var state = running(frameLimit: 1)
        let ticket = try XCTUnwrap(state.admit(at: 0))
        XCTAssertTrue(state.sourceLimitReached)
        XCTAssertFalse(state.isDrained)
        XCTAssertNil(state.admit(at: 0.01))
        XCTAssertEqual(state.snapshot.attemptedFrames, 1)
        XCTAssertTrue(state.encoded(ticket, byteCount: 1))
        XCTAssertTrue(state.decoded(ticket, at: 0.02))
        XCTAssertTrue(state.isDrained)
        state.stop(completed: true)
        XCTAssertEqual(state.snapshot.phase, .completed)
        XCTAssertEqual(state.snapshot.cancelledFrames, 0)
        // An explicit stop may race a completion update waiting on the main thread.
        state.stop()
        XCTAssertEqual(state.snapshot.phase, .stopped)
        XCTAssertEqual(state.snapshot.cancelledFrames, 0)
    }

    func testCannotClaimCompletionByCancellingPendingFrames() throws {
        var state = running(frameLimit: 1)
        _ = try XCTUnwrap(state.admit(at: 0))
        state.stop(completed: true)
        XCTAssertEqual(state.snapshot.phase, .stopped)
        XCTAssertEqual(state.snapshot.cancelledFrames, 1)
    }

    func testInvalidClockValuesCannotCreateOrExpireFrames() {
        var state = running()
        XCTAssertNil(state.admit(at: .nan))
        XCTAssertNil(state.admit(at: .infinity))
        XCTAssertFalse(state.hasTimedOut(at: .infinity, timeout: 3))
        XCTAssertFalse(state.hasTimedOut(at: 0, timeout: -1))
        XCTAssertEqual(state.snapshot.attemptedFrames, 0)
    }

    private func running(maximumInFlightFrames: Int = 3, frameLimit: Int = 300) -> LocalVideoCodecState {
        var state = LocalVideoCodecState()
        XCTAssertTrue(state.begin(runID: UUID(), configuration: LocalVideoCodecConfiguration(
            maximumInFlightFrames: maximumInFlightFrames, frameLimit: frameLimit)))
        return state
    }
}
