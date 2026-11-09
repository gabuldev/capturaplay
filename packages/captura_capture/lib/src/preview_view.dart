import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Native preview. On macOS this is an `NSView` whose backing layer is an
/// `AVCaptureVideoPreviewLayer`. That is lower latency than pushing
/// `CVPixelBuffer`s through the Flutter texture registry: the layer is drawn
/// by AVFoundation, and the embedder puts the view in the window hierarchy
/// instead of copying the frame into Impeller.
///
/// Leave this widget unclipped and fully opaque. A clip, opacity, or
/// transform can make Flutter composite the native view and add a frame.
class CapturePreview extends StatelessWidget {
  const CapturePreview({super.key});

  static const viewType = 'captura_capture/preview';

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.macOS) {
      return const ColoredBox(color: Color(0xFF0C0D0B));
    }
    return const AppKitView(
      viewType: viewType,
      hitTestBehavior: PlatformViewHitTestBehavior.transparent,
    );
  }
}
