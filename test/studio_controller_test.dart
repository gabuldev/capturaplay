import 'package:captura_capture/captura_capture.dart';
import 'package:capturaplay/src/studio_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_capture_client.dart';

const camLink = CaptureDevice(id: 'cam', name: 'Cam Link 4K');
const faceTime = CaptureDevice(id: 'face', name: 'FaceTime HD Camera');
const camAudio = CaptureDevice(id: 'cam-audio', name: 'Cam Link 4K');
const mic = CaptureDevice(id: 'mic', name: 'Microfone do MacBook Pro');
const hd60 = VideoFormatOption(
  id: '1080p60',
  width: 1920,
  height: 1080,
  fps: 60,
);
const uhd30 = VideoFormatOption(id: '4k30', width: 3840, height: 2160, fps: 30);

FakeCaptureClient readyClient() {
  return FakeCaptureClient(
    videos: const [faceTime, camLink],
    audios: const [mic, camAudio],
    formats: const [uhd30, hd60],
  );
}

void main() {
  test('permissão negada não abre a sessão', () async {
    final client = FakeCaptureClient(
      authorization: const AuthorizationState(
        video: PermissionStatus.denied,
        audio: PermissionStatus.denied,
      ),
      videos: const [camLink],
      formats: const [hd60],
    );
    final controller = StudioController(client: client);
    await controller.bootstrap();

    expect(controller.authorization.granted, isFalse);
    expect(client.starts, isEmpty);
    expect(client.calls, isNot(contains('requestAccess')));
    controller.dispose();
  });

  test('abre o Cam Link em 1080p60 e o áudio do capturador', () async {
    final client = readyClient();
    final controller = StudioController(client: client);
    await controller.bootstrap();

    expect(controller.running, isTrue);
    expect(controller.video?.id, 'cam');
    expect(controller.audio?.id, 'cam-audio');
    expect(controller.format?.id, '1080p60');
    expect(controller.activeFormat?.id, '1080p60');
    expect(client.starts.single.videoDeviceId, 'cam');
    expect(client.starts.single.audioDeviceId, 'cam-audio');
    expect(client.starts.single.formatId, '1080p60');
    expect(client.starts.single.audioDisabled, isFalse);
    controller.dispose();
  });

  test('lembra o último vídeo e não usa o microfone interno sozinho', () async {
    final client = readyClient()
      ..preferences = const PlaybackPreferences(
        videoDeviceId: 'face',
        formatId: '4k30',
      );
    final controller = StudioController(client: client);
    await controller.bootstrap();

    expect(controller.video?.id, 'face');
    expect(controller.format?.id, '4k30');
    expect(controller.audio?.id, 'cam-audio');

    final micOnly = FakeCaptureClient(
      videos: const [camLink],
      audios: const [mic],
      formats: const [hd60],
    );
    final quiet = StudioController(client: micOnly);
    await quiet.bootstrap();
    expect(quiet.audio, isNull);
    expect(micOnly.starts.single.audioDeviceId, isNull);
    quiet.dispose();
    controller.dispose();
  });

  test('dispositivo ocupado aparece para a interface', () async {
    final client = readyClient()
      ..startFailure = const CaptureFailure(
        code: 'device-busy',
        detail: 'em uso',
      );
    final controller = StudioController(client: client);
    await controller.bootstrap();

    expect(controller.running, isFalse);
    expect(controller.errorCode, 'device-busy');
    expect(describeCaptureError(controller.errorCode), contains('OBS'));
    controller.dispose();
  });

  test('mudo, dados e troca de formato', () async {
    final client = readyClient();
    final controller = StudioController(client: client);
    await controller.bootstrap();

    await controller.toggleMute();
    expect(controller.volume.muted, isTrue);
    expect(client.calls, contains('setMuted:true'));

    await controller.toggleStats();
    expect(controller.statsVisible, isTrue);
    expect(client.statsEnabled, isTrue);

    await controller.chooseFormat('4k30');
    expect(controller.format?.id, '4k30');
    expect(client.starts.last.formatId, '4k30');

    await controller.chooseAudio(null);
    expect(controller.audioDisabled, isTrue);
    expect(client.starts.last.audioDeviceId, isNull);
    expect(client.starts.last.audioDisabled, isTrue);
    controller.dispose();
  });

  test('transmissão pede H.264 na rede sem reiniciar a captura', () async {
    final client = readyClient();
    final controller = StudioController(client: client);
    await controller.bootstrap();
    final startsBefore = client.starts.length;

    await controller.toggleStreaming();
    expect(controller.streaming, isTrue);
    expect(client.calls, contains('setStreaming:true:20:1080:true:true'));
    expect(client.starts, hasLength(startsBefore));

    await controller.chooseLatencyMode(false);
    expect(controller.lowLatency, isFalse);
    expect(controller.streamHeight, 1080);
    expect(controller.streamBitrateMbps, 20);
    expect(client.calls.last, 'setStreaming:true:20:1080:false:true');
    controller.dispose();
  });

  test('Cam Link conectado depois da abertura entra sozinho', () async {
    final client = FakeCaptureClient(
      formats: const [hd60],
      audios: const [camAudio],
    );
    final controller = StudioController(client: client);
    await controller.bootstrap();
    expect(controller.video, isNull);
    expect(client.starts, isEmpty);

    client.videos = const [camLink];
    client.emit(const DevicesChanged(video: [camLink], audio: [camAudio]));
    await pumpEventQueue();

    expect(controller.video?.id, 'cam');
    expect(client.starts, isNotEmpty);
    controller.dispose();
  });
}
