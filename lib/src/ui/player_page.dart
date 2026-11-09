import 'dart:async';

import 'package:captura_capture/captura_capture.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../studio_controller.dart';
import '../theme.dart';
import 'control_bar.dart';

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key, required this.controller});

  final StudioController controller;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  final FocusNode _focus = FocusNode(debugLabel: 'capturaplay');
  Timer? _hideTimer;
  bool _chrome = true;
  bool _pointerDown = false;
  bool _cursorHidden = false;

  StudioController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    controller.addListener(_onController);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focus.requestFocus();
      if (controller.running) _armHideTimer();
    });
  }

  @override
  void dispose() {
    controller.removeListener(_onController);
    _hideTimer?.cancel();
    _focus.dispose();
    super.dispose();
  }

  void _onController() {
    if (!mounted) return;
    if (!controller.running) {
      _hideTimer?.cancel();
      _hideTimer = null;
      _showCursor();
      if (!_chrome) setState(() => _chrome = true);
      return;
    }
    if (_chrome && _hideTimer == null && !_pointerDown) {
      _armHideTimer();
    }
  }

  void _poke() {
    _hideTimer?.cancel();
    _hideTimer = null;
    _showCursor();
    if (!_chrome) setState(() => _chrome = true);
    _armHideTimer();
  }

  void _armHideTimer() {
    if (!controller.running || _pointerDown) return;
    _hideTimer = Timer(const Duration(milliseconds: 2500), _hideChrome);
  }

  void _hideChrome() {
    if (!mounted || _pointerDown || !controller.running) return;
    setState(() => _chrome = false);
    _hideCursor();
    _hideTimer = null;
  }

  void _showCursor() {
    if (!_cursorHidden) return;
    _cursorHidden = false;
    unawaited(controller.setCursorHidden(false));
  }

  void _hideCursor() {
    if (_cursorHidden || !controller.running) return;
    _cursorHidden = true;
    unawaited(controller.setCursorHidden(true));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: CapturaColors.background,
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyF):
              controller.toggleFullscreen,
          const SingleActivator(LogicalKeyboardKey.keyM): controller.toggleMute,
          const SingleActivator(LogicalKeyboardKey.keyI):
              controller.toggleStats,
          const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
              controller.nudgeVolume(0.05),
          const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
              controller.nudgeVolume(-0.05),
        },
        child: Focus(
          focusNode: _focus,
          autofocus: true,
          child: MouseRegion(
            onEnter: (_) => _poke(),
            onHover: (_) => _poke(),
            onExit: (_) => _armHideTimer(),
            child: Listener(
              onPointerDown: (_) {
                _pointerDown = true;
                _poke();
              },
              onPointerUp: (_) {
                _pointerDown = false;
                _poke();
              },
              child: ListenableBuilder(
                listenable: controller,
                builder: (context, _) {
                  final top = controller.fullscreen ? 16.0 : 36.0;
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      const ColoredBox(color: CapturaColors.background),
                      const CapturePreview(),
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onDoubleTap: controller.toggleFullscreen,
                        ),
                      ),
                      if (!controller.running)
                        Center(child: StatusCard(controller: controller)),
                      if (_chrome &&
                          controller.authorization.granted &&
                          !controller.initializing) ...[
                        Positioned(
                          top: top,
                          left: controller.fullscreen ? 16 : 84,
                          child: TopChrome(controller: controller),
                        ),
                        Positioned(
                          left: 16,
                          right: 16,
                          bottom: 16,
                          child: ControlBar(controller: controller),
                        ),
                      ],
                      if (controller.statsVisible)
                        Positioned(
                          top: top,
                          right: 16,
                          child: StatsReadout(stats: controller.stats),
                        ),
                      if (controller.running &&
                          (controller.warningCode != null ||
                              controller.errorCode != null) &&
                          _chrome)
                        Positioned(
                          left: 16,
                          right: 16,
                          bottom: 168,
                          child: MessageStrip(
                            text: controller.errorCode != null
                                ? describeCaptureError(controller.errorCode)
                                : describeCaptureWarning(
                                        controller.warningCode,
                                      ) ??
                                      '',
                            danger: controller.errorCode != null,
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class TopChrome extends StatelessWidget {
  const TopChrome({super.key, required this.controller});

  final StudioController controller;

  @override
  Widget build(BuildContext context) {
    final format = controller.displayedFormat;
    return Row(
      children: [
        const Text(
          'CapturaPlay',
          style: TextStyle(
            color: CapturaColors.ink,
            fontSize: 16,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
        ),
        const SizedBox(width: 12),
        if (format != null)
          DecoratedBox(
            decoration: BoxDecoration(
              color: CapturaColors.card,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: CapturaColors.line),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              child: Text(
                formatVideoChip(format),
                style: const TextStyle(
                  color: CapturaColors.brass,
                  fontSize: 12,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class StatsReadout extends StatelessWidget {
  const StatsReadout({super.key, required this.stats});

  final CaptureStats? stats;

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
              formatFps(stats?.fps),
              style: const TextStyle(
                color: CapturaColors.ink,
                fontSize: 14,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 2),
            Text(
              formatLatencyMs(stats?.latencyMs),
              style: const TextStyle(
                color: CapturaColors.brass,
                fontSize: 14,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 2),
            const Text(
              'latência estimada',
              style: TextStyle(color: CapturaColors.muted, fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }
}

class StatusCard extends StatelessWidget {
  const StatusCard({super.key, required this.controller});

  final StudioController controller;

  @override
  Widget build(BuildContext context) {
    final title = _title();
    final body = _body();
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460),
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
              Text(
                title,
                style: const TextStyle(
                  color: CapturaColors.ink,
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                body,
                style: const TextStyle(color: CapturaColors.muted, height: 1.4),
              ),
              const SizedBox(height: 16),
              _action(),
            ],
          ),
        ),
      ),
    );
  }

  String _title() {
    if (controller.initializing) return 'Abrindo o capturador…';
    if (!controller.authorization.granted) return 'Permissão necessária';
    if (controller.errorCode != null) return 'A captura não abriu';
    if (controller.video == null) return 'Nenhum capturador USB encontrado';
    return 'Preparando a prévia…';
  }

  String _body() {
    if (controller.initializing) {
      return 'Procurando o Cam Link e pedindo acesso à câmera e ao microfone.';
    }
    if (!controller.authorization.granted) {
      return 'O CapturaPlay precisa da câmera e do microfone para abrir o capturador USB e reproduzir o som do jogo. O microfone aqui é a entrada de áudio do próprio capturador.';
    }
    if (controller.errorCode != null) {
      final detail = controller.errorDetail;
      final message = describeCaptureError(controller.errorCode);
      if (detail == null || detail == message) return message;
      return '$message\n$detail';
    }
    if (controller.video == null) {
      return 'Conecte o capturador numa porta USB 3 do Mac, direto, sem hub. O HDMI sai do console e entra no capturador. Não precisa de splitter: a imagem aparece nesta janela.';
    }
    return 'Ajustando o formato e a prévia.';
  }

  Widget _action() {
    if (controller.initializing) {
      return const SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: CapturaColors.brass,
        ),
      );
    }
    if (!controller.authorization.granted) {
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton(
            onPressed: controller.bootstrap,
            child: const Text('Pedir acesso'),
          ),
          OutlinedButton(
            onPressed: controller.openPrivacySettings,
            child: const Text('Abrir Ajustes do Sistema'),
          ),
        ],
      );
    }
    return FilledButton(
      onPressed: controller.retry,
      child: const Text('Tentar de novo'),
    );
  }
}

class MessageStrip extends StatelessWidget {
  const MessageStrip({super.key, required this.text, required this.danger});

  final String text;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    return DecoratedBox(
      decoration: BoxDecoration(
        color: CapturaColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: danger ? CapturaColors.danger : CapturaColors.line,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(
          text,
          style: TextStyle(
            color: danger ? CapturaColors.danger : CapturaColors.ink,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}
