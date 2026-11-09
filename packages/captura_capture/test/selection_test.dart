import 'package:captura_capture/captura_capture.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const camLink = CaptureDevice(id: 'cam', name: 'Cam Link 4K');
  const faceTime = CaptureDevice(id: 'face', name: 'FaceTime HD Camera');
  const disconnected = CaptureDevice(
    id: 'old',
    name: 'Cam Link 4K',
    connected: false,
  );
  const mic = CaptureDevice(id: 'mic', name: 'Microfone do MacBook Pro');
  const camAudio = CaptureDevice(id: 'cam-audio', name: 'Cam Link 4K');
  const sameName = CaptureDevice(id: 'usb-audio', name: 'USB Capture');

  const hd60 = VideoFormatOption(
    id: '1080p60',
    width: 1920,
    height: 1080,
    fps: 60,
  );
  const hd30 = VideoFormatOption(
    id: '1080p30',
    width: 1920,
    height: 1080,
    fps: 30,
  );
  const uhd30 = VideoFormatOption(
    id: '4k30',
    width: 3840,
    height: 2160,
    fps: 30,
  );
  const sd60 = VideoFormatOption(
    id: '720p60',
    width: 1280,
    height: 720,
    fps: 60,
  );

  test('dispositivo lembrado vence o Cam Link se ainda estiver conectado', () {
    final selected = selectPreferredDevice(
      devices: const [camLink, faceTime],
      rememberedId: 'face',
    );
    expect(selected?.id, 'face');
  });

  test('sem memória, escolhe o dispositivo cujo nome contém Cam Link', () {
    final selected = selectPreferredDevice(
      devices: const [faceTime, camLink],
      rememberedId: null,
    );
    expect(selected?.id, 'cam');
  });

  test('ignora Cam Link desconectado e cai no próximo dispositivo', () {
    final selected = selectPreferredDevice(
      devices: const [disconnected, faceTime],
      rememberedId: null,
    );
    expect(selected?.id, 'face');
  });

  test('memória velha cai no Cam Link', () {
    final selected = selectPreferredDevice(
      devices: const [faceTime, camLink],
      rememberedId: 'sumiu',
    );
    expect(selected?.id, 'cam');
  });

  test('sem capturador devolve nulo', () {
    expect(
      selectPreferredDevice(devices: const [], rememberedId: null),
      isNull,
    );
  });

  test('áudio não cai no microfone interno', () {
    final selected = selectPreferredAudio(
      devices: const [mic],
      rememberedId: null,
      audioDisabled: false,
      videoName: 'Cam Link 4K',
    );
    expect(selected, isNull);
  });

  test('áudio prefere Cam Link e depois o mesmo nome do vídeo', () {
    expect(
      selectPreferredAudio(
        devices: const [mic, camAudio],
        rememberedId: null,
        audioDisabled: false,
        videoName: 'Outro',
      )?.id,
      'cam-audio',
    );
    expect(
      selectPreferredAudio(
        devices: const [mic, sameName],
        rememberedId: null,
        audioDisabled: false,
        videoName: 'USB Capture',
      )?.id,
      'usb-audio',
    );
  });

  test('áudio lembrado e sem áudio explícito', () {
    expect(
      selectPreferredAudio(
        devices: const [mic, camAudio],
        rememberedId: 'mic',
        audioDisabled: false,
        videoName: 'Cam Link 4K',
      )?.id,
      'mic',
    );
    expect(
      selectPreferredAudio(
        devices: const [camAudio],
        rememberedId: 'cam-audio',
        audioDisabled: true,
        videoName: 'Cam Link 4K',
      ),
      isNull,
    );
  });

  test('formato padrão é 1920x1080 a 60 fps', () {
    final selected = selectPreferredFormat(
      formats: const [uhd30, sd60, hd30, hd60],
      rememberedId: null,
    );
    expect(selected?.id, '1080p60');
  });

  test('sem 1080p60, a resolução mais próxima vence o fps', () {
    final selected = selectPreferredFormat(
      formats: const [uhd30, sd60, hd30],
      rememberedId: null,
    );
    expect(selected?.id, '1080p30');
  });

  test('formato lembrado vence o padrão', () {
    final selected = selectPreferredFormat(
      formats: const [hd60, uhd30],
      rememberedId: '4k30',
    );
    expect(selected?.id, '4k30');
  });

  test('formato lembrado que sumiu volta para 1080p60', () {
    final selected = selectPreferredFormat(
      formats: const [hd30, hd60],
      rememberedId: '4k30',
    );
    expect(selected?.id, '1080p60');
  });
}
