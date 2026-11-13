import 'lab_stats.dart';
import 'messages.g.dart';

/// Caminho 2: Pigeon. Mesmo transporte do caminho 1, mas o código de
/// serialização é gerado a partir de `pigeon/messages.dart`, então nome e tipos
/// são checados pelo compilador dos dois lados. Continua assíncrono.
class PigeonLab {
  PigeonLab([LabPigeonApi? api]) : _api = api ?? LabPigeonApi();

  final LabPigeonApi _api;

  Future<int> ping(int value) => _api.ping(value);

  Future<void> setVolume(double volume) => _api.setVolume(volume);

  Future<LabStats> getStats() async {
    final m = await _api.getStats();
    return LabStats(
      fps: m.fps,
      latencyMs: m.latencyMs,
      dropped: m.dropped,
      frames: m.frames,
    );
  }
}
