import 'package:captura_capture/captura_capture.dart';
import 'package:flutter/widgets.dart';

import 'src/app.dart';
import 'src/studio_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = StudioController(client: MethodChannelCaptureClient());
  runApp(CapturaPlayApp(controller: controller));
  await controller.bootstrap();
}
