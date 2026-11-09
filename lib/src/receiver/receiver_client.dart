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
  const ReceiverStatsChanged({
    required this.fps,
    this.displayedFps,
    this.latencyMs,
    this.dropped = 0,
    this.receiverDrops = 0,
    this.bufferDepth = 0,
  });

  final double fps;
  final double? displayedFps;
  final double? latencyMs;
  final int dropped;
  final int receiverDrops;
  final int bufferDepth;
}

abstract class ReceiverClient {
  Stream<ReceiverEvent> get events;

  Future<void> start();

  Future<void> stop();

  Future<void> connectService(String name);

  Future<void> connectHost(String host, int port);

  Future<void> disconnect();

  Future<void> setSmooth(bool smooth);
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

  @override
  Future<void> setSmooth(bool smooth) {
    return _methods.invokeMethod<void>('setSmooth', {'smooth': smooth});
  }
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
      final displayed = map['displayedFps'];
      final latency = map['latencyMs'];
      final dropped = map['dropped'];
      final receiverDrops = map['receiverDrops'];
      final bufferDepth = map['bufferDepth'];
      return ReceiverStatsChanged(
        fps: fps is num ? fps.toDouble() : 0,
        displayedFps: displayed is num ? displayed.toDouble() : null,
        latencyMs: latency is num ? latency.toDouble() : null,
        dropped: dropped is num ? dropped.toInt() : 0,
        receiverDrops: receiverDrops is num ? receiverDrops.toInt() : 0,
        bufferDepth: bufferDepth is num ? bufferDepth.toInt() : 0,
      );
    default:
      return null;
  }
}
