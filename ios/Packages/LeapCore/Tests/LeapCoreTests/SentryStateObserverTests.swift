import XCTest
@testable import LeapCore

final class SentryStateObserverTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func status(_ enabled: Bool?, source: Date?) -> VehicleStatus {
        var signals: [String: JSONValue] = [:]
        if let enabled { signals["3636"] = .number(enabled ? 1 : 0) }
        if let source { signals["sts"] = .number(source.timeIntervalSince1970 * 1000) }
        return VehicleStatus(raw: .object(["signalMap": .object(signals)]), receivedAt: now)
    }

    func testConfirmationRequiresNewFreshExplicitTargetForBothDirections() {
        let baseline = now.addingTimeInterval(-20)
        let newer = now.addingTimeInterval(-10)
        for target in [true, false] {
            let confirmation = SentryStateConfirmation(targetEnabled: target, baselineTimestamp: baseline)
            XCTAssertTrue(confirmation.isConfirmed(by: status(target, source: newer), at: now))
            for rejected in [status(!target, source: newer), status(nil, source: newer),
                             status(target, source: nil), status(target, source: baseline),
                             status(target, source: baseline.addingTimeInterval(-1)),
                             status(target, source: now.addingTimeInterval(1))] {
                XCTAssertFalse(confirmation.isConfirmed(by: rejected, at: now))
            }
            let oldBaseline = SentryStateConfirmation(targetEnabled: target, baselineTimestamp: now.addingTimeInterval(-400))
            XCTAssertFalse(oldBaseline.isConfirmed(by: status(target, source: now.addingTimeInterval(-301)), at: now))
            XCTAssertFalse(SentryStateConfirmation(targetEnabled: target, baselineTimestamp: nil)
                .isConfirmed(by: status(target, source: newer), at: now))
        }
    }

    func testDelayedTargetStopsAtFirstMatchingNewSourceTime() async throws {
        let baseline = now.addingTimeInterval(-20)
        let probe = SentryObservationProbe([
            status(false, source: baseline), status(true, source: baseline),
            status(true, source: now.addingTimeInterval(-10)), status(false, source: now)
        ])
        let instant = now
        let outcome = try await SentryStateObserver.observe(
            confirmation: .init(targetEnabled: true, baselineTimestamp: baseline),
            policy: .init(timeout: 1, initialDelay: 0.001, interval: 0.001),
            deadline: .init(timeout: 1), now: { instant },
            refresh: { try await probe.next() }, onObservation: { await probe.record($0) })
        XCTAssertEqual(outcome, .confirmed)
        let counts = await probe.counts()
        XCTAssertEqual(counts.reads, 3)
        XCTAssertEqual(counts.published, 3)
    }

    func testUnchangedTargetTimesOutWithoutFurtherReads() async throws {
        let baseline = now.addingTimeInterval(-20)
        let probe = SentryObservationProbe([status(true, source: baseline)])
        let instant = now
        let outcome = try await SentryStateObserver.observe(
            confirmation: .init(targetEnabled: true, baselineTimestamp: baseline),
            policy: .init(timeout: 0.08, initialDelay: 0.001, interval: 1),
            deadline: .init(timeout: 0.08), now: { instant },
            refresh: { try await probe.next() }, onObservation: { await probe.record($0) })
        XCTAssertEqual(outcome, .timedOut)
        try await Task.sleep(for: .milliseconds(10))
        let counts = await probe.counts()
        XCTAssertEqual(counts.reads, 1)
        XCTAssertEqual(counts.published, 1)
    }

    func testExhaustedOriginalDeadlineNeverStartsTelemetryRead() async throws {
        let probe = SentryObservationProbe([])
        let deadline = ControlObservationDeadline(timeout: 0.005)
        // The result stage has already consumed the shared budget.
        try await Task.sleep(for: .milliseconds(20))
        let outcome = try await SentryStateObserver.observe(
            confirmation: .init(targetEnabled: true, baselineTimestamp: now), deadline: deadline,
            refresh: { try await probe.next() })
        XCTAssertEqual(outcome, .timedOut)
        let counts = await probe.counts()
        XCTAssertEqual(counts.reads, 0)
    }

    func testReadFailurePropagatesWithoutRetry() async throws {
        let probe = SentryObservationProbe([])
        do {
            _ = try await SentryStateObserver.observe(
                confirmation: .init(targetEnabled: true, baselineTimestamp: now), deadline: .init(timeout: 1),
                refresh: { try await probe.next() })
            XCTFail("Read errors must be surfaced independently of the verified result")
        } catch { XCTAssertEqual(error as? LeapAPIError, .networkUnavailable) }
        let counts = await probe.counts()
        XCTAssertEqual(counts.reads, 1)
    }

    func testNonCooperativeLateReadCannotPublishAfterDeadline() async throws {
        let probe = SentryObservationProbe([])
        let baseline = now.addingTimeInterval(-20)
        let observation = Task {
            try await SentryStateObserver.observe(
                confirmation: .init(targetEnabled: true, baselineTimestamp: baseline), deadline: .init(timeout: 0.08),
                refresh: { await probe.suspend() }, onObservation: { await probe.record($0) })
        }
        let suspended = await waitUntilSuspended(probe)
        XCTAssertTrue(suspended)
        let outcome = try await observation.value
        XCTAssertEqual(outcome, .timedOut)
        await probe.release(status(true, source: now.addingTimeInterval(-10)))
        try await Task.sleep(for: .milliseconds(10))
        let counts = await probe.counts()
        XCTAssertEqual(counts.reads, 1)
        XCTAssertEqual(counts.published, 0)
    }

    func testCancellationRejectsNonCooperativeLateRead() async throws {
        let probe = SentryObservationProbe([])
        let baseline = now.addingTimeInterval(-20)
        let observation = Task {
            try await SentryStateObserver.observe(
                confirmation: .init(targetEnabled: true, baselineTimestamp: baseline), deadline: .init(timeout: 5),
                refresh: { await probe.suspend() }, onObservation: { await probe.record($0) })
        }
        let suspended = await waitUntilSuspended(probe)
        XCTAssertTrue(suspended)
        observation.cancel()
        do { _ = try await observation.value; XCTFail("Cancellation must throw") }
        catch { XCTAssertTrue(error is CancellationError) }
        await probe.release(status(true, source: now.addingTimeInterval(-10)))
        try await Task.sleep(for: .milliseconds(10))
        let counts = await probe.counts()
        XCTAssertEqual(counts.reads, 1)
        XCTAssertEqual(counts.published, 0)
    }

    private func waitUntilSuspended(_ probe: SentryObservationProbe) async -> Bool {
        for _ in 0..<1000 {
            if await probe.isSuspended { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }
}

private actor SentryObservationProbe {
    private var replies: [VehicleStatus]
    private var reads = 0
    private var published = 0
    private var continuation: CheckedContinuation<VehicleStatus, Never>?
    var isSuspended: Bool { continuation != nil }

    init(_ replies: [VehicleStatus]) { self.replies = replies }
    func next() throws -> VehicleStatus {
        reads += 1
        guard !replies.isEmpty else { throw LeapAPIError.networkUnavailable }
        return replies.removeFirst()
    }
    func record(_ status: VehicleStatus) { published += 1 }
    func counts() -> (reads: Int, published: Int) { (reads, published) }
    func suspend() async -> VehicleStatus {
        reads += 1
        return await withCheckedContinuation { continuation = $0 }
    }
    func release(_ status: VehicleStatus) {
        continuation?.resume(returning: status)
        continuation = nil
    }
}
