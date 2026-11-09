import 'package:captura_capture/captura_capture.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('lê o estado nativo e ignora lixo', () {
    final snapshot = snapshotFrom({
      'authorization': {'video': 'authorized', 'audio': 'notDetermined'},
      'videoDevices': [
        {'id': 'cam', 'name': 'Cam Link 4K'},
        {'name': 'sem id'},
      ],
      'audioDevices': [
        {'id': 'cam-audio', 'name': 'Cam Link 4K', 'connected': false},
      ],
      'preferences': {
        'videoDeviceId': 'cam',
        'audioDeviceId': null,
        'formatId': '',
        'volume': 0.5,
        'muted': true,
        'audioDisabled': false,
      },
      'session': {
        'running': true,
        'activeFormat': {
          'id': '1080p60',
          'width': 1920,
          'height': 1080,
          'fps': 60,
        },
        'errorCode': null,
        'warningCode': 'audio-unavailable',
      },
      'fullscreen': true,
    });

    expect(snapshot.authorization.video, PermissionStatus.authorized);
    expect(snapshot.authorization.audio, PermissionStatus.notDetermined);
    expect(snapshot.authorization.needsRequest, isTrue);
    expect(snapshot.videoDevices, hasLength(1));
    expect(snapshot.audioDevices.single.connected, isFalse);
    expect(snapshot.preferences.videoDeviceId, 'cam');
    expect(snapshot.preferences.formatId, isNull);
    expect(snapshot.preferences.volume, 0.5);
    expect(snapshot.preferences.muted, isTrue);
    expect(snapshot.session.running, isTrue);
    expect(snapshot.session.activeFormat?.fps, 60);
    expect(snapshot.session.warningCode, 'audio-unavailable');
    expect(snapshot.fullscreen, isTrue);
  });

  test('eventos desconhecidos e malformados não quebram', () {
    expect(eventFrom(null), isNull);
    expect(eventFrom({'type': 'nope'}), isNull);
    expect(snapshotFrom('lixo').authorization.video, PermissionStatus.unknown);

    final stats = eventFrom({'type': 'stats', 'fps': 59.9, 'latencyMs': null});
    expect(stats, isA<StatsChanged>());
    expect((stats! as StatsChanged).stats.fps, closeTo(59.9, 0.001));
    expect((stats as StatsChanged).stats.latencyMs, isNull);

    final fullscreen = eventFrom({'type': 'fullscreen', 'value': true});
    expect(fullscreen, isA<FullScreenChanged>());
  });
}
