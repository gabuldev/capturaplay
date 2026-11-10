import AVFoundation
import CoreMedia
import Foundation
import Network
import os
import VideoToolbox

private let lanLog = Logger(subsystem: "dev.capturaplay.capturaplay", category: "lan")

/// Hardware H.264 sender. It is a `CaptureMediaSink`, so the preview layer
/// stays on the capture clock. Sample buffers are retained and encoded on a
/// separate queue; if that queue is busy the frame is dropped instead of
/// being buffered.
final class LanSender: NSObject, CaptureMediaSink {
    var onStatus: ((Bool, Int, String?, String?) -> Void)?

    private let encodeQueue = DispatchQueue(label: "dev.capturaplay.lan.encode", qos: .userInteractive)
    private let networkQueue = DispatchQueue(label: "dev.capturaplay.lan.net", qos: .userInteractive)
    private let stateLock = NSLock()

    private var listener: NWListener?
    private var udpListener: NWListener?
    private var connection: NWConnection?
    private var udpPeer: NWConnection?
    private var lastStageLog = CFTimeInterval(0)
    private var lastVideoSend = CFTimeInterval(0)
    private var keepalive: DispatchSourceTimer?
    private var pathMonitor: NWPathMonitor?
    private var awdlUp = false
    private var txGapUntil = CFTimeInterval(0)
    private var statusHint: String?
    private var listeningClients = 0
    private var parser = LanStreamParser()
    private var pendingSends = 0
    private var dropUntilKeyframe = false
    private var frameSequence: UInt16 = 0
    private var compression: VTCompressionSession?
    private var sessionWidth = 0
    private var sessionHeight = 0
    private var inFlight = 0
    private var needKeyframe = true
    private var cachedConfig: Data?
    private var listening = false

    private(set) var requestedHeight = 1080
    var bitrate = 20_000_000
    private var maxFrameQP = 32
    var lowLatency = true
    private var smoothPlayback = true

    var wantsVideoSamples: Bool { true }
    // Audio stays on AVCaptureAudioPreviewOutput. Adding an audio data output
    // here would change the local monitoring path. TODO: AAC if we can do it
    // without touching that preview.
    var wantsAudioSamples: Bool { false }

    func consumeAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {}

    func update(bitrateMbps: Int, height: Int, lowLatency: Bool, smooth: Bool) {
        let cappedHeight = height <= 720 ? 720 : 1080
        let cappedBitrate = min(max(bitrateMbps, 10), 30) * 1_000_000
        stateLock.lock()
        let smoothChanged = smoothPlayback != smooth
        smoothPlayback = smooth
        stateLock.unlock()
        encodeQueue.async {
            let sizeChanged = self.requestedHeight != cappedHeight
            let modeChanged = self.lowLatency != lowLatency || smoothChanged
            self.requestedHeight = cappedHeight
            self.bitrate = cappedBitrate
            self.lowLatency = lowLatency
            if sizeChanged || modeChanged {
                self.invalidateEncoderLocked()
            } else if let session = self.compression {
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: self.bitrate as CFNumber)
            }
        }
        if smoothChanged {
            networkQueue.async {
                let udp = !self.isSmooth() && self.udpPeer != nil
                self.writeTcp(LanWire.transport(udp: udp), important: true, isKeyframe: false)
                self.requestKeyframe()
            }
        }
    }

    func startListening() {
        networkQueue.async {
            guard !self.listening else { return }
            self.listening = true
            do {
                let parameters = self.tcpParameters()
                let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: LanLimits.port)!)
                listener.service = NWListener.Service(name: "CapturaPlay", type: LanLimits.serviceType)
                listener.stateUpdateHandler = { [weak self] state in
                    self?.handleListener(state)
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.start(queue: self.networkQueue)
                self.listener = listener
                self.startUdpListener()
                self.startPathMonitor()
                self.startKeepalive()
            } catch {
                lanLog.error("Não abriu a porta \(LanLimits.port, privacy: .public): \(error.localizedDescription, privacy: .public)")
                self.publish(enabled: false, clients: 0, error: "Não foi possível abrir a porta \(LanLimits.port).")
            }
        }
    }

    func stop() {
        networkQueue.async {
            self.listening = false
            self.connection?.cancel()
            self.connection = nil
            self.udpPeer?.cancel()
            self.udpPeer = nil
            self.listener?.cancel()
            self.listener = nil
            self.udpListener?.cancel()
            self.udpListener = nil
            self.keepalive?.cancel()
            self.keepalive = nil
            self.pathMonitor?.cancel()
            self.pathMonitor = nil
            self.awdlUp = false
            self.statusHint = nil
            self.parser.reset()
            self.pendingSends = 0
            self.stateLock.lock()
            self.cachedConfig = nil
            self.stateLock.unlock()
            self.publish(enabled: false, clients: 0, error: nil)
        }
        encodeQueue.async {
            self.invalidateEncoderLocked()
            self.inFlight = 0
            self.requestKeyframe()
        }
    }

    func consumeVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let received = CACurrentMediaTime()
        let captureHostUs = Self.hostUs()
        stateLock.lock()
        let encodeLimit = smoothPlayback ? 2 : 1
        let busy = inFlight >= encodeLimit
        if !busy { inFlight += 1 }
        stateLock.unlock()
        guard !busy else {
            noteDropAndRequestKeyframe()
            return
        }
        encodeQueue.async { [weak self] in
            self?.encode(pixelBuffer, pts: pts, received: received, captureHostUs: captureHostUs)
        }
    }

    private func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime, received: CFTimeInterval, captureHostUs: UInt64) {
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        let target = targetSize(sourceWidth: sourceWidth, sourceHeight: sourceHeight)
        if compression == nil || sessionWidth != target.0 || sessionHeight != target.1 {
            invalidateEncoderLocked()
            guard createEncoder(width: target.0, height: target.1) else {
                finishFrame()
                return
            }
        }
        guard let compression else {
            finishFrame()
            return
        }
        let encoderInUs = Self.hostUs()
        let token = FrameToken(received: received, captureHostUs: captureHostUs, encoderInUs: encoderInUs)
        let refcon = Unmanaged.passRetained(token).toOpaque()
        var flags = VTEncodeInfoFlags()
        let force = takeKeyframeRequest()
        let properties: NSDictionary? = force
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true]
            : nil
        let status = VTCompressionSessionEncodeFrame(
            compression,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: properties as CFDictionary?,
            sourceFrameRefcon: refcon,
            infoFlagsOut: &flags
        )
        if status != noErr {
            Unmanaged<FrameToken>.fromOpaque(refcon).release()
            finishFrame()
            lanLog.error("EncodeFrame falhou: \(status, privacy: .public)")
            return
        }
        // Ultra keeps a single encode in flight. Without this flush, VideoToolbox
        // holds the frame until the next EncodeFrame, which never comes, and the
        // picture sits for about 100 ms. Suave flushes too; it does not add delay.
        VTCompressionSessionCompleteFrames(compression, untilPresentationTimeStamp: .invalid)
    }

    private func createEncoder(width: Int, height: Int) -> Bool {
        var session: VTCompressionSession?
        let callback: VTCompressionOutputCallback = { refcon, sourceFrameRefcon, status, _, sampleBuffer in
            guard let refcon else { return }
            let sender = Unmanaged<LanSender>.fromOpaque(refcon).takeUnretainedValue()
            sender.handleEncoded(status: status, sampleBuffer: sampleBuffer, sourceFrameRefcon: sourceFrameRefcon)
        }
        let spec = NSMutableDictionary()
        spec[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder] = true
        spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true
        var status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: callback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )
        if status != noErr || session == nil {
            status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: Int32(width),
                height: Int32(height),
                codecType: kCMVideoCodecType_H264,
                encoderSpecification: nil,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: callback,
                refcon: Unmanaged.passUnretained(self).toOpaque(),
                compressionSessionOut: &session
            )
        }
        guard status == noErr, let session else {
            publish(enabled: listening, clients: connection == nil ? 0 : 1, error: "O encoder H.264 não iniciou.")
            return false
        }
        let bitrate = self.bitrate
        let smooth = self.isSmooth()
        let interval = smooth ? 120 : 8
        let profile = smooth
            ? kVTProfileLevel_H264_High_AutoLevel
            : kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        let profileStatus = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: profile)
        if profileStatus != noErr {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: interval as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: (smooth ? 2.0 : 0.15) as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        let maxQP = smooth ? 32 : 38
        self.maxFrameQP = maxQP
        if #available(macOS 13.0, *) {
            _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxAllowedFrameQP, value: maxQP as CFNumber)
        }
        let delayStatus = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        if delayStatus != noErr {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 1 as CFNumber)
            lanLog.error("MaxFrameDelayCount 0 recusado (\(delayStatus, privacy: .public)); ficou em 1")
        } else {
            lanLog.info("MaxFrameDelayCount 0 aplicado")
        }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
        VTCompressionSessionPrepareToEncodeFrames(session)
        compression = session
        sessionWidth = width
        sessionHeight = height
        requestKeyframe()
        return true
    }

    private func invalidateEncoderLocked() {
        if let compression {
            VTCompressionSessionInvalidate(compression)
        }
        compression = nil
        sessionWidth = 0
        sessionHeight = 0
    }

    private func handleEncoded(status: OSStatus, sampleBuffer: CMSampleBuffer?, sourceFrameRefcon: UnsafeMutableRawPointer?) {
        defer { finishFrame() }
        let token: FrameToken?
        if let sourceFrameRefcon {
            token = Unmanaged<FrameToken>.fromOpaque(sourceFrameRefcon).takeRetainedValue()
        } else {
            token = nil
        }
        let received = token?.received ?? CACurrentMediaTime()
        let captureHostUs = token?.captureHostUs ?? Self.hostUs()
        let encoderInUs = token?.encoderInUs ?? captureHostUs
        guard status == noErr, let sampleBuffer else { return }
        let latencyUs = UInt32(max(0, (CACurrentMediaTime() - received) * 1_000_000))
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let nalus = dataBuffer(of: sampleBuffer) else { return }
        if let config = configMessage(from: format) {
            stateLock.lock()
            let changed = config != cachedConfig
            if changed { cachedConfig = config }
            stateLock.unlock()
            if changed { send(config, important: true) }
        }
        let keyframe = isKeyframe(sampleBuffer)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let ptsUs = pts.isValid && pts.timescale != 0
            ? UInt64(max(0, CMTimeConvertScale(pts, timescale: 1_000_000, method: .roundHalfAwayFromZero).value))
            : 0
        let sequence = nextSequence()
        let encoderOutUs = Self.hostUs()
        emitVideo(
            keyframe: keyframe,
            sequence: sequence,
            ptsUs: ptsUs,
            senderLatencyUs: latencyUs,
            captureHostUs: captureHostUs,
            encoderInUs: encoderInUs,
            encoderOutUs: encoderOutUs,
            nalus: nalus
        )
    }

    private func configMessage(from format: CMFormatDescription) -> Data? {
        var spsPointer: UnsafePointer<UInt8>?
        var spsSize = 0
        var ppsPointer: UnsafePointer<UInt8>?
        var ppsSize = 0
        var count = 0
        let spsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format,
            parameterSetIndex: 0,
            parameterSetPointerOut: &spsPointer,
            parameterSetSizeOut: &spsSize,
            parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: nil
        )
        let ppsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format,
            parameterSetIndex: 1,
            parameterSetPointerOut: &ppsPointer,
            parameterSetSizeOut: &ppsSize,
            parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: nil
        )
        guard spsStatus == noErr, ppsStatus == noErr, let spsPointer, let ppsPointer, spsSize > 0, ppsSize > 0 else {
            return nil
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let sps = Data(bytes: spsPointer, count: spsSize)
        let pps = Data(bytes: ppsPointer, count: ppsSize)
        return LanWire.videoConfig(
            width: Int(dimensions.width),
            height: Int(dimensions.height),
            fpsMilli: 60000,
            sps: sps,
            pps: pps,
            bitrateMbps: max(1, self.bitrate / 1_000_000),
            maxFrameQp: self.maxFrameQP
        )
    }

    private func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else {
            return true
        }
        return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    }

    private func dataBuffer(of sampleBuffer: CMSampleBuffer) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
        guard status == kCMBlockBufferNoErr, let pointer, length > 0 else { return nil }
        return Data(bytes: pointer, count: length)
    }

    private func targetSize(sourceWidth: Int, sourceHeight: Int) -> (Int, Int) {
        let capHeight = requestedHeight >= 1080 ? 1080 : 720
        let capWidth = capHeight == 1080 ? 1920 : 1280
        guard sourceWidth > 0, sourceHeight > 0 else { return (capWidth, capHeight) }
        if sourceHeight <= capHeight && sourceWidth <= capWidth {
            return (max(2, sourceWidth & ~1), max(2, sourceHeight & ~1))
        }
        let width = sourceWidth * capHeight / sourceHeight
        return (max(2, width & ~1), capHeight)
    }

    private func isSmooth() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return smoothPlayback
    }

    private func requestKeyframe() {
        stateLock.lock()
        needKeyframe = true
        stateLock.unlock()
    }

    private func takeKeyframeRequest() -> Bool {
        stateLock.lock()
        let value = needKeyframe
        needKeyframe = false
        stateLock.unlock()
        return value
    }

    private func finishFrame() {
        stateLock.lock()
        if inFlight > 0 { inFlight -= 1 }
        stateLock.unlock()
    }

    private func handleListener(_ state: NWListener.State) {
        switch state {
        case .ready:
            publish(enabled: true, clients: connection == nil ? 0 : 1, error: nil)
        case let .failed(error):
            lanLog.error("Listener falhou: \(error.localizedDescription, privacy: .public)")
            publish(enabled: false, clients: 0, error: "A transmissão na rede parou.")
        case .cancelled:
            break
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        self.connection?.cancel()
        parser.reset()
        pendingSends = 0
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.markInteractive(connection)
                self.requestKeyframe()
                self.send(LanWire.helloAck(features: LanFeatures.video | LanFeatures.udp), important: true)
                self.send(LanWire.transport(udp: false), important: true)
                self.stateLock.lock()
                let config = self.cachedConfig
                self.stateLock.unlock()
                if let config {
                    self.send(config, important: true)
                }
                self.receive(on: connection)
                self.publish(enabled: true, clients: 1, error: nil)
            case .failed, .cancelled:
                if self.connection === connection {
                    self.connection = nil
                    self.publish(enabled: self.listening, clients: 0, error: nil)
                }
            default:
                break
            }
        }
        connection.start(queue: networkQueue)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
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
            let messages = try parser.add(data)
            for message in messages {
                switch message.type {
                case LanType.ping:
                    let serverRecv = Self.hostUs()
                    if let clientTime = LanWire.pingTime(of: message.payload) {
                        let serverSend = Self.hostUs()
                        send(
                            LanWire.pong(
                                clientTimeUs: clientTime,
                                serverRecvUs: serverRecv,
                                serverSendUs: serverSend
                            ),
                            important: true,
                            isKeyframe: false
                        )
                    }
                case LanType.input:
                    // Reserved for a later controller. Do not buffer or act on it.
                    break
                case LanType.keyframeRequest:
                    requestKeyframe()
                case LanType.bye:
                    connection?.cancel()
                default:
                    break
                }
            }
        } catch {
            connection?.cancel()
        }
    }

    private func emitVideo(
        keyframe: Bool,
        sequence: UInt16,
        ptsUs: UInt64,
        senderLatencyUs: UInt32,
        captureHostUs: UInt64,
        encoderInUs: UInt64,
        encoderOutUs: UInt64,
        nalus: Data
    ) {
        networkQueue.async {
            let sendUs = Self.hostUs()
            self.noteSendGap()
            self.logSenderStages(captureUs: captureHostUs, encoderInUs: encoderInUs, encoderOutUs: encoderOutUs, sendUs: sendUs)
            if self.isSmooth() {
                let message = LanWire.videoFrame(
                    keyframe: keyframe,
                    sequence: sequence,
                    ptsUs: ptsUs,
                    senderLatencyUs: senderLatencyUs,
                    captureHostUs: captureHostUs,
                    encoderInUs: encoderInUs,
                    encoderOutUs: encoderOutUs,
                    sendUs: sendUs,
                    nalus: nalus
                )
                self.writeTcp(message, important: false, isKeyframe: keyframe)
                return
            }
            guard let peer = self.udpPeer else {
                let message = LanWire.videoFrame(
                    keyframe: keyframe,
                    sequence: sequence,
                    ptsUs: ptsUs,
                    senderLatencyUs: senderLatencyUs,
                    captureHostUs: captureHostUs,
                    encoderInUs: encoderInUs,
                    encoderOutUs: encoderOutUs,
                    sendUs: sendUs,
                    nalus: nalus
                )
                self.writeTcp(message, important: false, isKeyframe: keyframe)
                return
            }
            let timing = UdpTiming(
                captureUs: captureHostUs,
                encoderInUs: encoderInUs,
                encoderOutUs: encoderOutUs,
                sendUs: sendUs
            )
            self.markInteractive(peer)
            for packet in LanUdp.packets(frameId: sequence, keyframe: keyframe, timing: timing, nalus: nalus) {
                peer.send(content: packet, completion: .idempotent)
            }
        }
    }

    private func logSenderStages(captureUs: UInt64, encoderInUs: UInt64, encoderOutUs: UInt64, sendUs: UInt64) {
        let now = CACurrentMediaTime()
        guard now - lastStageLog >= 1 else { return }
        lastStageLog = now
        let cap = Int64(bitPattern: encoderInUs) - Int64(bitPattern: captureUs)
        let enc = Int64(bitPattern: encoderOutUs) - Int64(bitPattern: encoderInUs)
        let tx = Int64(bitPattern: sendUs) - Int64(bitPattern: encoderOutUs)
        let udp = !self.isSmooth()
        lanLog.info("Mac cap→enc \(cap / 1000, privacy: .public)ms enc \(enc / 1000, privacy: .public)ms tx \(tx / 1000, privacy: .public)ms udp \(udp, privacy: .public)")
    }

    private func send(_ data: Data, important: Bool, isKeyframe: Bool = false) {
        networkQueue.async {
            self.writeTcp(data, important: important, isKeyframe: isKeyframe)
        }
    }

    private func writeTcp(_ data: Data, important: Bool, isKeyframe: Bool) {
            guard let connection = self.connection else { return }
            if !important {
                let limit = self.isSmooth() ? 3 : 1
                if self.pendingSends >= limit {
                    self.dropUntilKeyframe = true
                    self.requestKeyframe()
                    return
                }
                if self.dropUntilKeyframe && !isKeyframe {
                    self.requestKeyframe()
                    return
                }
                if isKeyframe {
                    self.dropUntilKeyframe = false
                }
                self.pendingSends += 1
                connection.send(content: data, completion: .contentProcessed { [weak self] _ in
                    self?.networkQueue.async {
                        guard let self else { return }
                        if self.pendingSends > 0 { self.pendingSends -= 1 }
                    }
                })
                return
            }
            connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func startUdpListener() {
        do {
            let listener = try NWListener(using: udpParameters(), on: NWEndpoint.Port(rawValue: LanLimits.port)!)
            listener.stateUpdateHandler = { state in
                if case let .failed(error) = state {
                    lanLog.error("UDP falhou: \(error.localizedDescription, privacy: .public)")
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.acceptUdp(connection)
            }
            listener.start(queue: networkQueue)
            udpListener = listener
        } catch {
            lanLog.error("Não abriu UDP \(LanLimits.port, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func acceptUdp(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state {
                self.markInteractive(connection)
            }
        }
        connection.start(queue: networkQueue)
        receiveUdp(on: connection)
    }

    private func receiveUdp(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, LanUdp.isBind(data) {
                if self.udpPeer !== connection {
                    self.udpPeer?.cancel()
                    self.udpPeer = connection
                }
                lanLog.info("iPhone abriu o UDP")
                self.markInteractive(connection)
                let udp = !self.isSmooth()
                self.writeTcp(LanWire.transport(udp: udp), important: true, isKeyframe: false)
                self.requestKeyframe()
            }
            if let error {
                lanLog.error("UDP recv: \(error.localizedDescription, privacy: .public)")
                if self.udpPeer === connection {
                    self.udpPeer = nil
                    self.writeTcp(LanWire.transport(udp: false), important: true, isKeyframe: false)
                }
                return
            }
            self.receiveUdp(on: connection)
        }
    }

    private func udpParameters() -> NWParameters {
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = true
        parameters.allowLocalEndpointReuse = true
        parameters.serviceClass = .interactiveVideo
        return parameters
    }

    private func tcpParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true
        parameters.serviceClass = .interactiveVideo
        return parameters
    }

    private func noteDropAndRequestKeyframe() {
        networkQueue.async {
            self.dropUntilKeyframe = true
            self.requestKeyframe()
        }
    }

    private func nextSequence() -> UInt16 {
        stateLock.lock()
        let value = frameSequence
        frameSequence &+= 1
        stateLock.unlock()
        return value
    }

    private static func hostUs() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1_000_000)
    }

    private func publish(enabled: Bool, clients: Int, error: String?) {
        listeningClients = clients
        let hint = statusHint
        DispatchQueue.main.async { [weak self] in
            self?.onStatus?(enabled, clients, error, hint)
        }
    }

    private func noteSendGap() {
        let now = CACurrentMediaTime()
        if lastVideoSend > 0 {
            let gapMs = (now - lastVideoSend) * 1000
            if gapMs > 50 {
                lanLog.info("intervalo de envio \(Int(gapMs), privacy: .public)ms — o Mac segurou o quadro antes do socket (AWDL/AirDrop costuma ser ~100ms)")
                txGapUntil = now + 5
                refreshHint()
            }
        }
        lastVideoSend = now
    }

    private func startKeepalive() {
        guard keepalive == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: networkQueue)
        timer.schedule(deadline: .now() + .milliseconds(4), repeating: .milliseconds(4))
        timer.setEventHandler { [weak self] in
            guard let self, let peer = self.udpPeer, !self.isSmooth() else { return }
            peer.send(content: LanUdp.keepalivePacket(), completion: .idempotent)
        }
        timer.resume()
        keepalive = timer
    }

    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let awdl = path.availableInterfaces.contains { $0.name == "awdl0" }
            self.awdlUp = awdl
            if awdl {
                lanLog.info("awdl0 está na lista de interfaces. AirDrop/Continuity/Sidecar podem tirar o rádio do canal por ~100 ms. O app não desliga isso.")
            }
            self.refreshHint()
        }
        monitor.start(queue: networkQueue)
        pathMonitor = monitor
    }

    private func refreshHint() {
        let now = CACurrentMediaTime()
        let next: String?
        if now < txGapUntil {
            next = awdlUp
                ? "Envio pausou ~100 ms. AWDL (AirDrop) está ativo — desligue o AirDrop."
                : "Envio pausou ~100 ms antes do socket."
        } else {
            next = nil
        }
        guard next != statusHint else { return }
        statusHint = next
        publish(enabled: listening, clients: listeningClients, error: nil)
    }

    private func markInteractive(_ connection: NWConnection) {
        let metadata = connection.metadata(definition: NWProtocolIP.definition)
        if let ip = metadata as? NWProtocolIP.Metadata {
            ip.serviceClass = .interactiveVideo
        }
    }
}

private final class FrameToken {
    let received: CFTimeInterval
    let captureHostUs: UInt64
    let encoderInUs: UInt64
    init(received: CFTimeInterval, captureHostUs: UInt64, encoderInUs: UInt64) {
        self.received = received
        self.captureHostUs = captureHostUs
        self.encoderInUs = encoderInUs
    }
}
