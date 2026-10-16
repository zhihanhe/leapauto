import Foundation
import Combine
import CoreGraphics
import LeapCore

@MainActor
final class LocalVideoCodecDiagnosticsModel: ObservableObject {
    @Published private(set) var snapshot = LocalVideoCodecSnapshot()
    @Published private(set) var isStopping = false
    @Published private(set) var preview: CGImage?
    @Published private(set) var encoderUsesHardware: Bool?
    @Published private(set) var decoderUsesHardware: Bool?
    private var currentRunID: UUID?
    private var latestRevision: UInt64 = 0
    private var requestedRunning = false
    private lazy var engine = LocalVideoCodecEngine { [weak self] update in self?.receive(update) }

    var isRunning: Bool { requestedRunning && snapshot.phase == .running }

    /// Repeated starts and dimension changes replace the whole native session and generation.
    func start(configuration: LocalVideoCodecConfiguration = .standard) {
        let runID = UUID()
        currentRunID = runID
        requestedRunning = true
        isStopping = false
        snapshot = LocalVideoCodecSnapshot()
        snapshot.phase = .running
        preview = nil
        encoderUsesHardware = nil
        decoderUsesHardware = nil
        engine.start(runID: runID, configuration: configuration)
    }

    func stop() {
        guard let currentRunID else { return }
        preview = nil
        guard requestedRunning || snapshot.phase == .running else { return }
        requestedRunning = false
        isStopping = true
        snapshot.phase = .stopped
        engine.stop(runID: currentRunID)
    }

    private func receive(_ update: LocalVideoCodecUpdate) {
        guard update.runID == currentRunID, update.revision > latestRevision else { return }
        // A queued running/completed update cannot restore the preview after the user stops.
        if !requestedRunning && update.snapshot.phase != .stopped && update.snapshot.phase != .failed { return }
        latestRevision = update.revision
        snapshot = update.snapshot
        preview = update.preview
        encoderUsesHardware = update.encoderUsesHardware
        decoderUsesHardware = update.decoderUsesHardware
        if update.snapshot.phase != .running {
            requestedRunning = false
            isStopping = false
        }
    }
}
