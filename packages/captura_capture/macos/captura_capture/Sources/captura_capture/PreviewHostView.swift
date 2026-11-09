import AVFoundation
import Cocoa
import FlutterMacOS

/// Hosts an `AVCaptureVideoPreviewLayer` as the view's backing layer.
///
/// This is the display path on purpose. The layer is updated by the capture
/// pipeline, not by copying a `CVPixelBuffer` into Flutter's texture registry
/// and waiting for the next Impeller frame. macOS platform views are real
/// `NSView`s in the window (hybrid composition), so the layer stays on
/// AVFoundation's clock.
///
/// Hit testing returns nil so clicks and double-clicks fall through to
/// Flutter. Do not clip, fade, or transform the platform view from Dart:
/// those operations can force Flutter to composite the native view instead
/// of letting this layer draw itself.
final class PreviewHostView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func makeBackingLayer() -> CALayer {
        let preview = AVCaptureVideoPreviewLayer()
        preview.videoGravity = .resizeAspect
        preview.backgroundColor = CGColor(gray: 0, alpha: 1)
        return preview
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        guard let preview = layer as? AVCaptureVideoPreviewLayer else {
            preconditionFailure("PreviewHostView backing layer must be AVCaptureVideoPreviewLayer")
        }
        return preview
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override var isOpaque: Bool { true }
}

final class PreviewViewFactory: NSObject, FlutterPlatformViewFactory {
    private let engine: CaptureEngine

    init(engine: CaptureEngine) {
        self.engine = engine
        super.init()
    }

    func create(withViewIdentifier viewId: Int64, arguments args: Any?) -> NSView {
        let view = PreviewHostView(frame: .zero)
        engine.attachPreview(view.previewLayer)
        return view
    }
}
