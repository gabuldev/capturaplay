class VolumeState {
  const VolumeState({required this.level, required this.muted});

  final double level;
  final bool muted;

  double get effective => muted ? 0 : level.clamp(0, 1).toDouble();

  VolumeState toggleMute() => VolumeState(level: level, muted: !muted);

  /// Raising the level above zero unmutes. Dragging to zero keeps the mute flag.
  VolumeState withLevel(double next) {
    final clamped = next.clamp(0.0, 1.0).toDouble();
    return VolumeState(level: clamped, muted: clamped == 0 ? muted : false);
  }

  VolumeState nudge(double delta) => withLevel(level + delta);

  static const full = VolumeState(level: 1, muted: false);
}
