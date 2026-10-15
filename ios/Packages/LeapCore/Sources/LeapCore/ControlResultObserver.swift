import Foundation

public enum ControlObservationError: Error, LocalizedError, Sendable {
    case deadlineExceeded
    public var errorDescription: String? { "车况刷新超时，请稍后重新核对。" }
}

/// One monotonic budget shared by result polling and its final telemetry read.
/// Cancellation releases the caller even if a transport's callback arrives late.
public struct ControlObservationDeadline: Sendable {
    private let instant: ContinuousClock.Instant

    public init(timeout: TimeInterval) {
        precondition(timeout.isFinite && timeout >= 0)
        instant = ContinuousClock.now.advanced(by: .seconds(timeout))
    }

    fileprivate func checkRemaining() throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < instant else { throw ControlObservationError.deadlineExceeded }
    }

    public func run<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try checkRemaining()
        let race = ObservationRace<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
                let timer = Task {
                    do {
                        try await ContinuousClock().sleep(until: instant)
                        race.finish(.failure(ControlObservationError.deadlineExceeded))
                    } catch { /* A terminal result or caller cancellation won. */ }
                }
                let reader = Task {
                    do {
                        try Task.checkCancellation()
                        guard race.isPending else { return }
                        guard ContinuousClock.now < instant else { throw ControlObservationError.deadlineExceeded }
                        let value = try await operation()
                        try Task.checkCancellation()
                        guard ContinuousClock.now < instant else { throw ControlObservationError.deadlineExceeded }
                        race.finish(.success(value))
                    } catch {
                        race.finish(.failure(ContinuousClock.now >= instant
                            ? ControlObservationError.deadlineExceeded : error))
                    }
                }
                race.install(reader: reader, timer: timer)
            }
        } onCancel: {
            race.finish(.failure(CancellationError()))
        }
    }
}

/// Observes one already-accepted command. The deadline covers sleeps, credential
/// refresh and the entire result read; this API never submits commands.
public enum ControlResultObserver {
    public static func observe(
        policy: ControlPollingPolicy = .app,
        deadline: ControlObservationDeadline? = nil,
        poll: @escaping @Sendable () async throws -> ControlPollResult
    ) async throws -> ControlOutcome {
        let deadline = deadline ?? ControlObservationDeadline(timeout: policy.timeout)
        do {
            return try await deadline.run {
                try await Task.sleep(for: .seconds(policy.initialDelay))
                while true {
                    try deadline.checkRemaining()
                    let result = try await poll()
                    try deadline.checkRemaining()
                    switch result {
                    case .succeeded: return .verified
                    case .failed(let message): return .failed(message: message)
                    case .pending: try await Task.sleep(for: .seconds(policy.interval))
                    }
                }
            }
        } catch ControlObservationError.deadlineExceeded {
            return .timedOut
        }
    }
}

/// A task group waits for all children even after cancellation. A transport may
/// deliver its cancellation callback late, so use a single-resume race instead:
/// release the UI at the deadline, cancel the read, and discard every late result.
/// The HTTP actor independently checks cancellation before accepting responses.
private final class ObservationRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?
    private var reader: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    var isPending: Bool {
        lock.lock(); defer { lock.unlock() }
        return result == nil
    }

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func install(reader: Task<Void, Never>, timer: Task<Void, Never>) {
        lock.lock()
        if result != nil {
            lock.unlock()
            reader.cancel()
            timer.cancel()
        } else {
            self.reader = reader
            self.timer = timer
            lock.unlock()
        }
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        let reader = self.reader
        let timer = self.timer
        self.continuation = nil
        self.reader = nil
        self.timer = nil
        lock.unlock()
        reader?.cancel()
        timer?.cancel()
        continuation?.resume(with: result)
    }
}
