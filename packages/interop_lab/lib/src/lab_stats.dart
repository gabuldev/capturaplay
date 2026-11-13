/// The same stats, whichever path brought them.
class LabStats {
  const LabStats({
    required this.fps,
    required this.latencyMs,
    required this.dropped,
    required this.frames,
  });

  final double fps;
  final double latencyMs;
  final int dropped;
  final int frames;
}
