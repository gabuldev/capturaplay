import 'dart:async';

import 'package:captura_capture/captura_capture.dart';

class FakeCaptureClient implements CaptureClient {
  FakeCaptureClient({
    this.authorization = const AuthorizationState(
      video: PermissionStatus.authorized,
      audio: PermissionStatus.authorized,
    ),
    this.videos = const [],
    this.audios = const [],
    this.formats = const [],
    this.preferences = PlaybackPreferences.defaults,
  });

  AuthorizationState authorization;
  List<CaptureDevice> videos;
  List<CaptureDevice> audios;
  List<VideoFormatOption> formats;
  PlaybackPreferences preferences;
  CaptureFailure? startFailure;

  final List<StartRequest> starts = [];
  final List<String> calls = [];
  bool statsEnabled = false;

  final StreamController<CaptureEvent> _events =
      StreamController<CaptureEvent>.broadcast();

  void emit(CaptureEvent event) {
    _events.add(event);
  }

  @override
  Stream<CaptureEvent> get events => _events.stream;

  @override
  Future<CaptureSnapshot> getState() async {
    calls.add('getState');
    return CaptureSnapshot(
      authorization: authorization,
      videoDevices: videos,
      audioDevices: audios,
      preferences: preferences,
      session: SessionStatus.idle,
      fullscreen: false,
    );
  }

  @override
  Future<AuthorizationState> requestAccess() async {
    calls.add('requestAccess');
    return authorization;
  }

  @override
  Future<List<VideoFormatOption>> listFormats(String videoDeviceId) async {
    calls.add('listFormats:$videoDeviceId');
    return formats;
  }

  @override
  Future<SessionStatus> start(StartRequest request) async {
    calls.add('start');
    starts.add(request);
    final failure = startFailure;
    if (failure != null) throw failure;
    VideoFormatOption? active;
    for (final format in formats) {
      if (format.id == request.formatId) active = format;
    }
    return SessionStatus(running: true, activeFormat: active);
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
  }

  @override
  Future<void> setVolume(double volume) async {
    calls.add('setVolume:$volume');
  }

  @override
  Future<void> setMuted(bool muted) async {
    calls.add('setMuted:$muted');
  }

  @override
  Future<void> setStatsEnabled(bool enabled) async {
    calls.add('setStatsEnabled:$enabled');
    statsEnabled = enabled;
  }

  @override
  Future<void> setCursorHidden(bool hidden) async {
    calls.add('setCursorHidden:$hidden');
  }

  @override
  Future<void> toggleFullScreen() async {
    calls.add('toggleFullScreen');
  }

  @override
  Future<void> openPrivacySettings() async {
    calls.add('openPrivacySettings');
  }

  @override
  Future<void> setStreaming(StreamingRequest request) async {
    calls.add(
      'setStreaming:${request.enabled}:${request.bitrateMbps}:${request.height}',
    );
  }
}
