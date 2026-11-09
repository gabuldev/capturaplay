import 'dart:async';

import 'package:flutter/services.dart';

class ReceiverService {
  const ReceiverService(this.name);

  final String name;
}

sealed class ReceiverEvent {
  const ReceiverEvent();
}

class ReceiverServicesChanged extends ReceiverEvent {
  const ReceiverServicesChanged(this.names);

  final List<String> names;
}

class ReceiverPhaseChanged extends ReceiverEvent {
  const ReceiverPhaseChanged({required this.phase, this.detail});

  final String phase;
  final String? detail;
}

class ReceiverStatsChanged extends ReceiverEvent {
  const ReceiverStatsChanged({required this.fps, this.latencyMs});

  final double fps;
  final double? latencyMs;
}

abstract class ReceiverClient {
  Stream<ReceiverEvent> get events;

  Future<void> start();

  Future<void> stop();

  Future<void> connectService(String name);

  Future<void> connectHost(String host, int port);

  Future<void> disconnect();
}

class MethodChannelReceiverClient implements ReceiverClient {
  MethodChannelReceiverClient({MethodChannel? methods, EventChannel? events})
    : _methods = methods ?? const MethodChannel('captura_lan/receiver'),
      _events = events ?? const EventChannel('captura_lan/events');

  final MethodChannel _methods;
  final EventChannel _events;
  Stream<ReceiverEvent>? _cached;

  @override
  Stream<ReceiverEvent> get events {
    return _cached ??= _events
        .receiveBroadcastStream()
        .map(_decode)
        .where((event) => event != null)
        .cast<ReceiverEvent>();
  }

  @override
  Future<void> start() => _methods.invokeMethod<void>('start');

  @override
  Future<void> stop() => _methods.invokeMethod<void>('stop');

  @override
  Future<void> connectService(String name) {
    return _methods.invokeMethod<void>('connectService', {'name': name});
  }

  @override
  Future<void> connectHost(String host, int port) {
    return _methods.invokeMethod<void>('connectHost', {
      'host': host,
      'port': port,
    });
  }

  @override
  Future<void> disconnect() => _methods.invokeMethod<void>('disconnect');
}

ReceiverEvent? _decode(Object? raw) {
  if (raw is! Map) return null;
  final map = raw.map((key, value) => MapEntry(key.toString(), value));
  switch (map['type']) {
    case 'services':
      final names = <String>[];
      final rawNames = map['names'];
      if (rawNames is List) {
        for (final name in rawNames) {
          if (name is String && name.isNotEmpty) names.add(name);
        }
      }
      return ReceiverServicesChanged(names);
    case 'state':
      final phase = map['phase'];
      final detail = map['detail'];
      return ReceiverPhaseChanged(
        phase: phase is String ? phase : 'browsing',
        detail: detail is String && detail.isNotEmpty ? detail : null,
      );
    case 'stats':
      final fps = map['fps'];
      final latency = map['latencyMs'];
      return ReceiverStatsChanged(
        fps: fps is num ? fps.toDouble() : 0,
        latencyMs: latency is num ? latency.toDouble() : null,
      );
    default:
      return null;
  }
}
