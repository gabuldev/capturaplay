import 'models.dart';

/// The platform boundary. Tests use a fake; macOS uses the method channel.
/// Sample buffers never cross this boundary — a future encoder registers on
/// the native engine instead of pulling frames through Dart.
abstract class CaptureClient {
  Stream<CaptureEvent> get events;

  Future<CaptureSnapshot> getState();

  Future<AuthorizationState> requestAccess();

  Future<List<VideoFormatOption>> listFormats(String videoDeviceId);

  Future<SessionStatus> start(StartRequest request);

  Future<void> stop();

  Future<void> setVolume(double volume);

  Future<void> setMuted(bool muted);

  Future<void> setStatsEnabled(bool enabled);

  Future<void> setCursorHidden(bool hidden);

  Future<void> toggleFullScreen();

  Future<void> openPrivacySettings();

  Future<void> setStreaming(StreamingRequest request);
}
