import Foundation

/// A local synthetic-video diagnostic only. These settings describe no vehicle protocol.
public struct LocalVideoCodecConfiguration: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let framesPerSecond: Int
    public let bitRate: Int
    public let maximumInFlightFrames: Int
    public let frameLimit: Int

    public init(width: Int = 640, height: Int = 360, framesPerSecond: Int = 10,
                bitRate: Int = 800_000, maximumInFlightFrames: Int = 3, frameLimit: Int = 300) {
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.bitRate = bitRate
        self.maximumInFlightFrames = maximumInFlightFrames
        self.frameLimit = frameLimit
    }

    public static let standard = LocalVideoCodecConfiguration()
    public static let hd = LocalVideoCodecConfiguration(width: 1280, height: 720, bitRate: 2_000_000)

    /// Check before allocating buffers or creating Apple codec sessions.
    public var validationError: String? {
        guard (64...1920).contains(width), (64...1080).contains(height),
              width.isMultiple(of: 2), height.isMultiple(of: 2) else {
            return "图像尺寸必须是范围内的偶数（64–1920 × 64–1080）。"
        }
        guard (1...30).contains(framesPerSecond) else { return "帧率必须为 1–30。" }
        guard (64_000...10_000_000).contains(bitRate) else { return "码率超出诊断范围。" }
        guard (1...8).contains(maximumInFlightFrames) else { return "在途帧上限必须为 1–8。" }
        guard (1...1800).contains(frameLimit) else { return "诊断帧数必须为 1–1800。" }
        return nil
    }
}

public enum LocalVideoCodecPhase: String, Equatable, Sendable {
    case idle, running, completed, stopped, failed
}

public struct LocalVideoFrameTicket: Hashable, Sendable {
    public let runID: UUID
    public let sequence: Int64
}

public struct LocalVideoCodecSnapshot: Equatable, Sendable {
    public var phase: LocalVideoCodecPhase = .idle
    public var attemptedFrames = 0
    public var submittedFrames = 0
    public var encodedFrames = 0
    public var decodedFrames = 0
    public var backpressureDrops = 0
    public var codecDrops = 0
    public var cancelledFrames = 0
    public var failedFrames = 0
    public var encodedBytes = 0
    public var inFlightFrames = 0
    public var peakInFlightFrames = 0
    public var meanLatencyMilliseconds: Double = 0
    public var maximumLatencyMilliseconds: Double = 0
    public var errorMessage: String?
    public var droppedFrames: Int { backpressureDrops + codecDrops + cancelledFrames }
    public init() {}
}

/// Serial-owner state machine, deliberately independent of VideoToolbox and wall-clock APIs.
/// An admitted ticket occupies capacity until decode/drop/failure or cancellation. A timeout
/// stops the entire run; it must not free capacity while the codec still owns old frames.
public struct LocalVideoCodecState: Sendable {
    private enum Stage: Equatable, Sendable { case encoding, decoding }
    private struct Pending: Sendable {
        var stage: Stage
        let admittedAt: TimeInterval
    }
    public private(set) var runID: UUID?
    public private(set) var configuration = LocalVideoCodecConfiguration.standard
    public private(set) var snapshot = LocalVideoCodecSnapshot()
    private var pending: [Int64: Pending] = [:]
    private var nextSequence: Int64 = 0
    private var latencyTotal: Double = 0

    public init() {}

    @discardableResult
    public mutating func begin(runID: UUID, configuration: LocalVideoCodecConfiguration) -> Bool {
        self.runID = runID
        self.configuration = configuration
        snapshot = LocalVideoCodecSnapshot()
        pending.removeAll(keepingCapacity: false)
        nextSequence = 0
        latencyTotal = 0
        if let error = configuration.validationError {
            snapshot.phase = .failed
            snapshot.errorMessage = error
            return false
        }
        snapshot.phase = .running
        return true
    }

    public var sourceLimitReached: Bool { snapshot.submittedFrames >= configuration.frameLimit }
    public var isDrained: Bool { sourceLimitReached && pending.isEmpty }

    public mutating func admit(at time: TimeInterval) -> LocalVideoFrameTicket? {
        guard snapshot.phase == .running, !sourceLimitReached, time.isFinite, let runID else { return nil }
        snapshot.attemptedFrames += 1
        guard pending.count < configuration.maximumInFlightFrames else {
            snapshot.backpressureDrops += 1
            return nil
        }
        let ticket = LocalVideoFrameTicket(runID: runID, sequence: nextSequence)
        nextSequence += 1
        pending[ticket.sequence] = Pending(stage: .encoding, admittedAt: time)
        snapshot.submittedFrames += 1
        updateOccupancy()
        return ticket
    }

    public func isPending(_ ticket: LocalVideoFrameTicket) -> Bool {
        snapshot.phase == .running && ticket.runID == runID && pending[ticket.sequence] != nil
    }

    @discardableResult
    public mutating func encoded(_ ticket: LocalVideoFrameTicket, byteCount: Int) -> Bool {
        guard isPending(ticket), pending[ticket.sequence]?.stage == .encoding, byteCount > 0 else { return false }
        pending[ticket.sequence]?.stage = .decoding
        snapshot.encodedFrames += 1
        snapshot.encodedBytes += byteCount
        return true
    }

    @discardableResult
    public mutating func decoded(_ ticket: LocalVideoFrameTicket, at time: TimeInterval) -> Bool {
        guard isPending(ticket), let frame = pending[ticket.sequence], frame.stage == .decoding,
              time.isFinite, time >= frame.admittedAt else { return false }
        pending.removeValue(forKey: ticket.sequence)
        snapshot.decodedFrames += 1
        let latency = (time - frame.admittedAt) * 1000
        latencyTotal += latency
        snapshot.meanLatencyMilliseconds = latencyTotal / Double(snapshot.decodedFrames)
        snapshot.maximumLatencyMilliseconds = max(snapshot.maximumLatencyMilliseconds, latency)
        updateOccupancy()
        return true
    }

    @discardableResult
    public mutating func drop(_ ticket: LocalVideoFrameTicket) -> Bool {
        guard isPending(ticket) else { return false }
        pending.removeValue(forKey: ticket.sequence)
        snapshot.codecDrops += 1
        updateOccupancy()
        return true
    }

    @discardableResult
    public mutating func fail(_ ticket: LocalVideoFrameTicket) -> Bool {
        guard isPending(ticket) else { return false }
        pending.removeValue(forKey: ticket.sequence)
        snapshot.failedFrames += 1
        updateOccupancy()
        return true
    }

    public func hasTimedOut(at time: TimeInterval, timeout: TimeInterval) -> Bool {
        guard snapshot.phase == .running, time.isFinite, timeout.isFinite, timeout > 0 else { return false }
        return pending.values.contains { time >= $0.admittedAt && time - $0.admittedAt >= timeout }
    }

    /// Call before invalidating native sessions; all callbacks become ineligible immediately.
    public mutating func stop(error: String? = nil, completed: Bool = false) {
        // Completion may already be queued for the UI when an explicit stop arrives.
        // Give that stop its own terminal acknowledgement without reopening a session.
        guard snapshot.phase == .running || (snapshot.phase == .completed && !completed && error == nil) else { return }
        let didComplete = completed && isDrained
        snapshot.cancelledFrames += pending.count
        pending.removeAll(keepingCapacity: false)
        updateOccupancy()
        snapshot.errorMessage = error.map { String($0.prefix(240)) }
        snapshot.phase = error != nil ? .failed : (didComplete ? .completed : .stopped)
    }

    private mutating func updateOccupancy() {
        snapshot.inFlightFrames = pending.count
        snapshot.peakInFlightFrames = max(snapshot.peakInFlightFrames, pending.count)
    }
}
