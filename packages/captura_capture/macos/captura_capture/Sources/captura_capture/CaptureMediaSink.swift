import CoreMedia

/// Receives media from the capture session without participating in display.
///
/// The preview layer and the audio preview output stay attached whether or
/// not any sink is registered. Data outputs are added only while at least
/// one sink (or the on-screen stats probe) wants samples, so gameplay does
/// not pay for an encoder path that is not running.
///
/// Callbacks arrive on a dedicated capture queue. Return quickly: retain the
/// `CVPixelBuffer` if you still need it and hop to another queue before
/// encoding. The buffer is invalid to use after the callback returns unless
/// you retained it.
public protocol CaptureMediaSink: AnyObject {
    var wantsVideoSamples: Bool { get }
    var wantsAudioSamples: Bool { get }

    func consumeVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer)
    func consumeAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer)
}

public extension CaptureMediaSink {
    var wantsVideoSamples: Bool { true }
    var wantsAudioSamples: Bool { true }

    func consumeVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {}
    func consumeAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {}
}
