import 'package:captura_capture/captura_capture.dart';
import 'package:capturaplay/src/app.dart';
import 'package:capturaplay/src/studio_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_capture_client.dart';

void main() {
  testWidgets('mostra o estado sem capturador', (tester) async {
    final controller = StudioController(client: FakeCaptureClient());
    await controller.bootstrap();
    await tester.pumpWidget(CapturaPlayApp(controller: controller));

    expect(find.text('Nenhum capturador USB encontrado'), findsOneWidget);
    expect(find.text('Tentar de novo'), findsOneWidget);
    expect(find.text('CapturaPlay'), findsOneWidget);
  });

  testWidgets('explica a permissão de câmera e microfone', (tester) async {
    final controller = StudioController(
      client: FakeCaptureClient(
        authorization: const AuthorizationState(
          video: PermissionStatus.denied,
          audio: PermissionStatus.notDetermined,
        ),
      ),
    );
    await controller.bootstrap();
    await tester.pumpWidget(CapturaPlayApp(controller: controller));

    expect(find.text('Permissão necessária'), findsOneWidget);
    expect(find.textContaining('câmera e do microfone'), findsOneWidget);
    expect(find.text('Abrir Ajustes do Sistema'), findsOneWidget);
  });

  testWidgets('com sinal, mostra o formato ativo e os atalhos', (tester) async {
    final client = FakeCaptureClient(
      videos: const [CaptureDevice(id: 'cam', name: 'Cam Link 4K')],
      audios: const [CaptureDevice(id: 'cam-audio', name: 'Cam Link 4K')],
      formats: const [
        VideoFormatOption(id: '1080p60', width: 1920, height: 1080, fps: 60),
      ],
    );
    final controller = StudioController(client: client);
    await controller.bootstrap();
    await tester.pumpWidget(CapturaPlayApp(controller: controller));
    await tester.pump();

    expect(find.text('CapturaPlay'), findsOneWidget);
    expect(find.text('1920×1080 · 60 fps'), findsOneWidget);
    expect(find.text('VÍDEO'), findsOneWidget);
    expect(find.text('Cam Link 4K'), findsWidgets);
    expect(find.textContaining('tela cheia'), findsWidgets);

    await tester.tap(find.byTooltip('Mudo (M)'));
    await tester.pump();
    expect(controller.volume.muted, isTrue);
  });
}
