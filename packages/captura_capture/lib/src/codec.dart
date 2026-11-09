import 'models.dart';

Map<String, Object?> asStringMap(Object? raw) {
  if (raw is! Map) return const {};
  final result = <String, Object?>{};
  raw.forEach((key, value) {
    result[key.toString()] = value;
  });
  return result;
}

int asInt(Object? value) {
  if (value is int) return value;
  if (value is double) return value.round();
  return 0;
}

double asDouble(Object? value, {double fallback = 0}) {
  if (value is double) return value;
  if (value is int) return value.toDouble();
  return fallback;
}

bool asBool(Object? value, {bool fallback = false}) {
  if (value is bool) return value;
  return fallback;
}

String? asOptionalString(Object? value) {
  if (value is String && value.isNotEmpty) return value;
  return null;
}

PermissionStatus permissionStatusFrom(Object? raw) {
  switch (raw) {
    case 'authorized':
      return PermissionStatus.authorized;
    case 'denied':
      return PermissionStatus.denied;
    case 'restricted':
      return PermissionStatus.restricted;
    case 'notDetermined':
      return PermissionStatus.notDetermined;
    default:
      return PermissionStatus.unknown;
  }
}

AuthorizationState authorizationFrom(Object? raw) {
  final map = asStringMap(raw);
  return AuthorizationState(
    video: permissionStatusFrom(map['video']),
    audio: permissionStatusFrom(map['audio']),
  );
}

CaptureDevice? deviceFrom(Object? raw) {
  final map = asStringMap(raw);
  final id = asOptionalString(map['id']);
  final name = asOptionalString(map['name']);
  if (id == null || name == null) return null;
  return CaptureDevice(
    id: id,
    name: name,
    connected: map.containsKey('connected') ? asBool(map['connected']) : true,
  );
}

List<CaptureDevice> devicesFrom(Object? raw) {
  if (raw is! List) return const [];
  final devices = <CaptureDevice>[];
  for (final item in raw) {
    final device = deviceFrom(item);
    if (device != null) devices.add(device);
  }
  return devices;
}

VideoFormatOption? formatFrom(Object? raw) {
  if (raw == null) return null;
  final map = asStringMap(raw);
  final id = asOptionalString(map['id']);
  if (id == null) return null;
  final width = asInt(map['width']);
  final height = asInt(map['height']);
  final fps = asInt(map['fps']);
  if (width <= 0 || height <= 0 || fps <= 0) return null;
  return VideoFormatOption(id: id, width: width, height: height, fps: fps);
}

List<VideoFormatOption> formatsFrom(Object? raw) {
  if (raw is! List) return const [];
  final formats = <VideoFormatOption>[];
  for (final item in raw) {
    final format = formatFrom(item);
    if (format != null) formats.add(format);
  }
  return formats;
}

PlaybackPreferences preferencesFrom(Object? raw) {
  final map = asStringMap(raw);
  if (map.isEmpty) return PlaybackPreferences.defaults;
  return PlaybackPreferences(
    videoDeviceId: asOptionalString(map['videoDeviceId']),
    audioDeviceId: asOptionalString(map['audioDeviceId']),
    formatId: asOptionalString(map['formatId']),
    volume: asDouble(map['volume'], fallback: 1).clamp(0, 1).toDouble(),
    muted: asBool(map['muted']),
    audioDisabled: asBool(map['audioDisabled']),
  );
}

SessionStatus sessionFrom(Object? raw) {
  final map = asStringMap(raw);
  return SessionStatus(
    running: asBool(map['running']),
    activeFormat: formatFrom(map['activeFormat']),
    errorCode: asOptionalString(map['errorCode']),
    errorDetail: asOptionalString(map['errorDetail']),
    warningCode: asOptionalString(map['warningCode']),
  );
}

CaptureSnapshot snapshotFrom(Object? raw) {
  final map = asStringMap(raw);
  return CaptureSnapshot(
    authorization: authorizationFrom(map['authorization']),
    videoDevices: devicesFrom(map['videoDevices']),
    audioDevices: devicesFrom(map['audioDevices']),
    preferences: preferencesFrom(map['preferences']),
    session: sessionFrom(map['session']),
    fullscreen: asBool(map['fullscreen']),
  );
}

CaptureEvent? eventFrom(Object? raw) {
  final map = asStringMap(raw);
  switch (map['type']) {
    case 'devices':
      return DevicesChanged(
        video: devicesFrom(map['video']),
        audio: devicesFrom(map['audio']),
      );
    case 'session':
      return SessionChanged(sessionFrom(map));
    case 'stats':
      final fps = asDouble(map['fps']);
      final latency = map['latencyMs'];
      return StatsChanged(
        CaptureStats(
          fps: fps,
          latencyMs: latency == null ? null : asDouble(latency),
        ),
      );
    case 'fullscreen':
      return FullScreenChanged(asBool(map['value']));
    case 'stream':
      return StreamStatusChanged(
        enabled: asBool(map['enabled']),
        clients: asInt(map['clients']),
        error: asOptionalString(map['error']),
        port: asInt(map['port']),
      );
    default:
      return null;
  }
}
