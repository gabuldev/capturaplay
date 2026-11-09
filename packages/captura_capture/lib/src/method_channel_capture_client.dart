import 'dart:async';

import 'package:flutter/services.dart';

import 'capture_client.dart';
import 'codec.dart';
import 'models.dart';

/// Talks to `CapturaCapturePlugin` on macOS.
class MethodChannelCaptureClient implements CaptureClient {
  MethodChannelCaptureClient({MethodChannel? methods, EventChannel? events})
    : _methods = methods ?? const MethodChannel('captura_capture/methods'),
      _events = events ?? const EventChannel('captura_capture/events');

  final MethodChannel _methods;
  final EventChannel _events;
  Stream<CaptureEvent>? _eventsStream;

  @override
  Stream<CaptureEvent> get events {
    return _eventsStream ??= _events
        .receiveBroadcastStream()
        .map(eventFrom)
        .where((event) => event != null)
        .cast<CaptureEvent>();
  }

  @override
  Future<CaptureSnapshot> getState() {
    return _invoke('getState', null, snapshotFrom);
  }

  @override
  Future<AuthorizationState> requestAccess() {
    return _invoke('requestAccess', null, authorizationFrom);
  }

  @override
  Future<List<VideoFormatOption>> listFormats(String videoDeviceId) {
    return _invoke('listFormats', {
      'videoDeviceId': videoDeviceId,
    }, formatsFrom);
  }

  @override
  Future<SessionStatus> start(StartRequest request) {
    return _invoke('start', {
      'videoDeviceId': request.videoDeviceId,
      'audioDeviceId': request.audioDeviceId,
      'formatId': request.formatId,
      'volume': request.volume,
      'muted': request.muted,
      'audioDisabled': request.audioDisabled,
    }, sessionFrom);
  }

  @override
  Future<void> stop() => _invokeVoid('stop');

  @override
  Future<void> setVolume(double volume) {
    return _invokeVoid('setVolume', {'volume': volume});
  }

  @override
  Future<void> setMuted(bool muted) {
    return _invokeVoid('setMuted', {'muted': muted});
  }

  @override
  Future<void> setStatsEnabled(bool enabled) {
    return _invokeVoid('setStatsEnabled', {'enabled': enabled});
  }

  @override
  Future<void> setCursorHidden(bool hidden) {
    return _invokeVoid('setCursorHidden', {'hidden': hidden});
  }

  @override
  Future<void> toggleFullScreen() => _invokeVoid('toggleFullScreen');

  @override
  Future<void> openPrivacySettings() => _invokeVoid('openPrivacySettings');

  @override
  Future<void> setStreaming(StreamingRequest request) {
    return _invokeVoid('setStreaming', {
      'enabled': request.enabled,
      'bitrateMbps': request.bitrateMbps,
      'height': request.height,
      'lowLatency': request.lowLatency,
    });
  }

  Future<T> _invoke<T>(
    String method,
    Object? arguments,
    T Function(Object? raw) decode,
  ) async {
    try {
      final raw = await _methods.invokeMethod<Object>(method, arguments);
      return decode(raw);
    } on PlatformException catch (error) {
      throw CaptureFailure(code: error.code, detail: error.message);
    }
  }

  Future<void> _invokeVoid(String method, [Object? arguments]) async {
    try {
      await _methods.invokeMethod<void>(method, arguments);
    } on PlatformException catch (error) {
      throw CaptureFailure(code: error.code, detail: error.message);
    }
  }
}
