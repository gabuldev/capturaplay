import 'dart:async';

import 'package:captura_capture/captura_capture.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import 'receiver_client.dart';

class ReceiverApp extends StatefulWidget {
  const ReceiverApp({super.key, this.client});

  final ReceiverClient? client;

  @override
  State<ReceiverApp> createState() => _ReceiverAppState();
}

class _ReceiverAppState extends State<ReceiverApp> {
  late final ReceiverClient _client =
      widget.client ?? MethodChannelReceiverClient();
  late final ReceiverController _controller = ReceiverController(
    client: _client,
  );

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _controller.start();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CapturaPlay',
      debugShowCheckedModeBanner: false,
      theme: capturaTheme(),
      home: ReceiverPage(controller: _controller),
    );
  }
}

class ReceiverController extends ChangeNotifier {
  ReceiverController({required this.client});

  final ReceiverClient client;
  StreamSubscription<ReceiverEvent>? _subscription;

  List<String> services = const [];
  String phase = 'browsing';
  String? detail;
  double? fps;
  double? latencyMs;
  int droppedFrames = 0;
  bool showStats = false;
  bool chrome = true;

  bool get connected => phase == 'connected';

  Future<void> start() async {
    _subscription ??= client.events.listen(_onEvent);
    await client.start();
  }

  void _onEvent(ReceiverEvent event) {
    switch (event) {
      case ReceiverServicesChanged(:final names):
        services = names;
      case ReceiverPhaseChanged(:final phase, :final detail):
        this.phase = phase;
        this.detail = detail;
        if (phase != 'connected') {
          fps = null;
          latencyMs = null;
          droppedFrames = 0;
        }
      case ReceiverStatsChanged(:final fps, :final latencyMs, :final dropped):
        this.fps = fps;
        this.latencyMs = latencyMs;
        droppedFrames = dropped;
    }
    notifyListeners();
  }

  Future<void> connectService(String name) => client.connectService(name);

  Future<void> connectManual(String raw) async {
    final endpoint = parseManualEndpoint(raw);
    if (endpoint == null) return;
    await client.connectHost(endpoint.host, endpoint.port);
  }

  Future<void> disconnect() => client.disconnect();

  void toggleStats() {
    showStats = !showStats;
    notifyListeners();
  }

  void toggleChrome() {
    chrome = !chrome;
    notifyListeners();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    unawaited(client.stop());
    super.dispose();
  }
}

class ReceiverPage extends StatefulWidget {
  const ReceiverPage({super.key, required this.controller});

  final ReceiverController controller;

  @override
  State<ReceiverPage> createState() => _ReceiverPageState();
}

class _ReceiverPageState extends State<ReceiverPage> {
  final TextEditingController _address = TextEditingController();

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: CapturaColors.background,
      body: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final controller = widget.controller;
          return Stack(
            fit: StackFit.expand,
            children: [
              const ColoredBox(color: CapturaColors.background),
              if (controller.connected) const ReceiverPreview(),
              GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: controller.connected ? controller.toggleChrome : null,
              ),
              if (!controller.connected)
                _Picker(controller: controller, address: _address),
              if (controller.connected && controller.chrome)
                _ConnectedChrome(controller: controller),
              if (controller.connected && controller.showStats)
                Positioned(
                  top: 16,
                  right: 16,
                  child: _Stats(
                    fps: controller.fps,
                    latencyMs: controller.latencyMs,
                    dropped: controller.droppedFrames,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class ReceiverPreview extends StatelessWidget {
  const ReceiverPreview({super.key});

  static const viewType = 'captura_lan/display';

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      return const ColoredBox(color: CapturaColors.background);
    }
    return const UiKitView(
      viewType: viewType,
      hitTestBehavior: PlatformViewHitTestBehavior.transparent,
    );
  }
}

class _Picker extends StatelessWidget {
  const _Picker({required this.controller, required this.address});

  final ReceiverController controller;
  final TextEditingController address;

  @override
  Widget build(BuildContext context) {
    final title = switch (controller.phase) {
      'connecting' => 'Conectando…',
      'reconnecting' => 'Reconectando…',
      _ => 'Procurando o Mac na rede',
    };
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: CapturaColors.card,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: CapturaColors.line),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'CapturaPlay',
                  style: TextStyle(
                    color: CapturaColors.ink,
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  title,
                  style: const TextStyle(
                    color: CapturaColors.muted,
                    height: 1.35,
                  ),
                ),
                if (controller.detail != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    controller.detail!,
                    style: const TextStyle(
                      color: CapturaColors.danger,
                      fontSize: 13,
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                if (controller.services.isEmpty)
                  const Text(
                    'Ligue “Transmitir na rede” no Mac, na mesma Wi-Fi.',
                    style: TextStyle(color: CapturaColors.ink),
                  )
                else
                  for (final name in controller.services)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: FilledButton(
                        onPressed: () => controller.connectService(name),
                        child: Text(name),
                      ),
                    ),
                const SizedBox(height: 8),
                TextField(
                  controller: address,
                  style: const TextStyle(color: CapturaColors.ink),
                  decoration: const InputDecoration(
                    labelText: 'IP do Mac, se o Bonjour não achar',
                    hintText: '192.168.1.20',
                    labelStyle: TextStyle(color: CapturaColors.muted),
                    hintStyle: TextStyle(color: CapturaColors.muted),
                  ),
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  onSubmitted: controller.connectManual,
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: () => controller.connectManual(address.text),
                  child: const Text('Conectar pelo IP'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ConnectedChrome extends StatelessWidget {
  const _ConnectedChrome({required this.controller});

  final ReceiverController controller;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 16,
      right: 16,
      bottom: 16,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: CapturaColors.bar,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: CapturaColors.line),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'CapturaPlay',
                  style: TextStyle(
                    color: CapturaColors.ink,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              TextButton(
                onPressed: controller.toggleStats,
                child: Text(controller.showStats ? 'Ocultar dados' : 'Dados'),
              ),
              TextButton(
                onPressed: controller.disconnect,
                child: const Text('Desconectar'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Stats extends StatelessWidget {
  const _Stats({
    required this.fps,
    required this.latencyMs,
    required this.dropped,
  });

  final double? fps;
  final double? latencyMs;
  final int dropped;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: CapturaColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: CapturaColors.line),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              formatFps(fps),
              style: const TextStyle(
                color: CapturaColors.ink,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            Text(
              formatLatencyMs(latencyMs),
              style: const TextStyle(
                color: CapturaColors.brass,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            Text(
              'descartes $dropped',
              style: const TextStyle(color: CapturaColors.muted, fontSize: 10),
            ),
            const Text(
              'captura → tela',
              style: TextStyle(color: CapturaColors.muted, fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }
}
