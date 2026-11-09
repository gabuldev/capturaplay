import 'package:captura_capture/captura_capture.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'src/app.dart';
import 'src/receiver/receiver_page.dart';
import 'src/studio_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
    runApp(const ReceiverApp());
    return;
  }
  final controller = StudioController(client: MethodChannelCaptureClient());
  runApp(CapturaPlayApp(controller: controller));
  await controller.bootstrap();
}
