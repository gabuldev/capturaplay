import Foundation

/// Last video device, audio device, format, and volume. Empty audio id means
/// "no remembered device", which is different from the user turning audio off.
final class PreferenceStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private enum Key {
        static let video = "dev.capturaplay.videoDeviceId"
        static let audio = "dev.capturaplay.audioDeviceId"
        static let format = "dev.capturaplay.formatId"
        static let volume = "dev.capturaplay.volume"
        static let muted = "dev.capturaplay.muted"
        static let audioDisabled = "dev.capturaplay.audioDisabled"
    }

    var videoDeviceId: String? {
        get { defaults.string(forKey: Key.video) }
        set { setOptional(newValue, forKey: Key.video) }
    }

    var audioDeviceId: String? {
        get { defaults.string(forKey: Key.audio) }
        set { setOptional(newValue, forKey: Key.audio) }
    }

    var formatId: String? {
        get { defaults.string(forKey: Key.format) }
        set { setOptional(newValue, forKey: Key.format) }
    }

    var volume: Double {
        get {
            guard defaults.object(forKey: Key.volume) != nil else { return 1 }
            return min(max(defaults.double(forKey: Key.volume), 0), 1)
        }
        set { defaults.set(min(max(newValue, 0), 1), forKey: Key.volume) }
    }

    var muted: Bool {
        get { defaults.bool(forKey: Key.muted) }
        set { defaults.set(newValue, forKey: Key.muted) }
    }

    var audioDisabled: Bool {
        get { defaults.bool(forKey: Key.audioDisabled) }
        set { defaults.set(newValue, forKey: Key.audioDisabled) }
    }

    func snapshot() -> [String: Any] {
        [
            "videoDeviceId": videoDeviceId ?? NSNull(),
            "audioDeviceId": audioDeviceId ?? NSNull(),
            "formatId": formatId ?? NSNull(),
            "volume": volume,
            "muted": muted,
            "audioDisabled": audioDisabled,
        ]
    }

    private func setOptional(_ value: String?, forKey key: String) {
        if let value, !value.isEmpty {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
