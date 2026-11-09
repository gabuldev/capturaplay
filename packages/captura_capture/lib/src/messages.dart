import 'models.dart';

String formatVideoLabel(VideoFormatOption format) {
  return '${format.width}×${format.height} @ ${format.fps} fps';
}

String formatVideoChip(VideoFormatOption format) {
  return '${format.width}×${format.height} · ${format.fps} fps';
}

String formatFps(double? fps) {
  if (fps == null || fps.isNaN || fps <= 0) return '— fps';
  return '${fps.round()} fps';
}

String formatLatencyMs(double? milliseconds) {
  if (milliseconds == null ||
      milliseconds.isNaN ||
      milliseconds.isInfinite ||
      milliseconds < 0) {
    return '—';
  }
  return '${milliseconds.round()} ms';
}

String formatVolumePercent(double level) {
  final clamped = level.clamp(0.0, 1.0);
  return '${(clamped * 100).round()}%';
}

/// Portuguese copy for a capture failure. [device-busy] tells the user how
/// to share the signal with OBS, because macOS will not open the UVC device
/// from both apps.
String describeCaptureError(String? code) {
  switch (code) {
    case 'permission-denied':
      return 'O macOS bloqueou a câmera ou o microfone.';
    case 'device-missing':
      return 'O dispositivo escolhido não está mais conectado.';
    case 'device-busy':
      return 'O capturador já está aberto em outro app. Feche a fonte dele no OBS e deixe o CapturaPlay abrir o dispositivo. No OBS, capture a janela deste app.';
    case 'format-unsupported':
      return 'Esse formato não está disponível neste dispositivo.';
    case 'add-input-failed':
      return 'Não foi possível abrir a entrada de vídeo ou áudio.';
    case 'add-output-failed':
      return 'Não foi possível preparar a prévia de vídeo ou o áudio.';
    case 'session-failed':
      return 'A sessão de captura parou.';
    default:
      return 'Não foi possível iniciar a captura.';
  }
}

String? describeCaptureWarning(String? code) {
  switch (code) {
    case 'audio-unavailable':
      return 'O vídeo abriu, mas o áudio do capturador não entrou na sessão.';
    default:
      return null;
  }
}
