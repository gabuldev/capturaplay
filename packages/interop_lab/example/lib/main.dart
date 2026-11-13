import 'package:flutter/scheduler.dart';
import 'package:interop_lab/interop_lab.dart';
import 'package:material_ui/material_ui.dart';

void main() => runApp(const LabApp());

class LabApp extends StatelessWidget {
  const LabApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Interop Lab',
      theme: ThemeData.dark(),
      home: const LabPage(),
    );
  }
}

class LabPage extends StatefulWidget {
  const LabPage({super.key});

  @override
  State<LabPage> createState() => _LabPageState();
}

class _LabPageState extends State<LabPage> with SingleTickerProviderStateMixin {
  DirectLab? _direct;
  List<BenchRow>? _rows;
  late final Ticker _ticker = createTicker(
    (_) => _live.value = _direct?.readStats(),
  );
  final ValueNotifier<LabStats?> _live = ValueNotifier(null);

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final direct = await DirectLab.connect();
    setState(() => _direct = direct);
    _ticker.start();
    debugPrint('[lab] ui thread == main thread: ${direct.runsOnMainThread}');

    final rows = await runBench(
      channel: const ChannelLab(),
      pigeon: PigeonLab(),
      direct: direct,
    );
    for (final row in rows) {
      debugPrint(
        '[lab] ${row.operation.padRight(10)} ${row.path.padRight(14)} '
        '${row.microsPerCall.toStringAsFixed(3)} µs/chamada',
      );
    }
    debugPrint('[lab] done');
    if (mounted) setState(() => _rows = rows);
  }

  @override
  void dispose() {
    _ticker.dispose();
    _live.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final direct = _direct;
    final rows = _rows;
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Interop Lab',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            if (direct != null)
              Text('Thread de UI é a main thread: ${direct.runsOnMainThread}'),
            const SizedBox(height: 16),
            const Text(
              'Stats ao vivo, lidos da memória nativa a cada frame (FFI):',
            ),
            ValueListenableBuilder<LabStats?>(
              valueListenable: _live,
              builder: (context, s, _) => Text(
                s == null
                    ? '…'
                    : '${s.fps.toStringAsFixed(1)} fps · '
                          '${s.latencyMs.toStringAsFixed(0)} ms · '
                          'frame ${s.frames} · drops ${s.dropped}',
                style: const TextStyle(
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(height: 24),
            if (rows == null)
              const Text('Medindo… (20 mil chamadas por caminho)')
            else
              Table(
                columnWidths: const {
                  0: FixedColumnWidth(120),
                  1: FixedColumnWidth(160),
                },
                children: [
                  const TableRow(
                    children: [
                      Text('Operação'),
                      Text('Caminho'),
                      Text('µs/chamada'),
                    ],
                  ),
                  for (final row in rows)
                    TableRow(
                      children: [
                        Text(row.operation),
                        Text(row.path),
                        Text(row.microsPerCall.toStringAsFixed(3)),
                      ],
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
