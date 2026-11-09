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
    var onStatus: ((Bool, Int, String?) -> Void)?

    private let encodeQueue = DispatchQueue(label: "dev.capturaplay.lan.encode", qos: .userInteractive)
    private let networkQueue = DispatchQueue(label: "dev.capturaplay.lan.net", qos: .userInteractive)
    private let stateLock = NSLock()

    private var listener: NWListener?
    private var connection: NWConnection?
    private var parser = LanStreamParser()
    private var pendingSends = 0
    private var compression: VTCompressionSession?
    private var sessionWidth = 0
    private var sessionHeight = 0
    private var inFlight = 0
    private var needKeyframe = true
    private var cachedConfig: Data?
    private var listening = false

    private(set) var requestedHeight = 1080
    var bitrate = 12_000_000

    var wantsVideoSamples: Bool { true }
    // Audio stays on AVCaptureAudioPreviewOutput. Adding an audio data output
    // here would change the local monitoring path. TODO: AAC if we can do it
    // without touching that preview.
    var wantsAudioSamples: Bool { false }

    func consumeAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {}

    func update(bitrateMbps: Int, height: Int) {
        let cappedHeight = height <= 720 ? 720 : 1080
        let cappedBitrate = min(max(bitrateMbps, 10), 20) * 1_000_000
        encodeQueue.async {
            let sizeChanged = self.requestedHeight != cappedHeight
            self.requestedHeight = cappedHeight
            self.bitrate = cappedBitrate
            if sizeChanged {
                self.invalidateEncoderLocked()
            } else if let session = self.compression {
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
            }
        }
    }

    func startListening() {
        networkQueue.async {
            guard !self.listening else { return }
            self.listening = true
            do {
                let tcp = NWProtocolTCP.Options()
                tcp.noDelay = true
                tcp.enableKeepalive = true
                tcp.keepaliveIdle = 2
                let parameters = NWParameters(tls: nil, tcp: tcp)
                parameters.includePeerToPeer = true
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
            self.listener?.cancel()
            self.listener = nil
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
        stateLock.lock()
        let busy = inFlight >= 1
        if !busy { inFlight += 1 }
        stateLock.unlock()
        guard !busy else { return }
        encodeQueue.async { [weak self] in
            self?.encode(pixelBuffer, pts: pts, received: received)
        }
    }

    private func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime, received: CFTimeInterval) {
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
        let token = FrameToken(received: received)
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
        }
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
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 30 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 0.5 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 1 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
        let bytesPerSecond = max(bitrate / 8, 1)
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_DataRateLimits,
            value: [bytesPerSecond, 1] as CFArray
        )
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
        let received: CFTimeInterval
        if let sourceFrameRefcon {
            received = Unmanaged<FrameToken>.fromOpaque(sourceFrameRefcon).takeRetainedValue().received
        } else {
            received = CACurrentMediaTime()
        }
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
        let message = LanWire.videoFrame(
            keyframe: keyframe,
            ptsUs: ptsUs,
            senderLatencyUs: latencyUs,
            nalus: nalus
        )
        send(message, important: keyframe)
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
            pps: pps
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
                self.requestKeyframe()
                self.send(LanWire.helloAck(features: LanFeatures.video), important: true)
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
                    if let clientTime = LanWire.pingTime(of: message.payload) {
                        let now = UInt64(Date().timeIntervalSince1970 * 1_000_000)
                        send(LanWire.pong(clientTimeUs: clientTime, serverTimeUs: now), important: true)
                    }
                case LanType.input:
                    // Reserved for a later controller. Do not buffer or act on it.
                    break
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

    private func send(_ data: Data, important: Bool) {
        networkQueue.async {
            guard let connection = self.connection else { return }
            if !important && self.pendingSends >= 2 { return }
            if self.pendingSends >= 4 { return }
            self.pendingSends += 1
            connection.send(content: data, completion: .contentProcessed { [weak self] _ in
                self?.networkQueue.async {
                    if let self, self.pendingSends > 0 { self.pendingSends -= 1 }
                }
            })
        }
    }

    private func publish(enabled: Bool, clients: Int, error: String?) {
        DispatchQueue.main.async { [weak self] in
            self?.onStatus?(enabled, clients, error)
        }
    }
}

private final class FrameToken {
    let received: CFTimeInterval
    init(received: CFTimeInterval) {
        self.received = received
    }
}
