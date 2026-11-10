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
  double? displayedFps;
  double? latencyMs;
  int droppedFrames = 0;
  int receiverDrops = 0;
  int bufferDepth = 0;
  int decoderErrors = 0;
  int waitingKeyframe = 0;
  int bitrateMbps = 0;
  int maxFrameQp = 0;
  double stageCaptureMs = -1;
  double stageEncodeMs = -1;
  double stageQueueMs = -1;
  double stageNetworkMs = -1;
  double stageDecodeMs = -1;
  double stageGlassMs = -1;
  double offsetMs = 0;
  double rttMs = 0;
  bool clockSkew = false;
  bool showStats = false;
  bool smooth = true;
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
          displayedFps = null;
          latencyMs = null;
          droppedFrames = 0;
          receiverDrops = 0;
          bufferDepth = 0;
          decoderErrors = 0;
          waitingKeyframe = 0;
          bitrateMbps = 0;
          maxFrameQp = 0;
          stageCaptureMs = -1;
          stageEncodeMs = -1;
          stageQueueMs = -1;
          stageNetworkMs = -1;
          stageDecodeMs = -1;
          stageGlassMs = -1;
          offsetMs = 0;
          rttMs = 0;
          clockSkew = false;
        }
      case ReceiverStatsChanged(
        :final fps,
        :final displayedFps,
        :final latencyMs,
        :final dropped,
        :final receiverDrops,
        :final bufferDepth,
        :final decoderErrors,
        :final waitingKeyframe,
        :final bitrateMbps,
        :final maxFrameQp,
        :final stageCaptureMs,
        :final stageEncodeMs,
        :final stageQueueMs,
        :final stageNetworkMs,
        :final stageDecodeMs,
        :final stageGlassMs,
        :final offsetMs,
        :final rttMs,
        :final clockSkew,
      ):
        this.fps = fps;
        this.displayedFps = displayedFps;
        this.latencyMs = latencyMs;
        droppedFrames = dropped;
        this.receiverDrops = receiverDrops;
        this.bufferDepth = bufferDepth;
        this.decoderErrors = decoderErrors;
        this.waitingKeyframe = waitingKeyframe;
        this.bitrateMbps = bitrateMbps;
        this.maxFrameQp = maxFrameQp;
        this.stageCaptureMs = stageCaptureMs;
        this.stageEncodeMs = stageEncodeMs;
        this.stageQueueMs = stageQueueMs;
        this.stageNetworkMs = stageNetworkMs;
        this.stageDecodeMs = stageDecodeMs;
        this.stageGlassMs = stageGlassMs;
        this.offsetMs = offsetMs;
        this.rttMs = rttMs;
        this.clockSkew = clockSkew;
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

  Future<void> toggleSmooth() async {
    smooth = !smooth;
    notifyListeners();
    await client.setSmooth(smooth);
  }

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
                    displayedFps: controller.displayedFps,
                    latencyMs: controller.latencyMs,
                    dropped: controller.droppedFrames,
                    receiverDrops: controller.receiverDrops,
                    bufferDepth: controller.bufferDepth,
                    decoderErrors: controller.decoderErrors,
                    waitingKeyframe: controller.waitingKeyframe,
                    bitrateMbps: controller.bitrateMbps,
                    maxFrameQp: controller.maxFrameQp,
                    stageCaptureMs: controller.stageCaptureMs,
                    stageEncodeMs: controller.stageEncodeMs,
                    stageQueueMs: controller.stageQueueMs,
                    stageNetworkMs: controller.stageNetworkMs,
                    stageDecodeMs: controller.stageDecodeMs,
                    stageGlassMs: controller.stageGlassMs,
                    offsetMs: controller.offsetMs,
                    rttMs: controller.rttMs,
                    clockSkew: controller.clockSkew,
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
                onPressed: controller.toggleSmooth,
                child: Text(
                  controller.smooth ? 'Suave' : 'Ultra baixa latência',
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

String _ms(double value) {
  if (value < 0) return '—';
  return value.round().toString();
}

String _signed(double value) {
  final rounded = value.round();
  if (rounded > 0) return '+$rounded';
  return '$rounded';
}

class _Stats extends StatelessWidget {
  const _Stats({
    required this.fps,
    required this.displayedFps,
    required this.latencyMs,
    required this.dropped,
    required this.receiverDrops,
    required this.bufferDepth,
    required this.decoderErrors,
    required this.waitingKeyframe,
    required this.bitrateMbps,
    required this.maxFrameQp,
    required this.stageCaptureMs,
    required this.stageEncodeMs,
    required this.stageQueueMs,
    required this.stageNetworkMs,
    required this.stageDecodeMs,
    required this.stageGlassMs,
    required this.offsetMs,
    required this.rttMs,
    required this.clockSkew,
  });

  final double? fps;
  final double? displayedFps;
  final double? latencyMs;
  final int dropped;
  final int receiverDrops;
  final int bufferDepth;
  final int decoderErrors;
  final int waitingKeyframe;
  final int bitrateMbps;
  final int maxFrameQp;
  final double stageCaptureMs;
  final double stageEncodeMs;
  final double stageQueueMs;
  final double stageNetworkMs;
  final double stageDecodeMs;
  final double stageGlassMs;
  final double offsetMs;
  final double rttMs;
  final bool clockSkew;

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
              '${formatFps(fps)} chegam',
              style: const TextStyle(
                color: CapturaColors.ink,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            Text(
              '${formatFps(displayedFps)} na tela',
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
              'rede $dropped · tela $receiverDrops · buffer $bufferDepth',
              style: const TextStyle(color: CapturaColors.muted, fontSize: 10),
            ),
            Text(
              'decoder $decoderErrors · espera IDR $waitingKeyframe',
              style: const TextStyle(color: CapturaColors.muted, fontSize: 10),
            ),
            Text(
              bitrateMbps > 0
                  ? (maxFrameQp > 0
                        ? '$bitrateMbps Mb/s · QP ≤ $maxFrameQp'
                        : '$bitrateMbps Mb/s')
                  : 'taxa do encoder indisponível',
              style: const TextStyle(color: CapturaColors.muted, fontSize: 10),
            ),
            Text(
              'cap ${_ms(stageCaptureMs)} · enc ${_ms(stageEncodeMs)} · tx ${_ms(stageQueueMs)} · rede ${_ms(stageNetworkMs)}',
              style: const TextStyle(color: CapturaColors.muted, fontSize: 10),
            ),
            Text(
              'dec ${_ms(stageDecodeMs)} · vidro ${_ms(stageGlassMs)}',
              style: const TextStyle(color: CapturaColors.muted, fontSize: 10),
            ),
            Text(
              'off ${_signed(offsetMs)} · rtt ${_ms(rttMs)}${clockSkew ? ' · relógio' : ''}',
              style: TextStyle(
                color: clockSkew ? CapturaColors.brass : CapturaColors.muted,
                fontSize: 10,
              ),
            ),
            const Text(
              'captura → vidro',
              style: TextStyle(color: CapturaColors.muted, fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }
}
