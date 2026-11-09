import 'package:capturaplay/src/volume.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('mudo, limite e subir o volume desmuta', () {
    const full = VolumeState.full;
    expect(full.effective, 1);

    final muted = full.toggleMute();
    expect(muted.muted, isTrue);
    expect(muted.effective, 0);

    final raised = muted.nudge(0.05);
    expect(raised.level, closeTo(1.05.clamp(0, 1), 0.001));
    expect(raised.muted, isFalse);

    final clamped = VolumeState(level: 0.02, muted: false).nudge(-1);
    expect(clamped.level, 0);
    expect(clamped.muted, isFalse);
  });
}
