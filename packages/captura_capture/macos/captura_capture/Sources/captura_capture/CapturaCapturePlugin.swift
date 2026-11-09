import Cocoa
import FlutterMacOS

enum CaptureChannels {
    static let methods = "captura_capture/methods"
    static let events = "captura_capture/events"
    static let preview = "captura_capture/preview"
}

/// Flutter entry point. The capture graph itself lives in `CaptureEngine`
/// so a future streaming module can register a `CaptureMediaSink` without
/// going through this channel.
///
/// Obtain the engine from the plugin registry with `registryKey`, or add the
/// sink from code that lives in this same Swift module.
public final class CapturaCapturePlugin: NSObject, FlutterPlugin, FlutterStreamHandler, FlutterAppLifecycleDelegate, CaptureEngineDelegate {
    public static let registryKey = "CapturaCapturePlugin"

    public let engine: CaptureEngine
    private let sender = LanSender()
    private var eventSink: FlutterEventSink?
    private var cursorHidden = false

    public static func register(with registrar: FlutterPluginRegistrar) {
        let engine = CaptureEngine()
        let instance = CapturaCapturePlugin(engine: engine)
        let messenger = registrar.messenger
        let methods = FlutterMethodChannel(name: CaptureChannels.methods, binaryMessenger: messenger)
        registrar.addMethodCallDelegate(instance, channel: methods)
        let events = FlutterEventChannel(name: CaptureChannels.events, binaryMessenger: messenger)
        events.setStreamHandler(instance)
        registrar.register(PreviewViewFactory(engine: engine), withId: CaptureChannels.preview)
        registrar.addApplicationDelegate(instance)
        registrar.publish(instance)
        instance.observeFullscreen()
        engine.startDeviceNotifications()
    }

    init(engine: CaptureEngine) {
        self.engine = engine
        super.init()
        engine.delegate = self
        sender.onStatus = { [weak self] enabled, clients, error in
            var event: [String: Any] = [
                "type": "stream",
                "enabled": enabled,
                "clients": clients,
                "port": Int(LanLimits.port),
            ]
            event["error"] = error ?? NSNull()
            self?.eventSink?(event)
        }
    }

    public func handle(_ call: FlutterMethodCall, result callback: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "getState":
            engine.snapshot { payload in
                var snapshot = payload
                snapshot["fullscreen"] = self.isFullScreen
                callback(snapshot)
            }
        case "requestAccess":
            engine.requestAccess { status in
                callback(status)
            }
        case "listFormats":
            guard let videoId = args["videoDeviceId"] as? String else {
                callback(FlutterError(code: "device-missing", message: "Dispositivo de vídeo ausente.", details: nil))
                return
            }
            engine.listFormats(videoDeviceId: videoId) { listed in
                switch listed {
                case let .success(formats):
                    callback(formats)
                case let .failure(error):
                    callback(FlutterError(code: error.code, message: error.detail, details: nil))
                }
            }
        case "start":
            guard let videoId = args["videoDeviceId"] as? String,
                  let formatId = args["formatId"] as? String
            else {
                callback(FlutterError(code: "session-failed", message: "Pedido de captura incompleto.", details: nil))
                return
            }
            engine.start(
                videoId: videoId,
                audioId: args["audioDeviceId"] as? String,
                formatId: formatId,
                volume: Self.doubleValue(args["volume"]) ?? 1,
                muted: Self.boolValue(args["muted"]) ?? false,
                audioDisabled: Self.boolValue(args["audioDisabled"]) ?? false
            ) { started in
                switch started {
                case let .success(payload):
                    callback(payload)
                case let .failure(error):
                    callback(FlutterError(code: error.code, message: error.detail, details: nil))
                }
            }
        case "stop":
            engine.stop {
                callback(nil)
            }
        case "setVolume":
            engine.setVolume(Self.doubleValue(args["volume"]) ?? 1) {
                callback(nil)
            }
        case "setMuted":
            engine.setMuted(Self.boolValue(args["muted"]) ?? false) {
                callback(nil)
            }
        case "setStatsEnabled":
            engine.setStatsEnabled(Self.boolValue(args["enabled"]) ?? false)
            callback(nil)
        case "setStreaming":
            let enabled = Self.boolValue(args["enabled"]) ?? false
            let bitrate = Int(Self.doubleValue(args["bitrateMbps"]) ?? 8)
            let height = Int(Self.doubleValue(args["height"]) ?? 720)
            let lowLatency = Self.boolValue(args["lowLatency"]) ?? true
            if enabled {
                sender.update(bitrateMbps: bitrate, height: height, lowLatency: lowLatency)
                sender.startListening()
                engine.addMediaSink(sender)
            } else {
                engine.removeMediaSink(sender)
                sender.stop()
            }
            callback(nil)
        case "setCursorHidden":
            let hidden = Self.boolValue(args["hidden"]) ?? false
            DispatchQueue.main.async {
                self.applyCursorHidden(hidden)
                callback(nil)
            }
        case "toggleFullScreen":
            DispatchQueue.main.async {
                self.playerWindow()?.toggleFullScreen(nil)
                callback(nil)
            }
        case "openPrivacySettings":
            DispatchQueue.main.async {
                self.openPrivacySettings()
                callback(nil)
            }
        default:
            callback(FlutterMethodNotImplemented)
        }
    }

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    func captureEngine(_ engine: CaptureEngine, didEmit event: [String: Any]) {
        eventSink?(event)
    }

    public func handleDidHide(_ notification: Notification) {
        applyCursorHidden(false)
    }

    public func handleDidResignActive(_ notification: Notification) {
        applyCursorHidden(false)
    }

    public func handleWillTerminate(_ notification: Notification) {
        applyCursorHidden(false)
        engine.stopSynchronously()
    }

    private var isFullScreen: Bool {
        playerWindow()?.styleMask.contains(.fullScreen) ?? false
    }

    private func playerWindow() -> NSWindow? {
        let windows = NSApp.windows.filter { $0.contentViewController is FlutterViewController }
        if let key = NSApp.keyWindow, windows.contains(where: { $0 === key }) {
            return key
        }
        if let main = NSApp.mainWindow, windows.contains(where: { $0 === main }) {
            return main
        }
        return windows.first
    }

    private func observeFullscreen() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(fullscreenChanged(_:)), name: NSWindow.didEnterFullScreenNotification, object: nil)
        center.addObserver(self, selector: #selector(fullscreenChanged(_:)), name: NSWindow.didExitFullScreenNotification, object: nil)
    }

    @objc private func fullscreenChanged(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window.contentViewController is FlutterViewController
        else { return }
        eventSink?(["type": "fullscreen", "value": window.styleMask.contains(.fullScreen)])
    }

    private func applyCursorHidden(_ hidden: Bool) {
        if hidden && !cursorHidden {
            NSCursor.hide()
            cursorHidden = true
        } else if !hidden && cursorHidden {
            NSCursor.unhide()
            cursorHidden = false
        }
    }

    private func openPrivacySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Camera",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera",
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }
}
