import 'models.dart';

/// Picks the video device to open.
///
/// A still-connected remembered device wins. Otherwise a device whose name
/// contains "Cam Link" (any case) wins, so the first launch with the capture
/// card plugged in does not stick on the built-in camera.
CaptureDevice? selectPreferredDevice({
  required List<CaptureDevice> devices,
  String? rememberedId,
  String nameFragment = 'cam link',
}) {
  final connected = devices.where((device) => device.connected).toList();
  final pool = connected.isNotEmpty ? connected : devices;
  if (rememberedId != null && rememberedId.isNotEmpty) {
    for (final device in pool) {
      if (device.id == rememberedId) return device;
    }
  }
  final needle = nameFragment.toLowerCase();
  for (final device in pool) {
    if (device.name.toLowerCase().contains(needle)) return device;
  }
  if (pool.isEmpty) return null;
  return pool.first;
}

/// Picks the audio input that belongs to the capture card.
///
/// The built-in microphone is never a fallback: opening it would play the
/// room instead of the console. [audioDisabled] is an explicit "Sem áudio".
CaptureDevice? selectPreferredAudio({
  required List<CaptureDevice> devices,
  String? rememberedId,
  required bool audioDisabled,
  String? videoName,
  String nameFragment = 'cam link',
}) {
  if (audioDisabled) return null;
  final connected = devices.where((device) => device.connected).toList();
  if (rememberedId != null && rememberedId.isNotEmpty) {
    for (final device in connected) {
      if (device.id == rememberedId) return device;
    }
  }
  final needle = nameFragment.toLowerCase();
  for (final device in connected) {
    if (device.name.toLowerCase().contains(needle)) return device;
  }
  if (videoName != null && videoName.isNotEmpty) {
    final videoNeedle = videoName.toLowerCase();
    for (final device in connected) {
      if (device.name.toLowerCase() == videoNeedle) return device;
    }
  }
  return null;
}

/// Default format is 1920×1080 @ 60. A remembered id wins when it still exists.
/// Otherwise the closest resolution wins, and frame rate breaks the tie.
VideoFormatOption? selectPreferredFormat({
  required List<VideoFormatOption> formats,
  String? rememberedId,
  int targetWidth = 1920,
  int targetHeight = 1080,
  int targetFps = 60,
}) {
  if (formats.isEmpty) return null;
  if (rememberedId != null && rememberedId.isNotEmpty) {
    for (final format in formats) {
      if (format.id == rememberedId) return format;
    }
  }
  for (final format in formats) {
    if (format.width == targetWidth &&
        format.height == targetHeight &&
        format.fps == targetFps) {
      return format;
    }
  }

  int score(VideoFormatOption format) {
    final resolution =
        (format.width - targetWidth).abs() +
        (format.height - targetHeight).abs();
    final fps = (format.fps - targetFps).abs();
    return resolution * 1000 + fps;
  }

  var best = formats.first;
  var bestScore = score(best);
  for (final format in formats.skip(1)) {
    final next = score(format);
    if (next < bestScore) {
      best = format;
      bestScore = next;
    }
  }
  return best;
}

List<CaptureDevice> sortDevices(List<CaptureDevice> devices) {
  final copy = [...devices];
  copy.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return copy;
}

List<VideoFormatOption> sortFormats(List<VideoFormatOption> formats) {
  final copy = [...formats];
  copy.sort((a, b) {
    if (a.height != b.height) return b.height.compareTo(a.height);
    if (a.width != b.width) return b.width.compareTo(a.width);
    return b.fps.compareTo(a.fps);
  });
  return copy;
}
