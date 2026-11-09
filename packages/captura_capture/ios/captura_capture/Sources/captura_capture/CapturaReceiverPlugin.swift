import AVFoundation
import CoreMedia
import Flutter
import Foundation
import Network
import UIKit
import VideoToolbox

/// iPhone receiver. Compressed H.264 goes straight to an
/// `AVSampleBufferDisplayLayer` (hardware decode + display). That is lower
/// latency than decoding into a pixel buffer and uploading a Flutter texture.
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

    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var sampleLayer: AVSampleBufferDisplayLayer {
        guard let sample = layer as? AVSampleBufferDisplayLayer else {
            preconditionFailure("DisplayHostView layer must be AVSampleBufferDisplayLayer")
        }
        return sample
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .black
        sampleLayer.videoGravity = .resizeAspect
        sampleLayer.backgroundColor = UIColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func detachFromHub() {
        hub?.detach(self)
    }
}

final class ReceiverHub {
    var eventSink: FlutterEventSink?
    private let queue = DispatchQueue(label: "dev.capturaplay.lan.recv", qos: .userInteractive)
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var parser = LanStreamParser()
    private var endpoints: [String: NWEndpoint] = [:]
    private var desired: NWEndpoint?
    private var suppressAuto = false
    private var running = false
    private var format: CMVideoFormatDescription?
    private var lastKeyframe: CMSampleBuffer?
    private weak var display: DisplayHostView?
    private var pingTimer: DispatchSourceTimer?
    private var rttUs: UInt64 = 0
    private var frameTimes: [CFTimeInterval] = []
    private var lastStats: CFTimeInterval = 0

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
        }
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
        if let lastKeyframe {
            present(lastKeyframe, keyframe: true)
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
        parser.reset()
        format = nil
        lastKeyframe = nil
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
                    applyFrame(message.payload)
                case LanType.pong:
                    if let clientTime = LanWire.pingTime(of: message.payload), message.payload.count >= 16 {
                        let now = Self.nowUs()
                        if now >= clientTime {
                            rttUs = now - clientTime
                        }
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
                if status == noErr {
                    format = description
                }
            }
        }
    }

    private func applyFrame(_ payload: Data) {
        guard let format, let prefix = LanWire.framePrefix(of: payload), !prefix.nalus.isEmpty else { return }
        var block: CMBlockBuffer?
        let length = prefix.nalus.count
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
        let copied = prefix.nalus.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }
        guard copied == kCMBlockBufferNoErr else { return }
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(prefix.ptsUs), timescale: 1_000_000),
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
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample
        )
        guard status == noErr, let sample else { return }
        markDisplayImmediately(sample)
        if prefix.keyframe {
            lastKeyframe = sample
        }
        present(sample, keyframe: prefix.keyframe)
        noteFrame(senderLatencyUs: prefix.senderLatencyUs)
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

    private func present(_ sample: CMSampleBuffer, keyframe: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let layer = self?.display?.sampleLayer else { return }
            if layer.status == .failed {
                layer.flush()
            }
            if layer.isReadyForMoreMediaData {
                layer.enqueue(sample)
            } else if keyframe {
                layer.flush()
                layer.enqueue(sample)
            }
        }
    }

    private func noteFrame(senderLatencyUs: UInt32) {
        let now = CACurrentMediaTime()
        frameTimes.append(now)
        frameTimes.removeAll { now - $0 > 1 }
        guard now - lastStats >= 0.25 else { return }
        lastStats = now
        let latencyMs = Double(senderLatencyUs) / 1000.0 + Double(rttUs) / 2000.0
        emit(event: [
            "type": "stats",
            "fps": Double(frameTimes.count),
            "latencyMs": latencyMs,
        ])
    }

    private func startPing() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
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
        return NWParameters(tls: nil, tcp: tcp)
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
}
