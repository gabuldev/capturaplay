import os
import AVFoundation
import CoreMedia
import Flutter
import Foundation
import IOSurface
import Network
import QuartzCore
import UIKit
import VideoToolbox

/// iPhone receiver. Suave keeps `AVSampleBufferDisplayLayer`. Ultra decodes
/// with VideoToolbox and puts the IOSurface on a layer for the next vsync,
/// which skips the display layer's queue. The view stays a UIKit platform
/// view: on iOS that is a real UIView, not a Flutter texture copy.
public final class CapturaReceiverPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private let hub = ReceiverHub()

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = CapturaReceiverPlugin()
        let methods = FlutterMethodChannel(name: "captura_lan/receiver", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: methods)
        let events = FlutterEventChannel(name: "captura_lan/events", binaryMessenger: registrar.messenger())
        events.setStreamHandler(instance)
        registrar.register(DisplayViewFactory(hub: instance.hub), withId: "captura_lan/display")
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "start":
            hub.start()
            result(nil)
        case "stop":
            hub.stop()
            result(nil)
        case "connectService":
            hub.connect(name: args["name"] as? String ?? "")
            result(nil)
        case "connectHost":
            let host = args["host"] as? String ?? ""
            let port = (args["port"] as? NSNumber)?.uint16Value ?? LanLimits.port
            hub.connect(host: host, port: port)
            result(nil)
        case "disconnect":
            hub.disconnect()
            result(nil)
        case "setSmooth":
            let smooth = (args["smooth"] as? Bool) ?? (args["smooth"] as? NSNumber)?.boolValue ?? true
            hub.setSmooth(smooth)
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        hub.eventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        hub.eventSink = nil
        return nil
    }
}

final class DisplayViewFactory: NSObject, FlutterPlatformViewFactory {
    private let hub: ReceiverHub

    init(hub: ReceiverHub) {
        self.hub = hub
        super.init()
    }

    func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
        DisplayPlatformView(frame: frame, hub: hub)
    }
}

final class DisplayPlatformView: NSObject, FlutterPlatformView {
    private let host: DisplayHostView

    init(frame: CGRect, hub: ReceiverHub) {
        host = DisplayHostView(frame: frame)
        super.init()
        hub.attach(host)
    }

    func view() -> UIView { host }

    deinit {
        host.detachFromHub()
    }
}

final class DisplayHostView: UIView {
    weak var hub: ReceiverHub?
    let sampleLayer = AVSampleBufferDisplayLayer()
    let pixelLayer = CALayer()
    private var heldPixel: CVPixelBuffer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = true
        backgroundColor = .black
        sampleLayer.videoGravity = .resizeAspect
        sampleLayer.backgroundColor = UIColor.black.cgColor
        sampleLayer.preventsDisplaySleepDuringVideoPlayback = true
        pixelLayer.contentsGravity = .resizeAspect
        pixelLayer.backgroundColor = UIColor.black.cgColor
        pixelLayer.isHidden = true
        layer.addSublayer(sampleLayer)
        layer.addSublayer(pixelLayer)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        sampleLayer.frame = bounds
        pixelLayer.frame = bounds
        let scale = window?.windowScene?.screen.scale ?? 2
        pixelLayer.contentsScale = scale
        sampleLayer.contentsScale = scale
    }

    func showPixel(_ buffer: CVPixelBuffer) {
        heldPixel = buffer
        sampleLayer.isHidden = true
        pixelLayer.isHidden = false
        if let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() {
            pixelLayer.contents = surface
        }
    }

    func showSamples() {
        heldPixel = nil
        pixelLayer.contents = nil
        pixelLayer.isHidden = true
        sampleLayer.isHidden = false
    }

    func detachFromHub() {
        hub?.detach(self)
    }
}

private let lanLog = Logger(subsystem: "dev.capturaplay.capturaplay", category: "lan.recv")

final class ReceiverHub {
    var eventSink: FlutterEventSink?
    private let queue = DispatchQueue(label: "dev.capturaplay.lan.recv", qos: .userInteractive)
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var udpConnection: NWConnection?
    private var udpReassembler = UdpReassembler()
    private var remoteUltra = false
    private let pixelDecoder = PixelDecoder()
    private var lastKeyframeAsk = CFTimeInterval(0)
    private var parser = LanStreamParser()
    private var endpoints: [String: NWEndpoint] = [:]
    private var desired: NWEndpoint?
    private var suppressAuto = false
    private var running = false
    private var format: CMVideoFormatDescription?
    private var lastKeyframe: CMSampleBuffer?
    private weak var display: DisplayHostView?
    private var pingTimer: DispatchSourceTimer?
    private let stateLock = NSLock()
    private var smoothPlayback = true
    private var jitter: [HeldFrame] = []
    private var paceAnchorLocal: CFTimeInterval?
    private var paceAnchorPtsUs: UInt64?
    private let pacer = DisplayPacer()
    private var clockOffsetUs: Int64 = 0
    private var rttUs: Int64 = 0
    private var clockSuspect = false
    private var stageCaptureUs: Int64 = -1
    private var stageEncodeUs: Int64 = -1
    private var stageQueueUs: Int64 = -1
    private var stageNetworkUs: Int64 = -1
    private var stageDecodeUs: Int64 = -1
    private var stageGlassUs: Int64 = -1
    private var lastStageLog = CFTimeInterval(0)
    private var receivedTimes: [CFTimeInterval] = []
    private var displayedTimes: [CFTimeInterval] = []
    private var lastStats: CFTimeInterval = 0
    private var lastSequence: UInt16?
    private var networkDrops = 0
    private var displayDrops = 0
    private var decoderErrors = 0
    private var waitingForKeyframe = 0
    private var awaitingKeyframe = false
    private var configuredBitrateMbps = 0
    private var configuredMaxQp = 0
    private var lastLatencyMs = 0.0

    func start() {
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        queue.async {
            guard !self.running else { return }
            self.running = true
            self.startBrowser()
            self.startPing()
            self.emitState(phase: "browsing", detail: nil)
        }
        pacer.onTick = { [weak self] in
            self?.pace()
        }
        pacer.start()
    }

    func setSmooth(_ value: Bool) {
        stateLock.lock()
        smoothPlayback = value
        jitter.removeAll()
        paceAnchorLocal = nil
        paceAnchorPtsUs = nil
        stateLock.unlock()
    }

    func stop() {
        queue.async {
            self.running = false
            self.suppressAuto = true
            self.tearDownConnection()
            self.browser?.cancel()
            self.browser = nil
            self.pingTimer?.cancel()
            self.pingTimer = nil
            self.stateLock.lock()
            self.jitter.removeAll()
            self.paceAnchorLocal = nil
            self.paceAnchorPtsUs = nil
            self.stateLock.unlock()
        }
        pacer.stop()
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    func connect(name: String) {
        queue.async {
            guard let endpoint = self.endpoints[name] else { return }
            self.suppressAuto = false
            self.open(endpoint)
        }
    }

    func connect(host: String, port: UInt16) {
        queue.async {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
            self.suppressAuto = false
            self.open(.hostPort(host: NWEndpoint.Host(host), port: nwPort))
        }
    }

    func disconnect() {
        queue.async {
            self.suppressAuto = true
            self.desired = nil
            self.tearDownConnection()
            self.emitState(phase: "browsing", detail: nil)
        }
    }

    func attach(_ view: DisplayHostView) {
        view.hub = self
        display = view
        queue.async {
            let ultra = self.remoteUltra
            let sample = self.lastKeyframe
            DispatchQueue.main.async {
                if ultra {
                    view.showSamples()
                }
                if let sample, !ultra {
                    self.present(sample, keyframe: true, timing: .zero, flushBefore: true)
                }
            }
        }
    }

    func detach(_ view: DisplayHostView) {
        if display === view {
            display = nil
        }
    }

    private func startBrowser() {
        let browser = NWBrowser(for: .bonjour(type: LanLimits.serviceType, domain: nil), using: tcpParameters())
        browser.stateUpdateHandler = { [weak self] state in
            if case let .waiting(error) = state {
                self?.emitState(phase: "browsing", detail: "Rede local: \(error.localizedDescription)")
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.apply(results: results)
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func apply(results: Set<NWBrowser.Result>) {
        var next: [String: NWEndpoint] = [:]
        var names: [String] = []
        for result in results {
            let name = serviceName(result.endpoint)
            next[name] = result.endpoint
            names.append(name)
        }
        names.sort()
        endpoints = next
        emit(event: ["type": "services", "names": names])
        if !suppressAuto, connection == nil, results.count == 1, let only = results.first {
            open(only.endpoint)
        }
    }

    private func serviceName(_ endpoint: NWEndpoint) -> String {
        if case let .service(name, _, _, _) = endpoint {
            return name
        }
        return "CapturaPlay"
    }

    private func open(_ endpoint: NWEndpoint) {
        tearDownConnection()
        desired = endpoint
        emitState(phase: "connecting", detail: nil)
        let connection = NWConnection(to: endpoint, using: tcpParameters())
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            self?.handle(state, connection: connection)
        }
        connection.start(queue: queue)
    }

    private func handle(_ state: NWConnection.State, connection: NWConnection) {
        switch state {
        case .ready:
            parser.reset()
            send(LanWire.hello(features: LanFeatures.video), on: connection)
            receive(on: connection)
            if let remote = connection.currentPath?.remoteEndpoint {
                openUdp(to: remote)
            }
            emitState(phase: "connected", detail: nil)
        case .failed, .cancelled:
            guard self.connection === connection else { return }
            self.connection = nil
            format = nil
            guard running, !suppressAuto, desired != nil else {
                emitState(phase: "browsing", detail: nil)
                return
            }
            emitState(phase: "reconnecting", detail: "A ligação caiu. Tentando de novo…")
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, let desired = self.desired, self.connection == nil, !self.suppressAuto else { return }
                self.open(desired)
            }
        default:
            break
        }
    }

    private func tearDownConnection() {
        connection?.cancel()
        connection = nil
        udpConnection?.cancel()
        udpConnection = nil
        udpReassembler = UdpReassembler()
        remoteUltra = false
        pixelDecoder.invalidate()
        parser.reset()
        format = nil
        lastKeyframe = nil
        DispatchQueue.main.async { [weak self] in
            self?.display?.showSamples()
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.ingest(data)
            }
            if error != nil || isComplete {
                if self.connection === connection {
                    connection.cancel()
                }
                return
            }
            self.receive(on: connection)
        }
    }

    private func ingest(_ data: Data) {
        do {
            for message in try parser.add(data) {
                switch message.type {
                case LanType.videoConfig:
                    applyConfig(message.payload)
                case LanType.videoFrame:
                    if !remoteUltra {
                        applyFrame(message.payload)
                    }
                case LanType.transport:
                    if let udp = LanWire.transportIsUdp(of: message.payload) {
                        remoteUltra = udp
                        if udp {
                            stateLock.lock()
                            jitter.removeAll()
                            stateLock.unlock()
                            if let remote = self.connection?.currentPath?.remoteEndpoint {
                                openUdp(to: remote)
                            }
                        }
                        DispatchQueue.main.async { [weak self] in
                            if !udp {
                                self?.display?.showSamples()
                            }
                        }
                    }
                case LanType.pong:
                    if let times = LanWire.pongTimes(of: message.payload) {
                        let clientRecv = Self.nowUs()
                        self.clockOffsetUs = LanWire.clockOffsetUs(
                            clientSend: times.t1,
                            serverRecv: times.t2,
                            serverSend: times.t3,
                            clientRecv: clientRecv
                        )
                        self.rttUs = LanWire.roundTripUs(
                            clientSend: times.t1,
                            serverRecv: times.t2,
                            serverSend: times.t3,
                            clientRecv: clientRecv
                        )
                        let skew = self.clockOffsetUs < 0 ? -self.clockOffsetUs : self.clockOffsetUs
                        let trip = self.rttUs < 0 ? -self.rttUs : self.rttUs
                        let allowance = trip > 5_000 ? trip : 5_000
                        self.clockSuspect = skew > allowance + 2_000
                    }
                case LanType.audioConfig, LanType.audioFrame:
                    // TODO: audio. The Mac does not send it yet.
                    break
                default:
                    break
                }
            }
        } catch {
            connection?.cancel()
        }
    }

    private func applyConfig(_ payload: Data) {
        guard let sets = LanWire.parameterSets(of: payload) else { return }
        sets.sps.withUnsafeBytes { spsRaw in
            sets.pps.withUnsafeBytes { ppsRaw in
                guard let spsPointer = spsRaw.bindMemory(to: UInt8.self).baseAddress,
                      let ppsPointer = ppsRaw.bindMemory(to: UInt8.self).baseAddress else { return }
                var pointers = [spsPointer, ppsPointer]
                var sizes = [sets.sps.count, sets.pps.count]
                var description: CMVideoFormatDescription?
                let status = pointers.withUnsafeMutableBufferPointer { pointerBuffer in
                    sizes.withUnsafeMutableBufferPointer { sizeBuffer in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointerBuffer.baseAddress!,
                            parameterSetSizes: sizeBuffer.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &description
                        )
                    }
                }
                if status == noErr, let description {
                    format = description
                    pixelDecoder.update(format: description)
                    if let mbps = LanWire.configBitrateMbps(of: payload) {
                        self.configuredBitrateMbps = mbps
                    }
                    if let qp = LanWire.configMaxFrameQp(of: payload) {
                        self.configuredMaxQp = qp
                    }
                }
            }
        }
    }

    private func applyFrame(_ payload: Data) {
        guard let prefix = LanWire.framePrefix(of: payload), !prefix.nalus.isEmpty else { return }
        deliver(
            nalus: prefix.nalus,
            keyframe: prefix.keyframe,
            sequence: prefix.sequence,
            ptsUs: prefix.ptsUs,
            timing: FrameTiming(
                captureUs: prefix.captureHostUs,
                encoderInUs: prefix.encoderInUs,
                encoderOutUs: prefix.encoderOutUs,
                sendUs: prefix.sendUs,
                recvUs: Self.nowUs()
            ),
            direct: false
        )
    }

    private func deliver(nalus: Data, keyframe: Bool, sequence: UInt16, ptsUs: UInt64, timing: FrameTiming, direct: Bool) {
        guard !nalus.isEmpty else { return }
        guard let format else {
            askKeyframe()
            return
        }
        var block: CMBlockBuffer?
        let length = nalus.count
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: 0,
            blockBufferOut: &block
        ) == kCMBlockBufferNoErr, let block else { return }
        let copied = nalus.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }
        guard copied == kCMBlockBufferNoErr else { return }
        var sampleTiming = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: ptsUs == 0 ? .invalid : CMTime(value: CMTimeValue(ptsUs), timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = length
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &sampleTiming,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample
        )
        guard status == noErr, let sample else { return }
        markDisplayImmediately(sample)
        if keyframe {
            lastKeyframe = sample
        }
        noteSequence(sequence)
        noteReceived()
        let recover = awaitingKeyframe && keyframe
        if awaitingKeyframe && !keyframe {
            waitingForKeyframe += 1
            if direct || remoteUltra { askKeyframe() }
            emitStats(bufferDepth: bufferDepth())
            return
        }
        if recover {
            awaitingKeyframe = false
        }
        if direct || remoteUltra {
            decodeAndShow(sample, timing: timing)
        } else if isSmooth() {
            hold(
                sample,
                keyframe: keyframe,
                timing: timing,
                sequence: sequence,
                ptsUs: ptsUs,
                flushBefore: recover
            )
        } else {
            present(sample, keyframe: keyframe, timing: timing, flushBefore: recover)
        }
    }

    private func markDisplayImmediately(_ sample: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) else {
            return
        }
        if let dictionaries = attachments as? [NSMutableDictionary], let first = dictionaries.first {
            first[kCMSampleAttachmentKey_DisplayImmediately] = true
            return
        }
        let dictionary = unsafeBitCast(
            CFArrayGetValueAtIndex(attachments, 0),
            to: CFMutableDictionary.self
        )
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }

    private func present(_ sample: CMSampleBuffer, keyframe: Bool, timing: FrameTiming, flushBefore: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.display?.showSamples()
            let displayedAt = Self.nowUs()
            let glassUs = self.predictedGlassUs()
            var enqueued = false
            if let layer = self.display?.sampleLayer {
                if layer.status == .failed {
                    layer.flush()
                    self.queue.async { self.decoderErrors += 1 }
                } else if flushBefore {
                    layer.flush()
                }
                let failed = layer.status == .failed
                if failed && !keyframe {
                    enqueued = false
                } else if layer.isReadyForMoreMediaData || keyframe {
                    if !layer.isReadyForMoreMediaData {
                        layer.flush()
                    }
                    layer.enqueue(sample)
                    enqueued = true
                }
            }
            self.queue.async {
                if enqueued {
                    self.noteDisplayed(timing: timing, decodeSubmitUs: displayedAt, decodedUs: displayedAt, glassUs: glassUs)
                } else if keyframe {
                    self.displayDrops += 1
                    self.emitStats(bufferDepth: 0)
                } else {
                    self.displayDrops += 1
                    self.awaitingKeyframe = true
                    self.waitingForKeyframe += 1
                    self.emitStats(bufferDepth: 0)
                }
            }
        }
    }

    private func noteSequence(_ sequence: UInt16) {
        if let lastSequence {
            let gap = Int(sequence &- lastSequence)
            if gap > 1 && gap < 240 {
                networkDrops += gap - 1
                awaitingKeyframe = true
                askKeyframe()
            }
        }
        lastSequence = sequence
    }

    private func noteDisplayed(timing: FrameTiming, decodeSubmitUs: UInt64, decodedUs: UInt64, glassUs: UInt64) {
        guard timing.captureUs != 0 else { return }
        let now = CACurrentMediaTime()
        displayedTimes.append(now)
        displayedTimes.removeAll { now - $0 > 1 }
        func span(_ from: UInt64, _ to: UInt64) -> Int64 {
            Int64(bitPattern: to) - Int64(bitPattern: from)
        }
        let offset = clockOffsetUs
        stageCaptureUs = span(timing.captureUs, timing.encoderInUs)
        stageEncodeUs = span(timing.encoderInUs, timing.encoderOutUs)
        stageQueueUs = span(timing.encoderOutUs, timing.sendUs)
        stageNetworkUs = (Int64(bitPattern: timing.recvUs) + offset) - Int64(bitPattern: timing.sendUs)
        stageDecodeUs = span(decodeSubmitUs, decodedUs)
        stageGlassUs = span(decodedUs, glassUs)
        let latencyUs = Int64(bitPattern: glassUs) + offset - Int64(bitPattern: timing.captureUs)
        if latencyUs > 0 && latencyUs < 2_000_000 {
            lastLatencyMs = Double(latencyUs) / 1000.0
        }
        if now - lastStageLog >= 1 {
            lastStageLog = now
            let suspect = clockSuspect ? 1 : 0
            lanLog.info("cap \(self.stageCaptureUs / 1000, privacy: .public) enc \(self.stageEncodeUs / 1000, privacy: .public) tx \(self.stageQueueUs / 1000, privacy: .public) rede \(self.stageNetworkUs / 1000, privacy: .public) dec \(self.stageDecodeUs / 1000, privacy: .public) vidro \(self.stageGlassUs / 1000, privacy: .public) total \(latencyUs / 1000, privacy: .public) off \(offset / 1000, privacy: .public) rtt \(self.rttUs / 1000, privacy: .public) relogio \(suspect, privacy: .public)")
        }
        emitStats(bufferDepth: bufferDepth())
    }

    private func noteReceived() {
        let now = CACurrentMediaTime()
        receivedTimes.append(now)
        receivedTimes.removeAll { now - $0 > 1 }
    }

    private func isSmooth() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return smoothPlayback
    }

    private func bufferDepth() -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return jitter.count
    }

    private func hold(
        _ sample: CMSampleBuffer,
        keyframe: Bool,
        timing: FrameTiming,
        sequence: UInt16,
        ptsUs: UInt64,
        flushBefore: Bool
    ) {
        let frame = HeldFrame(
            sample: sample,
            keyframe: keyframe,
            timing: timing,
            sequence: sequence,
            ptsUs: ptsUs,
            flushBefore: flushBefore
        )
        stateLock.lock()
        jitter.append(frame)
        if jitter.count > 30 {
            let removed = jitter.count
            jitter.removeAll()
            displayDrops += removed
            awaitingKeyframe = true
            paceAnchorLocal = nil
            paceAnchorPtsUs = nil
        }
        let depth = jitter.count
        stateLock.unlock()
        emitStats(bufferDepth: depth)
    }

    /// Release every frame whose source PTS is due. 59.94 and 60 share this
    /// clock, so a fixed 16.7 ms gate is not used: that gate, plus dropping a
    /// frame when the layer was busy, was presenting ~7 fps fewer than arrived.
    private func pace() {
        let now = CACurrentMediaTime()
        stateLock.lock()
        guard smoothPlayback else {
            stateLock.unlock()
            return
        }
        var batch: [HeldFrame] = []
        while let frame = jitter.first {
            let due = dueTimeLocked(now: now, frame: frame)
            if now + 0.002 < due {
                break
            }
            batch.append(jitter.removeFirst())
        }
        stateLock.unlock()
        guard !batch.isEmpty else { return }
        var pending = batch
        while !pending.isEmpty {
            switch presentHeld(pending[0]) {
            case .shown:
                pending.removeFirst()
            case .skipped:
                pending.removeFirst()
                var droppedDependents = 1
                while !pending.isEmpty && !pending[0].keyframe {
                    pending.removeFirst()
                    droppedDependents += 1
                }
                stateLock.lock()
                while let next = jitter.first, !next.keyframe {
                    jitter.removeFirst()
                    droppedDependents += 1
                }
                let recovered = pending.contains { $0.keyframe } || jitter.contains { $0.keyframe }
                let depth = jitter.count
                stateLock.unlock()
                let lost = droppedDependents
                queue.async {
                    self.waitingForKeyframe += lost
                    if !recovered {
                        self.awaitingKeyframe = true
                    }
                    self.emitStats(bufferDepth: depth)
                }
            case .notReady:
                stateLock.lock()
                jitter.insert(contentsOf: pending, at: 0)
                stateLock.unlock()
                return
            }
        }
    }

    private func dueTimeLocked(now: CFTimeInterval, frame: HeldFrame) -> CFTimeInterval {
        if let anchorLocal = paceAnchorLocal, let anchorPts = paceAnchorPtsUs {
            let delta = Double(Int64(bitPattern: frame.ptsUs) - Int64(bitPattern: anchorPts)) / 1_000_000.0
            if delta < -0.5 || delta > 5 {
                paceAnchorLocal = now
                paceAnchorPtsUs = frame.ptsUs
                return now
            }
            return anchorLocal + delta
        }
        paceAnchorLocal = now
        paceAnchorPtsUs = frame.ptsUs
        return now
    }

    private enum PresentResult {
        case shown
        case skipped
        case notReady
    }

    private func presentHeld(_ frame: HeldFrame) -> PresentResult {
        guard let layer = display?.sampleLayer else { return .notReady }
        if layer.status == .failed {
            layer.flush()
            queue.async { self.decoderErrors += 1 }
            guard frame.keyframe else { return .skipped }
        } else if frame.flushBefore {
            layer.flush()
        }
        guard layer.isReadyForMoreMediaData else { return .notReady }
        layer.enqueue(frame.sample)
        let displayedAt = Self.nowUs()
        let glassUs = predictedGlassUs()
        let timing = frame.timing
        queue.async {
            self.noteDisplayed(timing: timing, decodeSubmitUs: displayedAt, decodedUs: displayedAt, glassUs: glassUs)
        }
        return .shown
    }

    private func decodeAndShow(_ sample: CMSampleBuffer, timing: FrameTiming) {
        let submit = Self.nowUs()
        let status = pixelDecoder.decode(sample) { [weak self] buffer in
            let decoded = Self.nowUs()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.display?.showPixel(buffer)
                let glassUs = self.predictedGlassUs()
                self.queue.async {
                    self.noteDisplayed(timing: timing, decodeSubmitUs: submit, decodedUs: decoded, glassUs: glassUs)
                }
            }
        }
        if status != noErr {
            decoderErrors += 1
            awaitingKeyframe = true
            askKeyframe()
        }
    }

    private func predictedGlassUs() -> UInt64 {
        let nowMedia = CACurrentMediaTime()
        let target = pacer.targetTimestamp ?? nowMedia
        let delta = max(0, target - nowMedia)
        return Self.nowUs() + UInt64(delta * 1_000_000)
    }

    private func askKeyframe() {
        let now = CACurrentMediaTime()
        guard now - lastKeyframeAsk > 0.1, let connection else { return }
        lastKeyframeAsk = now
        send(LanWire.keyframeRequest(), on: connection)
    }

    private func openUdp(to endpoint: NWEndpoint) {
        if let current = udpConnection, current.state == .ready || current.state == .preparing {
            current.send(content: LanUdp.bindPacket(), completion: .idempotent)
            return
        }
        udpConnection?.cancel()
        udpConnection = nil
        let connection = NWConnection(to: endpoint, using: udpParameters())
        udpConnection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state {
                connection.send(content: LanUdp.bindPacket(), completion: .idempotent)
                self.receiveUdp(on: connection)
            }
        }
        connection.start(queue: queue)
    }

    private func receiveUdp(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.ingestUdp(data)
            }
            if error != nil { return }
            if self.udpConnection === connection {
                self.receiveUdp(on: connection)
            }
        }
    }

    private func ingestUdp(_ data: Data) {
        let result = udpReassembler.add(data)
        if result.droppedIncomplete {
            awaitingKeyframe = true
            waitingForKeyframe += 1
            askKeyframe()
        }
        guard let frame = result.frame, !frame.nalus.isEmpty else { return }
        deliver(
            nalus: frame.nalus,
            keyframe: frame.keyframe,
            sequence: frame.frameId,
            ptsUs: 0,
            timing: FrameTiming(
                captureUs: frame.timing.captureUs,
                encoderInUs: frame.timing.encoderInUs,
                encoderOutUs: frame.timing.encoderOutUs,
                sendUs: frame.timing.sendUs,
                recvUs: Self.nowUs()
            ),
            direct: true
        )
    }

    private func udpParameters() -> NWParameters {
        let parameters = NWParameters.udp
        parameters.serviceClass = .interactiveVideo
        parameters.includePeerToPeer = true
        return parameters
    }

    private func emitStats(bufferDepth: Int) {
        let now = CACurrentMediaTime()
        guard now - lastStats >= 0.25 else { return }
        lastStats = now
        emit(event: [
            "type": "stats",
            "fps": Double(receivedTimes.count),
            "displayedFps": Double(displayedTimes.count),
            "latencyMs": lastLatencyMs,
            "dropped": networkDrops,
            "receiverDrops": displayDrops,
            "bufferDepth": bufferDepth,
            "decoderErrors": decoderErrors,
            "waitingKeyframe": waitingForKeyframe,
            "bitrateMbps": configuredBitrateMbps,
            "maxFrameQp": configuredMaxQp,
            "stageCaptureMs": Self.ms(stageCaptureUs),
            "stageEncodeMs": Self.ms(stageEncodeUs),
            "stageQueueMs": Self.ms(stageQueueUs),
            "stageNetworkMs": Self.ms(stageNetworkUs),
            "stageDecodeMs": Self.ms(stageDecodeUs),
            "stageGlassMs": Self.ms(stageGlassUs),
            "offsetMs": Double(clockOffsetUs) / 1000.0,
            "rttMs": Double(rttUs) / 1000.0,
            "clockSkew": clockSuspect ? 1 : 0,
        ])
    }

    private func startPing() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            guard let self, let connection = self.connection else { return }
            self.send(LanWire.ping(clientTimeUs: Self.nowUs()), on: connection)
        }
        timer.resume()
        pingTimer = timer
    }

    private func send(_ data: Data, on connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func tcpParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.serviceClass = .interactiveVideo
        return parameters
    }

    private func emitState(phase: String, detail: String?) {
        var event: [String: Any] = ["type": "state", "phase": phase]
        event["detail"] = detail ?? NSNull()
        emit(event: event)
    }

    private func emit(event: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            self?.eventSink?(event)
        }
    }

    private static func nowUs() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1_000_000)
    }

    private static func ms(_ us: Int64) -> Double {
        us < 0 ? -1 : Double(us) / 1000.0
    }
}

struct FrameTiming {
    var captureUs: UInt64 = 0
    var encoderInUs: UInt64 = 0
    var encoderOutUs: UInt64 = 0
    var sendUs: UInt64 = 0
    var recvUs: UInt64 = 0

    static let zero = FrameTiming()
}

private struct HeldFrame {
    let sample: CMSampleBuffer
    let keyframe: Bool
    let timing: FrameTiming
    let sequence: UInt16
    let ptsUs: UInt64
    let flushBefore: Bool
}

private final class DisplayPacer: NSObject {
    var onTick: (() -> Void)?
    private var link: CADisplayLink?
    var targetTimestamp: CFTimeInterval? { link?.targetTimestamp }

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        // Poll at the panel rate, up to 120 Hz. A preferred 60 with a floor of
        // 30 let ProMotion drift under the 59.94 source and the pacer then
        // discarded the frames it could not show on that tick.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick() {
        onTick?()
    }
}

private final class PixelDecoder {
    var onBuffer: ((CVPixelBuffer) -> Void)?
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?

    func update(format: CMVideoFormatDescription) {
        if let current = self.format, CMFormatDescriptionEqual(current, otherFormatDescription: format) {
            return
        }
        invalidate()
        self.format = format
        let attributes: [NSString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refcon, _, status, _, imageBuffer, _, _ in
                guard let refcon, status == noErr, let imageBuffer else { return }
                let decoder = Unmanaged<PixelDecoder>.fromOpaque(refcon).takeUnretainedValue()
                decoder.onBuffer?(imageBuffer)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &created
        )
        guard status == noErr, let created else {
            self.session = nil
            return
        }
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = created
    }

    func decode(_ sample: CMSampleBuffer, onImage: @escaping (CVPixelBuffer) -> Void) -> OSStatus {
        guard let session else { return -1 }
        onBuffer = onImage
        var flags = VTDecodeInfoFlags()
        return VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: [],
            frameRefcon: nil,
            infoFlagsOut: &flags
        )
    }

    func invalidate() {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        format = nil
    }
}
