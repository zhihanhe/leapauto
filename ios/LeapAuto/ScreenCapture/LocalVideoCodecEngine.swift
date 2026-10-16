import Foundation
import CoreGraphics
@preconcurrency import CoreImage
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
@preconcurrency import VideoToolbox
import LeapCore

/// Immutable callback payload. Core Foundation media objects are retained, never mutated after
/// submission, and consumed only on the engine's serial queue (CGImage only reaches the UI).
struct LocalVideoCodecUpdate: @unchecked Sendable {
    let runID: UUID
    let revision: UInt64
    let snapshot: LocalVideoCodecSnapshot
    let preview: CGImage?
    let encoderUsesHardware: Bool?
    let decoderUsesHardware: Bool?
}

/// Coalesces UI delivery to one pending update, even while the main thread is busy.
private final class LocalVideoCodecDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: LocalVideoCodecUpdate?
    private var scheduled = false
    private let receive: @MainActor @Sendable (LocalVideoCodecUpdate) -> Void

    init(receive: @escaping @MainActor @Sendable (LocalVideoCodecUpdate) -> Void) { self.receive = receive }

    func send(_ update: LocalVideoCodecUpdate) {
        lock.lock()
        pending = update
        let needsSchedule = !scheduled
        scheduled = true
        lock.unlock()
        guard needsSchedule else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let update = self.pending
            self.pending = nil
            self.scheduled = false
            self.lock.unlock()
            if let update { self.receive(update) }
        }
    }
}

/// All native sessions, timers and mutable state are confined to `queue`. Native output-handler
/// blocks carry value tickets, never raw unretained frame pointers. Stopped/replaced run IDs
/// are rejected before touching a new decoder. This engine has no capture or transport API.
final class LocalVideoCodecEngine: @unchecked Sendable {
    private struct EncodedOutput: @unchecked Sendable {
        let ticket: LocalVideoFrameTicket
        let status: OSStatus
        let dropped: Bool
        let sample: CMSampleBuffer?
    }
    private struct DecodedOutput: @unchecked Sendable {
        let ticket: LocalVideoFrameTicket
        let status: OSStatus
        let dropped: Bool
        let buffer: CVPixelBuffer?
    }
    private let queue = DispatchQueue(label: "com.leapauto.local-video-diagnostic", qos: .userInitiated)
    private let delivery: LocalVideoCodecDelivery
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var state = LocalVideoCodecState()
    private var encoder: VTCompressionSession?
    private var flushEveryFrame = false
    private var decoder: VTDecompressionSession?
    private var source: SyntheticVideoFrameSource?
    private var timer: DispatchSourceTimer?
    private var preview: CGImage?
    private var lastPreviewAt: TimeInterval = -.infinity
    private var revision: UInt64 = 0
    private var encoderUsesHardware: Bool?
    private var decoderUsesHardware: Bool?

    init(receive: @escaping @MainActor @Sendable (LocalVideoCodecUpdate) -> Void) {
        delivery = LocalVideoCodecDelivery(receive: receive)
    }

    deinit {
        timer?.cancel()
        if let encoder { VTCompressionSessionInvalidate(encoder) }
        if let decoder { VTDecompressionSessionInvalidate(decoder) }
    }

    func start(runID: UUID, configuration: LocalVideoCodecConfiguration) {
        queue.async { [self] in
            teardown()
            preview = nil
            lastPreviewAt = -.infinity
            encoderUsesHardware = nil
            decoderUsesHardware = nil
            guard state.begin(runID: runID, configuration: configuration) else { publish(); return }
            do {
                source = try SyntheticVideoFrameSource(configuration: configuration)
                try createEncoder(configuration)
                publish()
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now(), repeating: .milliseconds(1000 / configuration.framesPerSecond),
                               leeway: .milliseconds(2))
                timer.setEventHandler { [weak self] in self?.produceFrame() }
                self.timer = timer
                timer.resume()
            } catch {
                finish(error: message(for: error))
            }
        }
    }

    func stop(runID: UUID) {
        queue.async { [self] in
            guard state.runID == runID else { return }
            finish()
        }
    }

    private func createEncoder(_ configuration: LocalVideoCodecConfiguration) throws {
        var created: VTCompressionSession?
        let attributes = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] as CFDictionary
        try check(VTCompressionSessionCreate(allocator: kCFAllocatorDefault,
            width: Int32(configuration.width), height: Int32(configuration.height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: attributes, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &created), stage: "创建 H.264 编码器")
        guard let created else { throw LocalVideoCodecFailure.invalidFrame }
        encoder = created
        let properties: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel),
            (kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: configuration.bitRate)),
            (kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: configuration.framesPerSecond)),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: configuration.framesPerSecond * 2))
        ]
        for (key, value) in properties {
            try check(VTSessionSetProperty(created, key: key, value: value), stage: "设置编码参数 \(key)")
        }
        // Some software encoders (including the iOS simulator) do not support this
        // optional property. Explicitly drain each submitted frame in that case so
        // encoder lookahead cannot consume every bounded admission slot.
        let delayStatus = VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxFrameDelayCount,
                                               value: NSNumber(value: 0))
        flushEveryFrame = delayStatus == kVTPropertyNotSupportedErr
        if !flushEveryFrame { try check(delayStatus, stage: "设置编码参数 MaxFrameDelayCount") }
        try check(VTCompressionSessionPrepareToEncodeFrames(created), stage: "准备编码器")
        if #available(iOS 17.4, *) {
            encoderUsesHardware = readBoolean(created, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder)
        }
    }

    private func produceFrame() {
        guard state.snapshot.phase == .running else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if state.hasTimedOut(at: now, timeout: 5) {
            finish(error: "本机视频处理超过 5 秒未完成，已停止并释放本轮资源。")
            return
        }
        if state.isDrained { completeIfDrained(); return }
        guard let encoder, let source else { finish(error: "本机视频会话不可用。"); return }
        guard let ticket = state.admit(at: now) else { publish(); return }
        do {
            let frame = try source.makeFrame(sequence: ticket.sequence)
            let duration = CMTime(value: 1, timescale: Int32(state.configuration.framesPerSecond))
            let timestamp = CMTime(value: ticket.sequence, timescale: duration.timescale)
            var info = VTEncodeInfoFlags()
            let result = VTCompressionSessionEncodeFrame(encoder, imageBuffer: frame,
                presentationTimeStamp: timestamp, duration: duration, frameProperties: nil,
                infoFlagsOut: &info, outputHandler: { [weak self] status, flags, sample in
                    guard let self else { return }
                    let output = EncodedOutput(ticket: ticket, status: status,
                                               dropped: flags.contains(.frameDropped), sample: sample)
                    self.queue.async { [weak self] in self?.handleEncoded(output) }
                })
            if result != noErr { fail(ticket, stage: "提交编码帧", status: result); return }
            if info.contains(.frameDropped) { state.drop(ticket) }
            // Unsupported delay bounds require a per-frame drain; cancel/stop never
            // submits more input. Other encoders only flush at the finite source limit.
            if flushEveryFrame || state.sourceLimitReached {
                try check(VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid), stage: "排空编码器")
            }
            publish()
            completeIfDrained()
        } catch {
            state.fail(ticket)
            finish(error: message(for: error))
        }
    }

    private func handleEncoded(_ output: EncodedOutput) {
        guard state.isPending(output.ticket) else { return }
        guard output.status == noErr else { fail(output.ticket, stage: "H.264 编码", status: output.status); return }
        if output.dropped { state.drop(output.ticket); publish(); completeIfDrained(); return }
        guard let sample = output.sample, CMSampleBufferDataIsReady(sample),
              CMSampleBufferGetNumSamples(sample) == 1,
              let format = CMSampleBufferGetFormatDescription(sample),
              CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264,
              CMSampleBufferGetTotalSampleSize(sample) > 0 else {
            state.fail(output.ticket)
            finish(error: "编码器未返回有效的单帧 H.264 数据。")
            return
        }
        guard state.encoded(output.ticket, byteCount: CMSampleBufferGetTotalSampleSize(sample)) else { return }
        if #available(iOS 17.4, *), let encoder {
            encoderUsesHardware = readBoolean(encoder, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder)
        }
        do {
            if decoder == nil { try createDecoder(format: format) }
            guard let decoder, VTDecompressionSessionCanAcceptFormatDescription(decoder, formatDescription: format) else {
                throw LocalVideoCodecFailure.invalidFrame
            }
            var info = VTDecodeInfoFlags()
            let result = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [],
                infoFlagsOut: &info, outputHandler: { [weak self] status, flags, buffer, _, _ in
                    guard let self else { return }
                    let decoded = DecodedOutput(ticket: output.ticket, status: status,
                                                dropped: flags.contains(.frameDropped), buffer: buffer)
                    self.queue.async { [weak self] in self?.handleDecoded(decoded) }
                })
            if result != noErr { fail(output.ticket, stage: "提交解码帧", status: result); return }
            if info.contains(.frameDropped) { state.drop(output.ticket) }
            publish()
            completeIfDrained()
        } catch {
            state.fail(output.ticket)
            finish(error: message(for: error))
        }
    }

    private func createDecoder(format: CMVideoFormatDescription) throws {
        var created: VTDecompressionSession?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        try check(VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
            decoderSpecification: nil, imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &created), stage: "创建 H.264 解码器")
        guard let created else { throw LocalVideoCodecFailure.invalidFrame }
        decoder = created
    }

    private func handleDecoded(_ output: DecodedOutput) {
        guard state.isPending(output.ticket) else { return }
        guard output.status == noErr else { fail(output.ticket, stage: "H.264 解码", status: output.status); return }
        if output.dropped { state.drop(output.ticket); publish(); completeIfDrained(); return }
        guard let buffer = output.buffer,
              SyntheticVideoFrameSource.matchesColorBars(buffer, configuration: state.configuration) else {
            state.fail(output.ticket)
            finish(error: "解码图像的尺寸、格式或彩条内容校验失败。")
            return
        }
        if let decoder {
            decoderUsesHardware = readBoolean(decoder, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder)
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard state.decoded(output.ticket, at: now) else { return }
        if preview == nil || now - lastPreviewAt >= 0.25 || state.isDrained {
            let image = CIImage(cvPixelBuffer: buffer)
            preview = imageContext.createCGImage(image, from: image.extent)
            lastPreviewAt = now
        }
        publish()
        completeIfDrained()
    }

    private func completeIfDrained() {
        guard state.snapshot.phase == .running, state.isDrained else { return }
        if state.snapshot.decodedFrames == 0 { finish(error: "没有任何合成帧完成真实解码。"); return }
        finish(completed: true)
    }

    private func fail(_ ticket: LocalVideoFrameTicket, stage: String, status: OSStatus) {
        guard state.fail(ticket) else { return }
        finish(error: LocalVideoCodecFailure.operation(stage, status).message)
    }

    private func finish(error: String? = nil, completed: Bool = false) {
        state.stop(error: error, completed: completed)
        // Invalidate the generation before native cleanup can invoke any pending output blocks.
        teardown()
        if !completed { preview = nil }
        publish()
    }

    private func teardown() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        if let encoder { VTCompressionSessionInvalidate(encoder) }
        if let decoder { VTDecompressionSessionInvalidate(decoder) }
        encoder = nil
        decoder = nil
        source = nil
    }

    private func publish() {
        guard let runID = state.runID else { return }
        revision &+= 1
        delivery.send(LocalVideoCodecUpdate(runID: runID, revision: revision, snapshot: state.snapshot,
            preview: preview, encoderUsesHardware: encoderUsesHardware, decoderUsesHardware: decoderUsesHardware))
    }

    private func readBoolean(_ session: VTSession, key: CFString) -> Bool? {
        // The C API writes a retained CF object through void*. Receive that ownership
        // explicitly instead of writing a raw pointer into Swift strong-reference storage.
        var value: Unmanaged<CFTypeRef>?
        let status = VTSessionCopyProperty(session, key: key, allocator: kCFAllocatorDefault, valueOut: &value)
        let property = value?.takeRetainedValue()
        guard status == noErr, let boolean = property as? NSNumber else { return nil }
        return boolean.boolValue
    }

    private func check(_ status: OSStatus, stage: String) throws {
        if status != noErr { throw LocalVideoCodecFailure.operation(stage, status) }
    }

    private func message(for error: Error) -> String {
        (error as? LocalVideoCodecFailure)?.message ?? "本机视频诊断失败。"
    }
}
