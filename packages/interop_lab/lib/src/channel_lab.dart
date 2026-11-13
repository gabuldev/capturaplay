import 'package:flutter/services.dart';

import 'lab_stats.dart';

/// Caminho 1: MethodChannel. É assim que o `captura_capture` fala com o Swift hoje.
///
/// Toda chamada:
///   1. codifica nome + argumentos com StandardMessageCodec (Dart -> bytes)
///   2. manda a mensagem pela fila do engine até a thread de plataforma
///   3. o Swift decodifica, executa, codifica a resposta
///   4. a resposta volta pela fila e completa um Future no próximo giro do loop
/// Por isso tudo aqui é `Future`, mesmo quando o trabalho é somar 1.
class ChannelLab {
  const ChannelLab([
    this._channel = const MethodChannel('interop_lab/methods'),
  ]);

  final MethodChannel _channel;

  Future<int> ping(int value) async {
    final reply = await _channel.invokeMethod<int>('ping', value);
    return reply!;
  }

  Future<void> setVolume(double volume) {
    // Nome em String e argumento em Map: erro de digitação só aparece em runtime.
    return _channel.invokeMethod<void>('setVolume', {'volume': volume});
  }

  Future<LabStats> getStats() async {
    final map = (await _channel.invokeMapMethod<String, Object?>('getStats'))!;
    return LabStats(
      fps: (map['fps']! as num).toDouble(),
      latencyMs: (map['latencyMs']! as num).toDouble(),
      dropped: map['dropped']! as int,
      frames: map['frames']! as int,
    );
  }
}
