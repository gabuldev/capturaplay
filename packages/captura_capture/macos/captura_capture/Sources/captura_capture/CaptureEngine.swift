import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import os

private let captureLog = Logger(subsystem: "dev.capturaplay.capturaplay", category: "capture")

struct CaptureEngineError: Error {
    let code: String
    let detail: String
}

protocol CaptureEngineDelegate: AnyObject {
    func captureEngine(_ engine: CaptureEngine, didEmit event: [String: Any])
}

/// Owns the `AVCaptureSession`. Display and future encoders are clients of
/// this object, not the other way around: the preview layer only receives
/// the session, and `CaptureMediaSink` instances receive sample buffers only
/// after they register.
public final class CaptureEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    weak var delegate: CaptureEngineDelegate?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "dev.capturaplay.capture.session", qos: .userInteractive)
    private let videoQueue = DispatchQueue(label: "dev.capturaplay.capture.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "dev.capturaplay.capture.audio", qos: .userInteractive)
    private let stateLock = NSLock()
    private let preferences = PreferenceStore()

    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let audioDataOutput = AVCaptureAudioDataOutput()
    private var audioPreview: AVCaptureAudioPreviewOutput?
    private var videoDataAttached = false
    private var audioDataAttached = false
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var activeVideoId: String?
    private var storedVolume = 1.0
    private var storedMuted = false
    private var lastWarning: String?
    private var statsEnabled = false
    private var frameTimes: [CFTimeInterval] = []
    private var lastStatsSent: CFTimeInterval = 0
    private var sleepActivity: NSObjectProtocol?
    private var sinkBoxes: [ObjectIdentifier: SinkBox] = [:]

    private final class SinkBox {
        weak var sink: CaptureMediaSink?
        let wantsVideo: Bool
        let wantsAudio: Bool

        init(_ sink: CaptureMediaSink) {
            self.sink = sink
            wantsVideo = sink.wantsVideoSamples
            wantsAudio = sink.wantsAudioSamples
        }
    }

    private struct ListedFormat {
        let id: String
        let width: Int
        let height: Int
        let fps: Int
        let format: AVCaptureDevice.Format
    }

    func startDeviceNotifications() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(devicesChanged), name: AVCaptureDevice.wasConnectedNotification, object: nil)
        center.addObserver(self, selector: #selector(devicesChanged), name: AVCaptureDevice.wasDisconnectedNotification, object: nil)
        center.addObserver(self, selector: #selector(sessionRuntimeError), name: AVCaptureSession.runtimeErrorNotification, object: session)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        endSleepAssertion()
    }

    // MARK: - Sinks

    /// Flags on the sink are read once, at registration.
    public func addMediaSink(_ sink: CaptureMediaSink) {
        stateLock.lock()
        sinkBoxes[ObjectIdentifier(sink)] = SinkBox(sink)
        stateLock.unlock()
        sessionQueue.async { [weak self] in
            self?.refreshDataOutputsLocked()
        }
    }

    public func removeMediaSink(_ sink: CaptureMediaSink) {
        stateLock.lock()
        sinkBoxes.removeValue(forKey: ObjectIdentifier(sink))
        stateLock.unlock()
        sessionQueue.async { [weak self] in
            self?.refreshDataOutputsLocked()
        }
    }

    func attachPreview(_ layer: AVCaptureVideoPreviewLayer) {
        let apply = { [weak self] in
            guard let self else { return }
            if let previous = self.previewLayer, previous !== layer {
                previous.session = nil
            }
            self.previewLayer = layer
            if layer.session !== self.session {
                layer.session = self.session
            }
            self.applyPreviewConnection(layer)
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    // MARK: - Flutter-facing operations

    func snapshot(_ completion: @escaping ([String: Any]) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let payload = self.snapshotLocked()
            DispatchQueue.main.async { completion(payload) }
        }
    }

    func requestAccess(_ completion: @escaping ([String: Any]) -> Void) {
        request(.video) { [weak self] _ in
            self?.request(.audio) { [weak self] _ in
                guard let self else { return }
                DispatchQueue.main.async {
                    completion(self.authorizationMap())
                }
            }
        }
    }

    func listFormats(videoDeviceId: String, completion: @escaping (Result<[[String: Any]], CaptureEngineError>) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard let device = self.device(id: videoDeviceId, media: .video) else {
                let error = CaptureEngineError(code: "device-missing", detail: "Dispositivo de vídeo ausente.")
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            let maps: [[String: Any]] = self.listedFormats(device).map { item in
                [
                    "id": item.id,
                    "width": item.width,
                    "height": item.height,
                    "fps": item.fps,
                ]
            }
            DispatchQueue.main.async { completion(.success(maps)) }
        }
    }

    func start(
        videoId: String,
        audioId: String?,
        formatId: String,
        volume: Double,
        muted: Bool,
        audioDisabled: Bool,
        completion: @escaping (Result<[String: Any], CaptureEngineError>) -> Void
    ) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let result = self.configureLocked(
                videoId: videoId,
                audioId: audioId,
                formatId: formatId,
                volume: volume,
                muted: muted,
                audioDisabled: audioDisabled
            )
            switch result {
            case let .success(payload):
                self.emitSession(payload)
            case let .failure(error):
                captureLog.error("Falha ao abrir a captura: \(error.code, privacy: .public) \(error.detail, privacy: .public)")
                self.emitSession(self.sessionPayload(device: nil, warning: nil, errorCode: error.code, errorDetail: error.detail))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func stop(completion: @escaping () -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.stopLocked()
            self.emitSession(self.sessionPayload(device: nil, warning: nil))
            DispatchQueue.main.async { completion() }
        }
    }

    /// Used on terminate. Must not hop back to the main queue.
    func stopSynchronously() {
        sessionQueue.sync {
            stopLocked()
        }
    }

    func setVolume(_ volume: Double, completion: @escaping () -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.storedVolume = min(max(volume, 0), 1)
            self.preferences.volume = self.storedVolume
            self.applyAudioVolumeLocked()
            DispatchQueue.main.async { completion() }
        }
    }

    func setMuted(_ muted: Bool, completion: @escaping () -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.storedMuted = muted
            self.preferences.muted = muted
            self.applyAudioVolumeLocked()
            DispatchQueue.main.async { completion() }
        }
    }

    func setStatsEnabled(_ enabled: Bool) {
        stateLock.lock()
        statsEnabled = enabled
        if !enabled {
            frameTimes.removeAll()
            lastStatsSent = 0
        }
        stateLock.unlock()
        sessionQueue.async { [weak self] in
            self?.refreshDataOutputsLocked()
        }
    }

    // MARK: - Sample buffers

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoDataOutput {
            deliverVideo(sampleBuffer)
        } else if output === audioDataOutput {
            deliverAudio(sampleBuffer)
        }
    }

    private func deliverVideo(_ sampleBuffer: CMSampleBuffer) {
        for sink in currentSinks(video: true) {
            sink.consumeVideoSampleBuffer(sampleBuffer)
        }
        guard statsAreEnabled() else { return }
        let now = CACurrentMediaTime()
        stateLock.lock()
        frameTimes.append(now)
        let cutoff = now - 1
        frameTimes.removeAll { $0 < cutoff }
        let fps = Double(frameTimes.count)
        let shouldSend = now - lastStatsSent >= 0.25
        if shouldSend {
            lastStatsSent = now
        }
        stateLock.unlock()
        guard shouldSend else { return }
        var payload: [String: Any] = [
            "type": "stats",
            "fps": fps,
        ]
        if let latency = estimateLatencyMs(sampleBuffer) {
            payload["latencyMs"] = latency
        } else {
            payload["latencyMs"] = NSNull()
        }
        emit(payload)
    }

    private func deliverAudio(_ sampleBuffer: CMSampleBuffer) {
        for sink in currentSinks(video: false) {
            sink.consumeAudioSampleBuffer(sampleBuffer)
        }
    }

    // MARK: - Session configuration

    private func configureLocked(
        videoId: String,
        audioId: String?,
        formatId: String,
        volume: Double,
        muted: Bool,
        audioDisabled: Bool
    ) -> Result<[String: Any], CaptureEngineError> {
        guard let videoDevice = device(id: videoId, media: .video) else {
            return .failure(CaptureEngineError(code: "device-missing", detail: "Dispositivo de vídeo ausente."))
        }
        guard let resolved = resolve(device: videoDevice, formatId: formatId) else {
            return .failure(CaptureEngineError(code: "format-unsupported", detail: "Esse formato não está disponível neste dispositivo."))
        }

        session.beginConfiguration()
        var committed = false
        func commit() {
            if !committed {
                session.commitConfiguration()
                committed = true
            }
        }


        for input in session.inputs {
            session.removeInput(input)
        }
        if let audioPreview {
            session.removeOutput(audioPreview)
            self.audioPreview = nil
        }

        do {
            try videoDevice.lockForConfiguration()
        } catch {
            commit()
            stopLocked()
            let code = videoDevice.isInUseByAnotherApplication ? "device-busy" : "session-failed"
            return .failure(CaptureEngineError(code: code, detail: error.localizedDescription))
        }
        videoDevice.activeFormat = resolved.format
        let duration = frameDuration(for: resolved.format, fps: resolved.fps)
        videoDevice.activeVideoMinFrameDuration = duration
        videoDevice.activeVideoMaxFrameDuration = duration
        videoDevice.unlockForConfiguration()

        let videoInput: AVCaptureDeviceInput
        do {
            videoInput = try AVCaptureDeviceInput(device: videoDevice)
        } catch {
            commit()
            stopLocked()
            let code = videoDevice.isInUseByAnotherApplication ? "device-busy" : "add-input-failed"
            return .failure(CaptureEngineError(code: code, detail: error.localizedDescription))
        }
        guard session.canAddInput(videoInput) else {
            commit()
            stopLocked()
            let code = videoDevice.isInUseByAnotherApplication ? "device-busy" : "add-input-failed"
            return .failure(CaptureEngineError(code: code, detail: "A sessão recusou a entrada de vídeo."))
        }
        session.addInput(videoInput)

        var warning: String?
        if !audioDisabled, let audioId {
            warning = attachAudioLocked(audioId: audioId, volume: volume, muted: muted)
        }

        commit()
        refreshDataOutputsLocked()

        if !session.isRunning {
            session.startRunning()
        }
        guard session.isRunning else {
            captureLog.error("A sessão não entrou em execução.")
            stopLocked()
            return .failure(CaptureEngineError(code: "session-failed", detail: "A sessão de captura não iniciou."))
        }

        activeVideoId = videoId
        storedVolume = min(max(volume, 0), 1)
        storedMuted = muted
        lastWarning = warning
        applyAudioVolumeLocked()
        beginSleepAssertion()
        configurePreviewLayer()

        preferences.videoDeviceId = videoId
        preferences.formatId = formatId
        preferences.volume = storedVolume
        preferences.muted = muted
        preferences.audioDisabled = audioDisabled
        preferences.audioDeviceId = audioDisabled ? nil : audioId

        return .success(sessionPayload(device: videoDevice, warning: warning))
    }

    private func attachAudioLocked(audioId: String, volume: Double, muted: Bool) -> String? {
        guard let audioDevice = device(id: audioId, media: .audio) else {
            return "audio-unavailable"
        }
        let audioInput: AVCaptureDeviceInput
        do {
            audioInput = try AVCaptureDeviceInput(device: audioDevice)
        } catch {
            captureLog.error("Entrada de áudio recusada: \(error.localizedDescription, privacy: .public)")
            return "audio-unavailable"
        }
        guard session.canAddInput(audioInput) else {
            return "audio-unavailable"
        }
        session.addInput(audioInput)
        let preview = AVCaptureAudioPreviewOutput()
        preview.volume = muted ? 0 : Float(min(max(volume, 0), 1))
        guard session.canAddOutput(preview) else {
            return "audio-unavailable"
        }
        session.addOutput(preview)
        audioPreview = preview
        return nil
    }

    private func stopLocked() {
        if session.isRunning {
            session.stopRunning()
        }
        session.beginConfiguration()
        for input in session.inputs {
            session.removeInput(input)
        }
        if let audioPreview {
            session.removeOutput(audioPreview)
            self.audioPreview = nil
        }
        if videoDataAttached {
            session.removeOutput(videoDataOutput)
            videoDataOutput.setSampleBufferDelegate(nil, queue: nil)
            videoDataAttached = false
        }
        if audioDataAttached {
            session.removeOutput(audioDataOutput)
            audioDataOutput.setSampleBufferDelegate(nil, queue: nil)
            audioDataAttached = false
        }
        session.commitConfiguration()
        activeVideoId = nil
        lastWarning = nil
        endSleepAssertion()
    }

    private func refreshDataOutputsLocked() {
        let demand = outputDemand()
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if demand.video {
            videoDataOutput.alwaysDiscardsLateVideoFrames = true
            videoDataOutput.setSampleBufferDelegate(self, queue: videoQueue)
            if demand.encoder {
                videoDataOutput.videoSettings = Self.encoderVideoSettings
            } else {
                videoDataOutput.videoSettings = nil
            }
            if !videoDataAttached, session.canAddOutput(videoDataOutput) {
                session.addOutput(videoDataOutput)
                videoDataAttached = true
            }
        } else if videoDataAttached {
            session.removeOutput(videoDataOutput)
            videoDataOutput.setSampleBufferDelegate(nil, queue: nil)
            videoDataAttached = false
        }

        if demand.audio {
            audioDataOutput.setSampleBufferDelegate(self, queue: audioQueue)
            if !audioDataAttached, session.canAddOutput(audioDataOutput) {
                session.addOutput(audioDataOutput)
                audioDataAttached = true
            }
        } else if audioDataAttached {
            session.removeOutput(audioDataOutput)
            audioDataOutput.setSampleBufferDelegate(nil, queue: nil)
            audioDataAttached = false
        }
    }

    private func outputDemand() -> (video: Bool, audio: Bool, encoder: Bool) {
        stateLock.lock()
        defer { stateLock.unlock() }
        sinkBoxes = sinkBoxes.filter { $0.value.sink != nil }
        var video = statsEnabled
        var audio = false
        var encoder = false
        for box in sinkBoxes.values {
            if box.wantsVideo {
                video = true
                encoder = true
            }
            if box.wantsAudio {
                audio = true
            }
        }
        return (video, audio, encoder)
    }

    private static let encoderVideoSettings: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    // MARK: - Devices and formats

    private func videoDevices() -> [AVCaptureDevice] {
        unique(AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video,
            position: .unspecified
        ).devices)
    }

    private func audioDevices() -> [AVCaptureDevice] {
        unique(AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices)
    }

    private func unique(_ devices: [AVCaptureDevice]) -> [AVCaptureDevice] {
        var seen = Set<String>()
        return devices.filter { seen.insert($0.uniqueID).inserted }
    }

    private func device(id: String, media: AVMediaType) -> AVCaptureDevice? {
        let pool = media == .video ? videoDevices() : audioDevices()
        return pool.first { $0.uniqueID == id }
    }

    private func deviceMap(_ device: AVCaptureDevice) -> [String: Any] {
        [
            "id": device.uniqueID,
            "name": device.localizedName,
            "connected": device.isConnected,
        ]
    }

    private func listedFormats(_ device: AVCaptureDevice) -> [ListedFormat] {
        var listed: [ListedFormat] = []
        var seen = Set<String>()
        for format in device.formats {
            let description = format.formatDescription
            guard CMFormatDescriptionGetMediaType(description) == kCMMediaType_Video else { continue }
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            let width = Int(dimensions.width)
            let height = Int(dimensions.height)
            guard width > 0, height > 0 else { continue }
            let subtype = fourCC(CMFormatDescriptionGetMediaSubType(description))
            for fps in frameRates(for: format) {
                let id = "\(width)x\(height)@\(fps)#\(subtype)"
                let key = "\(width)x\(height)@\(fps)"
                guard seen.insert(key).inserted else { continue }
                listed.append(ListedFormat(id: id, width: width, height: height, fps: fps, format: format))
            }
        }
        return listed
    }

    private func resolve(device: AVCaptureDevice, formatId: String) -> ListedFormat? {
        listedFormats(device).first { $0.id == formatId }
    }

    private func frameRates(for format: AVCaptureDevice.Format) -> [Int] {
        var rates: [Int] = []
        var seen = Set<Int>()
        func add(_ fps: Int) {
            guard fps > 0, seen.insert(fps).inserted else { return }
            rates.append(fps)
        }
        for range in format.videoSupportedFrameRateRanges {
            add(Int(range.maxFrameRate.rounded()))
            if range.minFrameRate < range.maxFrameRate - 0.5 {
                for preferred in [60, 50, 30, 25, 24] where Double(preferred) >= range.minFrameRate - 0.05 && Double(preferred) <= range.maxFrameRate + 0.05 {
                    add(preferred)
                }
            }
        }
        return rates
    }

    private func frameDuration(for format: AVCaptureDevice.Format, fps: Int) -> CMTime {
        // Use the device's own exact durations at the range edges: capture cards
        // like the Cam Link report 59.94 fps (1001/60000), and setting a rounded
        // 60 fps duration throws NSInvalidArgumentException.
        let requested = Double(fps)
        let ranges = format.videoSupportedFrameRateRanges
        guard let range = ranges.first(where: { requested >= $0.minFrameRate - 0.5 && requested <= $0.maxFrameRate + 0.5 })
            ?? ranges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) else {
            return CMTime(value: 1, timescale: 60)
        }
        let chosen = min(max(requested, range.minFrameRate), range.maxFrameRate)
        if abs(chosen - range.maxFrameRate) < 0.5 { return range.minFrameDuration }
        if abs(chosen - range.minFrameRate) < 0.5 { return range.maxFrameDuration }
        return CMTime(value: 1000, timescale: CMTimeScale((chosen * 1000).rounded()))
    }

    private func describeActive(_ device: AVCaptureDevice) -> [String: Any] {
        let description = device.activeFormat.formatDescription
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        let seconds = CMTimeGetSeconds(device.activeVideoMinFrameDuration)
        let fps = (seconds > 0 && seconds.isFinite) ? Int((1.0 / seconds).rounded()) : 0
        let subtype = fourCC(CMFormatDescriptionGetMediaSubType(description))
        let width = Int(dimensions.width)
        let height = Int(dimensions.height)
        return [
            "id": "\(width)x\(height)@\(fps)#\(subtype)",
            "width": width,
            "height": height,
            "fps": fps,
        ]
    }

    private func fourCC(_ code: FourCharCode) -> String {
        var characters = ""
        for shift in stride(from: 24, through: 0, by: -8) {
            let value = Int((code >> UInt32(shift)) & 0xff)
            guard let scalar = UnicodeScalar(value),
                  scalar.isASCII,
                  scalar.value >= 32,
                  scalar.value < 127
            else {
                return String(format: "%08x", code)
            }
            characters.append(Character(scalar))
        }
        return characters
    }

    // MARK: - Audio preview, sleep, permissions

    private func applyAudioVolumeLocked() {
        audioPreview?.volume = storedMuted ? 0 : Float(storedVolume)
    }

    private func beginSleepAssertion() {
        guard sleepActivity == nil else { return }
        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .userInitiated],
            reason: "CapturaPlay está exibindo a captura"
        )
    }

    private func endSleepAssertion() {
        guard let sleepActivity else { return }
        ProcessInfo.processInfo.endActivity(sleepActivity)
        self.sleepActivity = nil
    }

    private func configurePreviewLayer() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let layer = self.previewLayer else { return }
            if layer.session !== self.session {
                layer.session = self.session
            }
            self.applyPreviewConnection(layer)
        }
    }

    private func applyPreviewConnection(_ layer: AVCaptureVideoPreviewLayer) {
        guard let connection = layer.connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = false
    }

    private func request(_ media: AVMediaType, completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: media, completionHandler: completion)
        default:
            completion(false)
        }
    }

    private func authorizationMap() -> [String: Any] {
        [
            "video": statusString(AVCaptureDevice.authorizationStatus(for: .video)),
            "audio": statusString(AVCaptureDevice.authorizationStatus(for: .audio)),
        ]
    }

    private func statusString(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            return "authorized"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        case .notDetermined:
            return "notDetermined"
        @unknown default:
            return "unknown"
        }
    }

    // MARK: - Snapshots and events

    private func snapshotLocked() -> [String: Any] {
        let active = activeVideoId.flatMap { device(id: $0, media: .video) }
        return [
            "authorization": authorizationMap(),
            "videoDevices": videoDevices().map { deviceMap($0) },
            "audioDevices": audioDevices().map { deviceMap($0) },
            "preferences": preferences.snapshot(),
            "session": sessionPayload(device: active, warning: lastWarning),
        ]
    }

    private func sessionPayload(
        device: AVCaptureDevice?,
        warning: String?,
        errorCode: String? = nil,
        errorDetail: String? = nil
    ) -> [String: Any] {
        [
            "running": session.isRunning,
            "activeFormat": device.map { describeActive($0) } ?? NSNull(),
            "errorCode": errorCode ?? NSNull(),
            "errorDetail": errorDetail ?? NSNull(),
            "warningCode": warning ?? NSNull(),
        ]
    }

    private func emitSession(_ payload: [String: Any]) {
        var event = payload
        event["type"] = "session"
        emit(event)
    }

    private func emit(_ event: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.captureEngine(self, didEmit: event)
        }
    }

    private func estimateLatencyMs(_ sampleBuffer: CMSampleBuffer) -> Double? {
        guard let clock = session.synchronizationClock else { return nil }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid else { return nil }
        let now = CMClockGetTime(clock)
        let delta = CMTimeSubtract(now, pts)
        guard delta.isValid, delta.isNumeric else { return nil }
        if CMTimeCompare(delta, .zero) < 0 { return nil }
        let seconds = CMTimeGetSeconds(delta)
        guard seconds.isFinite, seconds >= 0, seconds < 2 else { return nil }
        return seconds * 1000
    }

    private func currentSinks(video: Bool) -> [CaptureMediaSink] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return sinkBoxes.values.compactMap { box in
            guard let sink = box.sink else { return nil }
            if video {
                return box.wantsVideo ? sink : nil
            }
            return box.wantsAudio ? sink : nil
        }
    }

    private func statsAreEnabled() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return statsEnabled
    }

    // MARK: - Notifications

    @objc private func devicesChanged() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.emit([
                "type": "devices",
                "video": self.videoDevices().map { self.deviceMap($0) },
                "audio": self.audioDevices().map { self.deviceMap($0) },
            ])
            if let activeVideoId = self.activeVideoId, self.device(id: activeVideoId, media: .video) == nil {
                self.stopLocked()
                self.emitSession(self.sessionPayload(
                    device: nil,
                    warning: nil,
                    errorCode: "device-missing",
                    errorDetail: "O capturador foi desconectado."
                ))
            }
        }
    }

    @objc private func sessionRuntimeError(_ notification: Notification) {
        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
        let detail = error?.localizedDescription ?? "A sessão de captura parou."
        captureLog.error("Erro de sessão: \(detail, privacy: .public)")
        let code = error.map { AVError.Code(rawValue: $0.code) }
        let busy = code == .deviceAlreadyUsedByAnotherSession
            || code == .deviceInUseByAnotherApplication
            || code == .deviceLockedForConfigurationByAnotherProcess
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.emitSession(self.sessionPayload(
                device: nil,
                warning: nil,
                errorCode: busy ? "device-busy" : "session-failed",
                errorDetail: detail
            ))
        }
    }
}
