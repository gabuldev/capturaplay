import 'dart:ffi';

import 'package:flutter/services.dart';

import 'lab_stats.dart';

/// Slots of the table built in `DirectExports.swift`. Keep both in sync.
abstract final class _Slot {
  static const ping = 0;
  static const setVolume = 1;
  static const getVolume = 2;
  static const isMainThread = 3;
  static const stats = 4;
}

/// Layout of the stats memory written by `LabEngine.swift`, in 8-byte words.
abstract final class _LabStatsLayout {
  static const seq = 0;
  static const fps = 1;
  static const latencyMs = 2;
  static const dropped = 3;
  static const frames = 4;
}

/// Caminho 3: chamada direta com `dart:ffi`.
///
/// Depois do `connect`, nenhuma chamada passa por canal:
///   - não tem codec: `double` vai em registrador, como numa chamada C
///   - não tem fila: roda agora, na thread atual, e devolve o valor na hora
///   - por isso é síncrono: `ping(1)` devolve `int`, não `Future<int>`
///
/// O preço:
///   - você escreve o "contrato" à mão (tipos C, ordem dos slots, layout de memória)
///   - errou o tipo ou o slot? não é exceção, é crash
///   - uma função nativa lenta trava a UI, porque roda na thread de UI
class DirectLab {
  DirectLab._(Pointer<Pointer<Void>> table)
    : _ping = table[_Slot.ping]
          .cast<NativeFunction<Int64 Function(Int64)>>()
          // isLeaf: a função não chama de volta pro Dart nem demora. O Dart
          // pula a troca de estado da VM e a chamada fica ainda mais barata.
          .asFunction<int Function(int)>(isLeaf: true),
      _setVolume = table[_Slot.setVolume]
          .cast<NativeFunction<Void Function(Double)>>()
          .asFunction<void Function(double)>(isLeaf: true),
      _getVolume = table[_Slot.getVolume]
          .cast<NativeFunction<Double Function()>>()
          .asFunction<double Function()>(isLeaf: true),
      _isMainThread = table[_Slot.isMainThread]
          .cast<NativeFunction<Bool Function()>>()
          .asFunction<bool Function()>(isLeaf: true),
      _stats = table[_Slot.stats].cast<Int64>();

  /// Asks the plugin for the table address once. The only channel call.
  static Future<DirectLab> connect([
    MethodChannel channel = const MethodChannel('interop_lab/methods'),
  ]) async {
    final address = (await channel.invokeMethod<int>('directTable'))!;
    return DirectLab._(Pointer<Pointer<Void>>.fromAddress(address));
  }

  final int Function(int) _ping;
  final void Function(double) _setVolume;
  final double Function() _getVolume;
  final bool Function() _isMainThread;
  final Pointer<Int64> _stats;

  int ping(int value) => _ping(value);

  void setVolume(double volume) => _setVolume(volume);

  double get volume => _getVolume();

  /// True when Dart's UI thread is the platform main thread (merged threads).
  bool get runsOnMainThread => _isMainThread();

  /// Reads the stats straight from native memory. No message, no copy on the
  /// native side, no wait: call it every frame if you like.
  LabStats readStats() {
    final doubles = _stats.cast<Double>();
    while (true) {
      final before = _stats[_LabStatsLayout.seq];
      if (before.isOdd) continue;
      final stats = LabStats(
        fps: doubles[_LabStatsLayout.fps],
        latencyMs: doubles[_LabStatsLayout.latencyMs],
        dropped: _stats[_LabStatsLayout.dropped],
        frames: _stats[_LabStatsLayout.frames],
      );
      if (_stats[_LabStatsLayout.seq] == before) return stats;
    }
  }
}
