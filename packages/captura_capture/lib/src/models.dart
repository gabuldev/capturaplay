/// Camera and microphone authorization, as reported by AVFoundation.
enum PermissionStatus { authorized, denied, restricted, notDetermined, unknown }

class AuthorizationState {
  const AuthorizationState({required this.video, required this.audio});

  final PermissionStatus video;
  final PermissionStatus audio;

  bool get granted =>
      video == PermissionStatus.authorized &&
      audio == PermissionStatus.authorized;

  /// True when the system dialog has not been answered for at least one device.
  bool get needsRequest =>
      video == PermissionStatus.notDetermined ||
      audio == PermissionStatus.notDetermined;

  static const unknown = AuthorizationState(
    video: PermissionStatus.unknown,
    audio: PermissionStatus.unknown,
  );
}

class CaptureDevice {
  const CaptureDevice({
    required this.id,
    required this.name,
    this.connected = true,
  });

  final String id;
  final String name;
  final bool connected;
}

class VideoFormatOption {
  const VideoFormatOption({
    required this.id,
    required this.width,
    required this.height,
    required this.fps,
  });

  final String id;
  final int width;
  final int height;
  final int fps;
}

class PlaybackPreferences {
  const PlaybackPreferences({
    this.videoDeviceId,
    this.audioDeviceId,
    this.formatId,
    this.volume = 1,
    this.muted = false,
    this.audioDisabled = false,
  });

  final String? videoDeviceId;
  final String? audioDeviceId;
  final String? formatId;
  final double volume;
  final bool muted;

  /// The user chose "Sem áudio". Distinct from [audioDeviceId] being null,
  /// which means there is no remembered choice yet.
  final bool audioDisabled;

  static const defaults = PlaybackPreferences();
}

class StartRequest {
  const StartRequest({
    required this.videoDeviceId,
    required this.audioDeviceId,
    required this.formatId,
    required this.volume,
    required this.muted,
    required this.audioDisabled,
  });

  final String videoDeviceId;
  final String? audioDeviceId;
  final String formatId;
  final double volume;
  final bool muted;
  final bool audioDisabled;
}

class SessionStatus {
  const SessionStatus({
    required this.running,
    this.activeFormat,
    this.errorCode,
    this.errorDetail,
    this.warningCode,
  });

  final bool running;
  final VideoFormatOption? activeFormat;
  final String? errorCode;
  final String? errorDetail;
  final String? warningCode;

  static const idle = SessionStatus(running: false);
}

class CaptureStats {
  const CaptureStats({required this.fps, this.latencyMs});

  final double fps;
  final double? latencyMs;
}

class CaptureSnapshot {
  const CaptureSnapshot({
    required this.authorization,
    required this.videoDevices,
    required this.audioDevices,
    required this.preferences,
    required this.session,
    required this.fullscreen,
  });

  final AuthorizationState authorization;
  final List<CaptureDevice> videoDevices;
  final List<CaptureDevice> audioDevices;
  final PlaybackPreferences preferences;
  final SessionStatus session;
  final bool fullscreen;
}

class CaptureFailure implements Exception {
  const CaptureFailure({required this.code, this.detail});

  final String code;
  final String? detail;

  @override
  String toString() => 'CaptureFailure($code, $detail)';
}

sealed class CaptureEvent {
  const CaptureEvent();
}

class DevicesChanged extends CaptureEvent {
  const DevicesChanged({required this.video, required this.audio});

  final List<CaptureDevice> video;
  final List<CaptureDevice> audio;
}

class SessionChanged extends CaptureEvent {
  const SessionChanged(this.status);

  final SessionStatus status;
}

class StatsChanged extends CaptureEvent {
  const StatsChanged(this.stats);

  final CaptureStats stats;
}

class FullScreenChanged extends CaptureEvent {
  const FullScreenChanged(this.fullscreen);

  final bool fullscreen;
}

class StreamingRequest {
  const StreamingRequest({
    required this.enabled,
    required this.bitrateMbps,
    required this.height,
    this.lowLatency = true,
  });

  final bool enabled;
  final int bitrateMbps;
  final int height;
  final bool lowLatency;
}

class StreamStatusChanged extends CaptureEvent {
  const StreamStatusChanged({
    required this.enabled,
    required this.clients,
    this.error,
    this.port = 0,
  });

  final bool enabled;
  final int clients;
  final String? error;
  final int port;
}
