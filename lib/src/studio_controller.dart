import 'dart:async';

import 'package:captura_capture/captura_capture.dart';
import 'package:flutter/foundation.dart';

import 'volume.dart';

class StudioController extends ChangeNotifier {
  StudioController({required this.client});

  final CaptureClient client;

  StreamSubscription<CaptureEvent>? _subscription;
  int _revision = 0;

  bool initializing = true;
  AuthorizationState authorization = AuthorizationState.unknown;
  List<CaptureDevice> videoDevices = const [];
  List<CaptureDevice> audioDevices = const [];
  List<VideoFormatOption> formats = const [];
  CaptureDevice? video;
  CaptureDevice? audio;
  VideoFormatOption? format;
  VideoFormatOption? activeFormat;
  VolumeState volume = VolumeState.full;
  bool running = false;
  String? errorCode;
  String? errorDetail;
  String? warningCode;
  bool statsVisible = false;
  CaptureStats? stats;
  bool fullscreen = false;
  bool streaming = false;
  int streamBitrateMbps = 20;
  int streamHeight = 1080;
  bool lowLatency = true;
  bool smoothPlayback = true;
  int streamClients = 0;
  String? streamError;

  String? preferredVideoId;
  String? preferredAudioId;
  String? preferredFormatId;
  bool audioDisabled = false;

  VideoFormatOption? get displayedFormat => activeFormat ?? format;

  Future<void> bootstrap() async {
    _subscription ??= client.events.listen(
      _handleEvent,
      onError: _handleStreamError,
    );
    try {
      final snapshot = await client.getState();
      _ingestSnapshot(snapshot);
      if (!authorization.granted && authorization.needsRequest) {
        authorization = await client.requestAccess();
      }
      if (authorization.granted) {
        await _loadFormatsAndStart();
      }
    } on CaptureFailure catch (error) {
      errorCode = error.code;
      errorDetail = error.detail;
    } finally {
      initializing = false;
      notifyListeners();
    }
  }

  Future<void> retry() => _loadFormatsAndStart();

  Future<void> chooseVideo(String id) async {
    preferredVideoId = id;
    await _loadFormatsAndStart();
  }

  Future<void> chooseAudio(String? id) async {
    if (id == null) {
      audioDisabled = true;
      preferredAudioId = null;
    } else {
      audioDisabled = false;
      preferredAudioId = id;
    }
    await _loadFormatsAndStart();
  }

  Future<void> chooseFormat(String id) async {
    preferredFormatId = id;
    await _loadFormatsAndStart();
  }

  Future<void> setLevel(double level) async {
    final wasMuted = volume.muted;
    volume = volume.withLevel(level);
    notifyListeners();
    await client.setVolume(volume.level);
    if (volume.muted != wasMuted) {
      await client.setMuted(volume.muted);
    }
  }

  Future<void> toggleMute() async {
    volume = volume.toggleMute();
    notifyListeners();
    await client.setMuted(volume.muted);
  }

  Future<void> nudgeVolume(double delta) => setLevel(volume.level + delta);

  Future<void> toggleStats() async {
    statsVisible = !statsVisible;
    if (!statsVisible) stats = null;
    notifyListeners();
    await client.setStatsEnabled(statsVisible);
  }

  Future<void> toggleFullscreen() => client.toggleFullScreen();

  Future<void> toggleStreaming() async {
    streaming = !streaming;
    await _pushStreaming();
    notifyListeners();
  }

  void previewStreamBitrate(double mbps) {
    streamBitrateMbps = clampStreamBitrateMbps(mbps.round());
    notifyListeners();
  }

  Future<void> commitStreamBitrate() => _pushStreaming();

  Future<void> chooseStreamBitrate(int mbps) async {
    streamBitrateMbps = clampStreamBitrateMbps(mbps);
    await _pushStreaming();
    notifyListeners();
  }

  Future<void> chooseStreamHeight(int height) async {
    streamHeight = normalizeStreamHeight(height);
    await _pushStreaming();
    notifyListeners();
  }

  Future<void> chooseSmooth(bool smooth) async {
    smoothPlayback = smooth;
    await _pushStreaming();
    notifyListeners();
  }

  Future<void> chooseLatencyMode(bool lowLatency) async {
    final tune = tuneForLatency(lowLatency);
    this.lowLatency = tune.lowLatency;
    streamHeight = tune.height;
    streamBitrateMbps = tune.bitrateMbps;
    await _pushStreaming();
    notifyListeners();
  }

  Future<void> _pushStreaming() async {
    try {
      await client.setStreaming(
        StreamingRequest(
          enabled: streaming,
          bitrateMbps: streamBitrateMbps,
          height: streamHeight,
          lowLatency: lowLatency,
          smooth: smoothPlayback,
        ),
      );
      if (streaming) streamError = null;
    } on CaptureFailure catch (error) {
      streamError = error.detail ?? error.code;
      streaming = false;
    }
  }

  String get streamStatusLabel {
    if (streamError != null) return streamError!;
    if (streamClients > 0) {
      return 'Na rede · iPhone ligado · $streamBitrateMbps Mb/s';
    }
    return 'Na rede · à espera do iPhone · porta ${LanLimits.port}';
  }

  Future<void> openPrivacySettings() => client.openPrivacySettings();

  Future<void> setCursorHidden(bool hidden) async {
    try {
      await client.setCursorHidden(hidden);
    } on CaptureFailure {
      // Cursor hiding is cosmetic. A missing plugin should not block playback.
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    unawaited(_release());
    super.dispose();
  }

  Future<void> _release() async {
    try {
      await client.setStreaming(
        const StreamingRequest(enabled: false, bitrateMbps: 20, height: 1080),
      );
      await client.setCursorHidden(false);
      await client.stop();
    } on Object {
      // The embedder may already be gone during shutdown.
    }
  }

  void _ingestSnapshot(CaptureSnapshot snapshot) {
    authorization = snapshot.authorization;
    fullscreen = snapshot.fullscreen;
    _applyDevices(snapshot.videoDevices, snapshot.audioDevices);
    preferredVideoId = snapshot.preferences.videoDeviceId;
    preferredAudioId = snapshot.preferences.audioDeviceId;
    preferredFormatId = snapshot.preferences.formatId;
    audioDisabled = snapshot.preferences.audioDisabled;
    volume = VolumeState(
      level: snapshot.preferences.volume,
      muted: snapshot.preferences.muted,
    );
    _applySession(snapshot.session);
  }

  Future<void> _loadFormatsAndStart() async {
    final revision = ++_revision;
    try {
      final snapshot = await client.getState();
      if (revision != _revision) return;
      _applyDevices(snapshot.videoDevices, snapshot.audioDevices);
      video = selectPreferredDevice(
        devices: videoDevices,
        rememberedId: preferredVideoId,
      );
      audio = selectPreferredAudio(
        devices: audioDevices,
        rememberedId: preferredAudioId,
        audioDisabled: audioDisabled,
        videoName: video?.name,
      );
      if (video == null) {
        running = false;
        formats = const [];
        format = null;
        activeFormat = null;
        errorCode = null;
        errorDetail = null;
        warningCode = null;
        notifyListeners();
        return;
      }
      formats = sortFormats(await client.listFormats(video!.id));
      if (revision != _revision) return;
      format = selectPreferredFormat(
        formats: formats,
        rememberedId: preferredFormatId,
      );
      if (format == null) {
        running = false;
        errorCode = 'format-unsupported';
        errorDetail = null;
        notifyListeners();
        return;
      }
      preferredVideoId = video!.id;
      preferredFormatId = format!.id;
      if (!audioDisabled) preferredAudioId = audio?.id;
      final status = await client.start(
        StartRequest(
          videoDeviceId: video!.id,
          audioDeviceId: audio?.id,
          formatId: format!.id,
          volume: volume.level,
          muted: volume.muted,
          audioDisabled: audioDisabled,
        ),
      );
      if (revision != _revision) return;
      _applySession(status);
      if (streaming) await _pushStreaming();
    } on CaptureFailure catch (error) {
      if (revision != _revision) return;
      running = false;
      errorCode = error.code;
      errorDetail = error.detail;
    }
    notifyListeners();
  }

  void _handleEvent(CaptureEvent event) {
    switch (event) {
      case DevicesChanged(:final video, :final audio):
        final previousId = this.video?.id;
        _applyDevices(video, audio);
        final gone =
            previousId != null &&
            !videoDevices.any((device) => device.id == previousId);
        final arrived =
            previousId == null &&
            videoDevices.isNotEmpty &&
            authorization.granted &&
            errorCode == null &&
            !initializing;
        notifyListeners();
        if (gone || arrived) {
          unawaited(_loadFormatsAndStart());
        }
      case SessionChanged(:final status):
        _applySession(status);
        notifyListeners();
      case StatsChanged(:final stats):
        this.stats = stats;
        notifyListeners();
      case FullScreenChanged(:final fullscreen):
        this.fullscreen = fullscreen;
        notifyListeners();
      case StreamStatusChanged(:final enabled, :final clients, :final error):
        streamClients = clients;
        streamError = error;
        if (!enabled && error != null) streaming = false;
        notifyListeners();
    }
  }

  void _handleStreamError(Object error) {
    errorCode = error is CaptureFailure ? error.code : 'session-failed';
    errorDetail = error is CaptureFailure ? error.detail : null;
    initializing = false;
    notifyListeners();
  }

  void _applyDevices(List<CaptureDevice> video, List<CaptureDevice> audio) {
    videoDevices = sortDevices(video);
    audioDevices = sortDevices(audio);
  }

  void _applySession(SessionStatus status) {
    running = status.running;
    if (status.activeFormat != null) {
      activeFormat = status.activeFormat;
    } else if (!status.running) {
      activeFormat = null;
    }
    errorCode = status.errorCode;
    errorDetail = status.errorDetail;
    warningCode = status.warningCode;
  }
}
