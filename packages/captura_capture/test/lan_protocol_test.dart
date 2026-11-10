import 'dart:typed_data';

import 'package:captura_capture/captura_capture.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('um quadro sobrevive a cortes no meio do TCP', () {
    final frame = LanVideoFrame(
      keyframe: true,
      sequence: 9,
      ptsUs: 1500,
      senderLatencyUs: 4200,
      captureHostUs: 9000,
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
    expect(decoded.sequence, 9);
    expect(decoded.ptsUs, 1500);
    expect(decoded.senderLatencyUs, 4200);
    expect(decoded.captureHostUs, 9000);
    expect(decoded.encoderInUs, 0);
    expect(decoded.sendUs, 0);
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
    expect(decoded.bitrateMbps, 0);
    expect(decoded.maxFrameQp, 0);
    expect(LanVideoFrame.decode(messages.last.payload).keyframe, isFalse);
  });

  test('configuração H.264 carrega taxa e teto de QP', () {
    final config = LanVideoConfig(
      width: 1280,
      height: 720,
      fpsMilli: 60000,
      sps: Uint8List.fromList([0x67]),
      pps: Uint8List.fromList([0x68]),
      bitrateMbps: 20,
      maxFrameQp: 32,
    );
    final decoded = LanVideoConfig.decode(config.encode());
    expect(decoded.bitrateMbps, 20);
    expect(decoded.maxFrameQp, 32);
    expect(decoded.sps, config.sps);
    expect(decoded.pps, config.pps);
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
    final pong = LanPong(
      clientTimeUs: ping.clientTimeUs,
      serverRecvUs: 5000,
      serverSendUs: 5000,
    );
    expect(LanPing.decode(ping.encode()).clientTimeUs, ping.clientTimeUs);
    expect(LanPong.decode(pong.encode()).serverRecvUs, 5000);

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
    expect(clampStreamBitrateMbps(30), 30);
    expect(clampStreamBitrateMbps(40), 30);
    expect(
      clockOffsetUs(
        clientSendUs: 1000,
        serverRecvUs: 5000,
        serverSendUs: 5000,
        clientRecvUs: 1000,
      ),
      4000,
    );
    expect(
      glassLatencyUs(
        captureSenderUs: 6000,
        displayReceiverUs: 2100,
        offsetUs: 4000,
      ),
      100,
    );
    final tuned = tuneForLatency(true);
    expect(tuned.height, 720);
    expect(tuned.bitrateMbps, 15);
    expect(tuneForLatency(false).height, 1080);
    expect(
      decideFrameSend(
        smooth: true,
        pendingSends: 2,
        keyframe: false,
        dropUntilKeyframe: false,
      ).send,
      isTrue,
    );
    final blocked = decideFrameSend(
      smooth: true,
      pendingSends: 3,
      keyframe: false,
      dropUntilKeyframe: false,
    );
    expect(blocked.send, isFalse);
    expect(blocked.requestKeyframe, isTrue);
    expect(
      decideFrameSend(
        smooth: false,
        pendingSends: 1,
        keyframe: false,
        dropUntilKeyframe: false,
      ).send,
      isFalse,
    );
    expect(
      decideFrameSend(
        smooth: true,
        pendingSends: 0,
        keyframe: true,
        dropUntilKeyframe: true,
      ).send,
      isTrue,
    );
    expect(normalizeStreamHeight(480), 720);
    expect(normalizeStreamHeight(1080), 1080);
  });

  test('carimbos do quadro, UDP e o relógio', () {
    final frame = LanVideoFrame(
      keyframe: false,
      sequence: 4,
      ptsUs: 30,
      senderLatencyUs: 8,
      captureHostUs: 1000,
      encoderInUs: 1100,
      encoderOutUs: 4500,
      sendUs: 4600,
      nalus: Uint8List.fromList([9, 9]),
    );
    final decoded = LanVideoFrame.decode(frame.encode());
    expect(decoded.encoderInUs, 1100);
    expect(decoded.encoderOutUs, 4500);
    expect(decoded.sendUs, 4600);
    expect(decoded.nalus, frame.nalus);
    expect(decoded.encode().length, LanVideoFrame.prefixSize + 2);

    final stages = stageDurations(
      captureUs: 1000,
      encoderInUs: 1100,
      encoderOutUs: 4500,
      sendUs: 4600,
      recvUs: 2000,
      decodeSubmitUs: 2100,
      decodedUs: 2800,
      glassUs: 3000,
      offsetUs: 3000,
    );
    expect(stages.captureToEncoderUs, 100);
    expect(stages.encodeUs, 3400);
    expect(stages.sendQueueUs, 100);
    expect(stages.networkUs, 400);
    expect(stages.decodeUs, 700);
    expect(stages.toGlassUs, 200);
    expect(stages.totalUs, 5000);

    expect(
      roundTripUs(
        clientSendUs: 1000,
        serverRecvUs: 5000,
        serverSendUs: 5200,
        clientRecvUs: 2500,
      ),
      1300,
    );
    expect(clockOffsetLooksSkewed(offsetUs: 100000, rttUs: 2000), isTrue);
    expect(clockOffsetLooksSkewed(offsetUs: 400, rttUs: 2000), isFalse);

    final timing = UdpTiming(
      captureUs: 10,
      encoderInUs: 20,
      encoderOutUs: 30,
      sendUs: 40,
    );
    final nalus = Uint8List.fromList(
      List<int>.generate(2000, (index) => index & 0xff),
    );
    final packets = packetizeUdpFrame(
      UdpFrame(frameId: 7, keyframe: true, timing: timing, nalus: nalus),
    );
    expect(packets.length, greaterThan(1));
    for (final packet in packets) {
      expect(packet.length, lessThanOrEqualTo(UdpDatagram.datagramSize));
    }
    final reassembler = UdpReassembler();
    UdpFrame? assembled;
    var dropped = false;
    for (final packet in packets) {
      final ingest = reassembler.add(packet);
      dropped = dropped || ingest.droppedIncomplete;
      assembled ??= ingest.frame;
    }
    expect(dropped, isFalse);
    expect(assembled?.keyframe, isTrue);
    expect(assembled?.frameId, 7);
    expect(assembled?.timing.sendUs, 40);
    expect(assembled?.nalus, nalus);

    final lossy = UdpReassembler();
    final first = lossy.add(packets.first);
    expect(first.frame, isNull);
    final other = packetizeUdpFrame(
      UdpFrame(
        frameId: 8,
        keyframe: false,
        timing: timing,
        nalus: Uint8List.fromList([1, 2, 3, 4]),
      ),
    );
    final next = lossy.add(other.single);
    expect(next.droppedIncomplete, isTrue);
    expect(next.frame?.nalus, [1, 2, 3, 4]);
    expect(UdpDatagram.decode(udpBindDatagram()).isBind, isTrue);
    expect(LanType.keyframeRequest, 0x12);
    expect(LanType.transport, 0x14);

    final keepalive = UdpDatagram(
      flags: UdpDatagram.keepaliveFlag,
      frameId: 0,
      fragIndex: 0,
      fragCount: 0,
      payload: Uint8List(0),
    );
    expect(UdpReassembler().add(keepalive.encode()).ignored, isTrue);
    expect(udpPartialExpired(ageUs: 7999), isFalse);
    expect(udpPartialExpired(ageUs: 8000), isTrue);
    expect(percentileNearest(const [10, 20, 30, 40, 100], 0.50), 30);
    expect(percentileNearest(const [10, 20, 30, 40, 100], 0.95), 100);
    expect(
      dominantStage(
        captureUs: 1,
        encodeUs: 2,
        queueUs: 0,
        networkUs: 90,
        decodeUs: 3,
        glassUs: 4,
      ),
      'rede',
    );
    final window = LatencyWindow()
      ..add(nowUs: 0, totalUs: 20000, stage: 'enc')
      ..add(nowUs: 16000, totalUs: 90000, stage: 'rede')
      ..add(nowUs: 32000, totalUs: 30000, stage: 'enc');
    final summary = window.summarize();
    expect(summary.p50Us, 30000);
    expect(summary.maxUs, 90000);
    expect(summary.spikeCount, 1);
    expect(summary.spikeStage, 'rede');
  });
}
