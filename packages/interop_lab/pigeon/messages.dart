import 'package:pigeon/pigeon.dart';

// Caminho 2: Pigeon. Você descreve a interface aqui e roda
//   dart run pigeon --input pigeon/messages.dart
// O Pigeon gera o Dart e o Swift. Por baixo continua sendo um canal
// (BasicMessageChannel + StandardMessageCodec), só que tipado.

@ConfigurePigeon(
  PigeonOptions(
    dartPackageName: 'interop_lab',
    dartOut: 'lib/src/messages.g.dart',
    swiftOut: 'macos/interop_lab/Sources/interop_lab/Messages.g.swift',
  ),
)
class LabStatsMessage {
  LabStatsMessage({
    required this.fps,
    required this.latencyMs,
    required this.dropped,
    required this.frames,
  });

  double fps;
  double latencyMs;
  int dropped;
  int frames;
}

@HostApi()
abstract class LabPigeonApi {
  int ping(int value);

  void setVolume(double volume);

  LabStatsMessage getStats();
}
