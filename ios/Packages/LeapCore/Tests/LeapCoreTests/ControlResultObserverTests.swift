import XCTest
@testable import LeapCore

private actor PollProbe {
    private(set) var calls = 0
    private(set) var cancelled = false
    private var replies: [ControlPollResult]
    init(_ replies: [ControlPollResult] = []) { self.replies = replies }
    func next() -> ControlPollResult {
        calls += 1
        return replies.isEmpty ? .pending : replies.removeFirst()
    }
    func delay() async throws -> ControlPollResult {
        calls += 1
        do {
            try await Task.sleep(for: .seconds(5))
            return .succeeded
        } catch { cancelled = true; throw error }
    }
}

final class ControlResultObserverTests: XCTestCase {
    private let quick = ControlPollingPolicy(timeout: 0.06, initialDelay: 0.001, interval: 0.001)

    func testAlreadyCancelledCallerDoesNotStartARead() async throws {
        let probe = PollProbe([.succeeded])
        let gate = CancellationGate()
        let observation = Task {
            await gate.wait()
            return try await ControlResultObserver.observe(policy: quick) { await probe.next() }
        }
        observation.cancel()
        await gate.release()
        do { _ = try await observation.value; XCTFail("Already cancelled caller must throw") }
        catch { XCTAssertTrue(error is CancellationError) }
        let calls = await probe.calls
        XCTAssertEqual(calls, 0)
    }

    func testZeroBudgetNeverStartsARead() async throws {
        let probe = PollProbe([.succeeded])
        let outcome = try await ControlResultObserver.observe(policy: .init(timeout: 0)) { await probe.next() }
        XCTAssertEqual(outcome, .timedOut)
        let calls = await probe.calls
        XCTAssertEqual(calls, 0)
    }

    func testBudgetShorterThanInitialDelayNeverStartsRead() async throws {
        let probe = PollProbe([.succeeded])
        let outcome = try await ControlResultObserver.observe(
            policy: .init(timeout: 0.01, initialDelay: 0.1, interval: 0.001)
        ) { await probe.next() }
        XCTAssertEqual(outcome, .timedOut)
        let calls = await probe.calls
        XCTAssertEqual(calls, 0)
    }

    func testAllPendingResponsesReachDeadline() async throws {
        let probe = PollProbe()
        let outcome = try await ControlResultObserver.observe(policy: quick) { await probe.next() }
        XCTAssertEqual(outcome, .timedOut)
        let calls = await probe.calls
        XCTAssertGreaterThan(calls, 0)
        try await Task.sleep(for: .milliseconds(10))
        let laterCalls = await probe.calls
        XCTAssertEqual(laterCalls, calls, "Timeout must stop further reads")
    }

    func testPendingThenSuccessStopsAtFirstTerminalResponse() async throws {
        let probe = PollProbe([.pending, .succeeded, .failed(message: "must not read")])
        let outcome = try await ControlResultObserver.observe(policy: quick) { await probe.next() }
        XCTAssertEqual(outcome, .verified)
        let calls = await probe.calls
        XCTAssertEqual(calls, 2)
    }

    func testServerFailureRemainsTerminal() async throws {
        let probe = PollProbe([.failed(message: "rejected"), .succeeded])
        let outcome = try await ControlResultObserver.observe(policy: quick) { await probe.next() }
        XCTAssertEqual(outcome, .failed(message: "rejected"))
        let calls = await probe.calls
        XCTAssertEqual(calls, 1)
    }

    func testDeadlineCancelsInflightRead() async throws {
        let probe = PollProbe()
        let start = ContinuousClock.now
        let outcome = try await ControlResultObserver.observe(policy: quick) { try await probe.delay() }
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        // Cancellation is signalled before the observer returns; allow the actor
        // a scheduling turn to finish its cancellation handler.
        for _ in 0..<100 {
            if await probe.cancelled { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let cancelled = await probe.cancelled
        XCTAssertTrue(cancelled)
        let calls = await probe.calls
        XCTAssertEqual(calls, 1)
    }

    func testCallerCancellationCancelsInflightRead() async throws {
        let probe = PollProbe()
        let observation = Task {
            try await ControlResultObserver.observe(policy: .init(timeout: 5, initialDelay: 0.001)) {
                try await probe.delay()
            }
        }
        for _ in 0..<100 {
            if await probe.calls > 0 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        observation.cancel()
        do { _ = try await observation.value; XCTFail("Caller cancellation must throw") }
        catch { XCTAssertTrue(error is CancellationError) }
        for _ in 0..<100 {
            if await probe.cancelled { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let cancelled = await probe.cancelled
        XCTAssertTrue(cancelled)
    }
}

private actor CancellationGate {
    private var open = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if open { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        open = true
        continuation?.resume()
        continuation = nil
    }
}
