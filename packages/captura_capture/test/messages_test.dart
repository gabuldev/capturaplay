import 'package:captura_capture/captura_capture.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const format = VideoFormatOption(
    id: '1080p60',
    width: 1920,
    height: 1080,
    fps: 60,
  );

  test('rótulos de formato e leituras', () {
    expect(formatVideoLabel(format), '1920×1080 @ 60 fps');
    expect(formatVideoChip(format), '1920×1080 · 60 fps');
    expect(formatFps(59.6), '60 fps');
    expect(formatFps(null), '— fps');
    expect(formatLatencyMs(17.4), '17 ms');
    expect(formatLatencyMs(null), '—');
    expect(formatLatencyMs(-1), '—');
    expect(formatVolumePercent(0.805), '81%');
  });

  test('dispositivo ocupado explica o caminho com o OBS', () {
    final message = describeCaptureError('device-busy');
    expect(message, contains('OBS'));
    expect(message, contains('janela'));
  });

  test('aviso de áudio e erro desconhecido', () {
    expect(describeCaptureWarning('audio-unavailable'), contains('áudio'));
    expect(describeCaptureWarning('outro'), isNull);
    expect(describeCaptureError(null), contains('Não foi possível'));
  });
}
