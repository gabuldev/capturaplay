import 'channel_lab.dart';
import 'direct_lab.dart';
import 'pigeon_lab.dart';

class BenchRow {
  const BenchRow(this.path, this.operation, this.microsPerCall);

  final String path;
  final String operation;
  final double microsPerCall;
}

/// Runs each operation [calls] times on each path and reports the mean cost.
/// Run it in profile or release: debug (JIT) makes the Dart side look slower.
Future<List<BenchRow>> runBench({
  required ChannelLab channel,
  required PigeonLab pigeon,
  required DirectLab direct,
  int calls = 20000,
}) async {
  final rows = <BenchRow>[];

  Future<void> measure(
    String path,
    String operation,
    Future<void> Function(int i) body,
  ) async {
    for (var i = 0; i < 500; i++) {
      await body(i);
    }
    final watch = Stopwatch()..start();
    for (var i = 0; i < calls; i++) {
      await body(i);
    }
    watch.stop();
    rows.add(BenchRow(path, operation, watch.elapsedMicroseconds / calls));
  }

  void measureSync(String path, String operation, void Function(int i) body) {
    for (var i = 0; i < 500; i++) {
      body(i);
    }
    final watch = Stopwatch()..start();
    for (var i = 0; i < calls; i++) {
      body(i);
    }
    watch.stop();
    rows.add(BenchRow(path, operation, watch.elapsedMicroseconds / calls));
  }

  var sink = 0.0;

  await measure(
    'MethodChannel',
    'ping',
    (i) async => sink += await channel.ping(i),
  );
  await measure('Pigeon', 'ping', (i) async => sink += await pigeon.ping(i));
  measureSync('FFI direto', 'ping', (i) => sink += direct.ping(i));

  await measure(
    'MethodChannel',
    'setVolume',
    (i) => channel.setVolume(i / calls),
  );
  await measure('Pigeon', 'setVolume', (i) => pigeon.setVolume(i / calls));
  measureSync('FFI direto', 'setVolume', (i) => direct.setVolume(i / calls));

  await measure(
    'MethodChannel',
    'getStats',
    (_) async => sink += (await channel.getStats()).fps,
  );
  await measure(
    'Pigeon',
    'getStats',
    (_) async => sink += (await pigeon.getStats()).fps,
  );
  measureSync('FFI direto', 'getStats', (_) => sink += direct.readStats().fps);

  // Keeps the compiler from dropping the work above.
  if (sink.isNaN) rows.clear();
  return rows;
}
