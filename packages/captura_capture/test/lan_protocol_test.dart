import 'dart:typed_data';

import 'package:captura_capture/captura_capture.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('um quadro sobrevive a cortes no meio do TCP', () {
    final frame = LanVideoFrame(
      keyframe: true,
      ptsUs: 1500,
      senderLatencyUs: 4200,
      nalus: Uint8List.fromList([0, 0, 0, 4, 9, 8, 7, 6]),
    );
    final bytes = LanFramer.encode(
      LanMessage(type: LanType.videoFrame, payload: frame.encode()),
    );
    final parser = LanParser();
    expect(parser.add(bytes.sublist(0, 5)), isEmpty);
    expect(parser.add(bytes.sublist(5, 20)), isEmpty);
    final messages = parser.add(bytes.sublist(20));
    expect(messages, hasLength(1));
    final decoded = LanVideoFrame.decode(messages.single.payload);
    expect(decoded.keyframe, isTrue);
    expect(decoded.ptsUs, 1500);
    expect(decoded.senderLatencyUs, 4200);
    expect(decoded.nalus, frame.nalus);
  });

  test('configuração H.264 e dois quadros na mesma leitura', () {
    final config = LanVideoConfig(
      width: 1920,
      height: 1080,
      fpsMilli: 59940,
      sps: Uint8List.fromList([0x67, 0x42, 0x00]),
      pps: Uint8List.fromList([0x68, 0xCE]),
    );
    final delta = LanVideoFrame(
      keyframe: false,
      ptsUs: 99,
      senderLatencyUs: 1,
      nalus: Uint8List.fromList([1, 2, 3]),
    );
    final packed = Uint8List.fromList([
      ...LanFramer.encode(
        LanMessage(type: LanType.videoConfig, payload: config.encode()),
      ),
      ...LanFramer.encode(
        LanMessage(type: LanType.videoFrame, payload: delta.encode()),
      ),
    ]);
    final messages = LanParser().add(packed);
    expect(messages.map((message) => message.type), [
      LanType.videoConfig,
      LanType.videoFrame,
    ]);
    final decoded = LanVideoConfig.decode(messages.first.payload);
    expect(decoded.width, 1920);
    expect(decoded.height, 1080);
    expect(decoded.fpsMilli, 59940);
    expect(decoded.sps, config.sps);
    expect(decoded.pps, config.pps);
    expect(LanVideoFrame.decode(messages.last.payload).keyframe, isFalse);
  });

  test('magic, versão e tamanho inválidos derrubam o parser', () {
    expect(
      () => LanParser().add([0, 1, 2, 3, 1, 0, 0, 0, 0, 0, 0, 0]),
      throwsA(isA<LanDecodeException>()),
    );
    final badVersion = Uint8List.fromList(LanLimits.magic);
    final padded = Uint8List(12);
    padded.setRange(0, 4, badVersion);
    padded[4] = 9;
    expect(() => LanParser().add(padded), throwsA(isA<LanDecodeException>()));
    expect(
      () => LanFramer.encode(
        LanMessage(
          type: LanType.videoFrame,
          payload: Uint8List(LanLimits.maxPayload + 1),
        ),
      ),
      throwsA(isA<LanDecodeException>()),
    );
  });

  test('hello, ping e o relatório de controle reservado', () {
    final hello = LanHello(features: LanFeatures.video | LanFeatures.input);
    expect(LanHello.decode(hello.encode()).features, hello.features);

    final ping = LanPing(123456789);
    final pong = LanPong(clientTimeUs: ping.clientTimeUs, serverTimeUs: 50);
    expect(LanPing.decode(ping.encode()).clientTimeUs, ping.clientTimeUs);
    expect(LanPong.decode(pong.encode()).serverTimeUs, 50);

    const input = LanInputReport(
      sequence: 7,
      buttons: 0x11,
      lx: -1000,
      ly: 2000,
      rx: 3,
      ry: -4,
      l2: 10,
      r2: 255,
    );
    final decoded = LanInputReport.decode(input.encode());
    expect(decoded.sequence, 7);
    expect(decoded.buttons, 0x11);
    expect(decoded.lx, -1000);
    expect(decoded.ly, 2000);
    expect(decoded.l2, 10);
    expect(decoded.r2, 255);
    expect(LanType.input, 0x30);
  });

  test('endereço manual, bitrate e altura', () {
    expect(parseManualEndpoint('192.168.1.20')?.port, LanLimits.port);
    expect(parseManualEndpoint('192.168.1.20:5000')?.port, 5000);
    expect(parseManualEndpoint('fe80::1')?.host, 'fe80::1');
    expect(parseManualEndpoint('[fe80::1]:9')?.port, 9);
    expect(parseManualEndpoint('  '), isNull);
    expect(clampStreamBitrateMbps(4), 10);
    expect(clampStreamBitrateMbps(30), 20);
    expect(normalizeStreamHeight(480), 720);
    expect(normalizeStreamHeight(1080), 1080);
  });
}
