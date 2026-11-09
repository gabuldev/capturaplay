import 'package:captura_capture/captura_capture.dart';
import 'package:flutter/material.dart';

import '../studio_controller.dart';
import '../theme.dart';

class ControlBar extends StatelessWidget {
  const ControlBar({super.key, required this.controller});

  final StudioController controller;

  @override
  Widget build(BuildContext context) {
    final format = controller.displayedFormat;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: CapturaColors.bar,
        border: Border.all(color: CapturaColors.line),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FieldMenu(
                  label: 'Vídeo',
                  value: controller.video?.name ?? 'Nenhum',
                  enabled: controller.videoDevices.isNotEmpty,
                  entries: [
                    for (final device in controller.videoDevices)
                      MenuEntry(
                        id: device.id,
                        label: device.name,
                        selected: device.id == controller.video?.id,
                      ),
                  ],
                  onSelected: controller.chooseVideo,
                ),
                FieldMenu(
                  label: 'Áudio',
                  value: controller.audio?.name ?? 'Sem áudio',
                  enabled: true,
                  entries: [
                    MenuEntry(
                      id: '',
                      label: 'Sem áudio',
                      selected:
                          controller.audioDisabled || controller.audio == null,
                    ),
                    for (final device in controller.audioDevices)
                      MenuEntry(
                        id: device.id,
                        label: device.name,
                        selected: device.id == controller.audio?.id,
                      ),
                  ],
                  onSelected: (id) =>
                      controller.chooseAudio(id.isEmpty ? null : id),
                ),
                FieldMenu(
                  label: 'Formato',
                  value: format == null
                      ? 'Automático'
                      : formatVideoLabel(format),
                  enabled: controller.formats.isNotEmpty,
                  entries: [
                    for (final option in controller.formats)
                      MenuEntry(
                        id: option.id,
                        label: formatVideoLabel(option),
                        selected: option.id == controller.format?.id,
                      ),
                  ],
                  onSelected: controller.chooseFormat,
                ),
                VolumeControl(controller: controller),
                IconAction(
                  tooltip: controller.statsVisible
                      ? 'Ocultar dados (I)'
                      : 'Mostrar dados (I)',
                  icon: Icons.speed,
                  active: controller.statsVisible,
                  onPressed: controller.toggleStats,
                ),
                IconAction(
                  tooltip: controller.fullscreen
                      ? 'Sair da tela cheia (F)'
                      : 'Tela cheia (F)',
                  icon: controller.fullscreen
                      ? Icons.fullscreen_exit
                      : Icons.fullscreen,
                  active: controller.fullscreen,
                  onPressed: controller.toggleFullscreen,
                ),
                IconAction(
                  tooltip: 'Atualizar dispositivos',
                  icon: Icons.refresh,
                  onPressed: controller.retry,
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              'F ou duplo clique: tela cheia    ⌘⌃F: tela cheia do sistema    M: mudo    I: dados    ↑↓: volume',
              style: TextStyle(
                color: CapturaColors.muted,
                fontSize: 11,
                height: 1.3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class VolumeControl extends StatelessWidget {
  const VolumeControl({super.key, required this.controller});

  final StudioController controller;

  @override
  Widget build(BuildContext context) {
    final muted = controller.volume.muted || controller.volume.level == 0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconAction(
          tooltip: muted ? 'Ativar som (M)' : 'Mudo (M)',
          icon: muted ? Icons.volume_off : Icons.volume_up,
          active: muted,
          onPressed: controller.toggleMute,
        ),
        SizedBox(
          width: 128,
          child: Slider(
            value: controller.volume.level.clamp(0, 1).toDouble(),
            onChanged: controller.setLevel,
          ),
        ),
        SizedBox(
          width: 40,
          child: Text(
            formatVolumePercent(controller.volume.effective),
            style: const TextStyle(
              color: CapturaColors.ink,
              fontSize: 12,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

class IconAction extends StatelessWidget {
  const IconAction({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.active = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      style: IconButton.styleFrom(
        foregroundColor: active ? CapturaColors.brassInk : CapturaColors.ink,
        backgroundColor: active ? CapturaColors.brass : Colors.transparent,
        side: const BorderSide(color: CapturaColors.line),
        minimumSize: const Size(36, 36),
        padding: const EdgeInsets.all(8),
      ),
      icon: Icon(icon, size: 18),
    );
  }
}

class MenuEntry {
  const MenuEntry({
    required this.id,
    required this.label,
    required this.selected,
  });

  final String id;
  final String label;
  final bool selected;
}

class FieldMenu extends StatelessWidget {
  const FieldMenu({
    super.key,
    required this.label,
    required this.value,
    required this.entries,
    required this.onSelected,
    required this.enabled,
  });

  final String label;
  final String value;
  final List<MenuEntry> entries;
  final ValueChanged<String> onSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      style: const MenuStyle(
        backgroundColor: WidgetStatePropertyAll(Color(0xFF1C1D18)),
        surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
        maximumSize: WidgetStatePropertyAll(Size(440, 360)),
      ),
      menuChildren: [
        for (final entry in entries)
          MenuItemButton(
            onPressed: enabled ? () => onSelected(entry.id) : null,
            leadingIcon: Icon(
              entry.selected ? Icons.check : Icons.circle,
              size: entry.selected ? 16 : 6,
              color: entry.selected ? CapturaColors.brass : CapturaColors.line,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Text(
                entry.label,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: CapturaColors.ink),
              ),
            ),
          ),
      ],
      builder: (context, menu, child) {
        return Opacity(
          opacity: enabled ? 1 : 0.45,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: enabled
                  ? () {
                      if (menu.isOpen) {
                        menu.close();
                      } else {
                        menu.open();
                      }
                    }
                  : null,
              borderRadius: BorderRadius.circular(10),
              child: Ink(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: CapturaColors.line),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label.toUpperCase(),
                      style: const TextStyle(
                        color: CapturaColors.muted,
                        fontSize: 10,
                        letterSpacing: 0.8,
                      ),
                    ),
                    const SizedBox(height: 2),
                    SizedBox(
                      width: 180,
                      child: Text(
                        value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: CapturaColors.ink,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
