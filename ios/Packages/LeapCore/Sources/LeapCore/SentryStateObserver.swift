import Foundation

/// State evidence for one submitted sentry target. A matching cached signal is
/// insufficient: it must have a strictly newer vehicle source time and remain
/// fresh. Receipt time and a successful result query cannot replace that evidence.
public struct SentryStateConfirmation: Equatable, Sendable {
    public let targetEnabled: Bool
    public let baselineTimestamp: Date?

    public init(targetEnabled: Bool, baselineTimestamp: Date?) {
        self.targetEnabled = targetEnabled
        self.baselineTimestamp = baselineTimestamp
    }

    public func isConfirmed(by status: VehicleStatus, at now: Date = Date()) -> Bool {
        guard let baselineTimestamp, let observed = status.sourceTimestamp,
              observed > baselineTimestamp, status.isFreshForControl(at: now) else { return false }
        return SentryControlPolicy.isConfirmed(targetEnabled: targetEnabled, telemetryEnabled: status.sentryMode)
    }
}

public enum SentryStateObservationOutcome: Equatable, Sendable {
    case confirmed
    case timedOut
}

/// Read-only follow-through after a verified command result. Shares the original
/// result deadline, including every telemetry read and intervening delay. This
/// type has no command submission closure, and never retries a failed read.
public enum SentryStateObserver {
    public static func observe(
        confirmation: SentryStateConfirmation,
        policy: ControlPollingPolicy = .app,
        deadline: ControlObservationDeadline,
        now: @escaping @Sendable () -> Date = { Date() },
        refresh: @escaping @Sendable () async throws -> VehicleStatus,
        onObservation: @escaping @Sendable (VehicleStatus) async throws -> Void = { _ in }
    ) async throws -> SentryStateObservationOutcome {
        do {
            while true {
                // Keep publication outside the deadline race: a cancelled or
                // non-cooperative late response must never reach the callback.
                let fresh = try await deadline.run(refresh)
                try Task.checkCancellation()
                try await deadline.run { try await onObservation(fresh) }
                if confirmation.isConfirmed(by: fresh, at: now()) { return .confirmed }
                try await deadline.run { try await Task.sleep(for: .seconds(policy.interval)) }
            }
        } catch ControlObservationError.deadlineExceeded {
            return .timedOut
        }
    }
}
