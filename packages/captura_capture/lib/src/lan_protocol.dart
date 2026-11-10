import 'dart:typed_data';

/// Byte layout shared by the Mac sender and the iPhone receiver.
///
/// The hot path is implemented again in Swift (`LanWire.swift`) because
/// frames must not cross a method channel. These types are the spec: the
/// Dart tests lock the bytes, and the Swift code has to match them.
///
/// ```
/// offset  size  field
/// 0       4     magic "CPL1"
/// 4       1     version (1)
/// 5       1     type
/// 6       2     flags (big-endian)
/// 8       4     payload length (big-endian)
/// 12      n     payload
/// ```
///
/// [LanType.input] is reserved for a later controller. Nothing sends it yet.
abstract final class LanType {
  static const hello = 1;
  static const helloAck = 2;
  static const videoConfig = 0x10;
  static const videoFrame = 0x11;
  static const keyframeRequest = 0x12;
  static const transport = 0x14;
  static const audioConfig = 0x20;
  static const audioFrame = 0x21;
  static const input = 0x30;
  static const ping = 0x40;
  static const pong = 0x41;
  static const bye = 0x7F;
}

abstract final class LanLimits {
  static const version = 1;
  static const headerSize = 12;
  static const maxPayload = 4000000;
  static const port = 47731;
  static const serviceType = '_capturaplay._tcp';
  static const magic = [0x43, 0x50, 0x4C, 0x31];
}

abstract final class LanFeatures {
  static const video = 1;
  static const audio = 2;
  static const input = 4;
  static const udp = 8;
}

class LanDecodeException implements Exception {
  const LanDecodeException(this.reason);

  final String reason;

  @override
  String toString() => 'LanDecodeException($reason)';
}

class LanMessage {
  const LanMessage({required this.type, this.flags = 0, required this.payload});

  final int type;
  final int flags;
  final Uint8List payload;
}

class LanFramer {
  static Uint8List encode(LanMessage message) {
    if (message.payload.length > LanLimits.maxPayload) {
      throw const LanDecodeException('length');
    }
    final out = Uint8List(LanLimits.headerSize + message.payload.length);
    final data = ByteData.sublistView(out);
    out[0] = LanLimits.magic[0];
    out[1] = LanLimits.magic[1];
    out[2] = LanLimits.magic[2];
    out[3] = LanLimits.magic[3];
    data.setUint8(4, LanLimits.version);
    data.setUint8(5, message.type);
    data.setUint16(6, message.flags, Endian.big);
    data.setUint32(8, message.payload.length, Endian.big);
    out.setRange(LanLimits.headerSize, out.length, message.payload);
    return out;
  }
}

/// Incremental TCP deframer. Incomplete headers stay buffered.
class LanParser {
  final List<int> _pending = [];

  List<LanMessage> add(List<int> chunk) {
    _pending.addAll(chunk);
    final messages = <LanMessage>[];
    while (_pending.length >= LanLimits.headerSize) {
      for (var i = 0; i < 4; i++) {
        if (_pending[i] != LanLimits.magic[i]) {
          throw const LanDecodeException('magic');
        }
      }
      final header = Uint8List.fromList(
        _pending.sublist(0, LanLimits.headerSize),
      );
      final view = ByteData.sublistView(header);
      final version = view.getUint8(4);
      if (version != LanLimits.version) {
        throw const LanDecodeException('version');
      }
      final type = view.getUint8(5);
      final flags = view.getUint16(6, Endian.big);
      final length = view.getUint32(8, Endian.big);
      if (length > LanLimits.maxPayload) {
        throw const LanDecodeException('length');
      }
      final total = LanLimits.headerSize + length;
      if (_pending.length < total) break;
      final payload = Uint8List.fromList(
        _pending.sublist(LanLimits.headerSize, total),
      );
      _pending.removeRange(0, total);
      messages.add(LanMessage(type: type, flags: flags, payload: payload));
    }
    return messages;
  }

  void reset() => _pending.clear();
}

class LanHello {
  const LanHello({required this.features});

  final int features;

  Uint8List encode() {
    final out = Uint8List(3);
    final view = ByteData.sublistView(out);
    view.setUint8(0, LanLimits.version);
    view.setUint16(1, features, Endian.big);
    return out;
  }

  static LanHello decode(Uint8List payload) {
    if (payload.length < 3) throw const LanDecodeException('hello');
    final view = ByteData.sublistView(payload);
    if (view.getUint8(0) != LanLimits.version) {
      throw const LanDecodeException('hello-version');
    }
    return LanHello(features: view.getUint16(1, Endian.big));
  }
}

class LanVideoConfig {
  const LanVideoConfig({
    required this.width,
    required this.height,
    required this.fpsMilli,
    required this.sps,
    required this.pps,
    this.bitrateMbps = 0,
    this.maxFrameQp = 0,
  });

  static const codecH264 = 1;
  static const nalLengthSize = 4;

  final int width;
  final int height;
  final int fpsMilli;
  final Uint8List sps;
  final Uint8List pps;
  final int bitrateMbps;
  final int maxFrameQp;

  Uint8List encode() {
    final extra = bitrateMbps > 0 ? 8 : 0;
    final out = Uint8List(14 + sps.length + pps.length + extra);
    final view = ByteData.sublistView(out);
    view.setUint8(0, codecH264);
    view.setUint8(1, nalLengthSize);
    view.setUint16(2, width, Endian.big);
    view.setUint16(4, height, Endian.big);
    view.setUint32(6, fpsMilli, Endian.big);
    view.setUint16(10, sps.length, Endian.big);
    out.setRange(12, 12 + sps.length, sps);
    final ppsAt = 12 + sps.length;
    ByteData.sublistView(out).setUint16(ppsAt, pps.length, Endian.big);
    out.setRange(ppsAt + 2, ppsAt + 2 + pps.length, pps);
    if (bitrateMbps > 0) {
      final tail = ppsAt + 2 + pps.length;
      ByteData.sublistView(out).setUint32(tail, bitrateMbps, Endian.big);
      ByteData.sublistView(out).setUint32(tail + 4, maxFrameQp, Endian.big);
    }
    return out;
  }

  static LanVideoConfig decode(Uint8List payload) {
    if (payload.length < 14) throw const LanDecodeException('config');
    final view = ByteData.sublistView(payload);
    if (view.getUint8(0) != codecH264) throw const LanDecodeException('codec');
    if (view.getUint8(1) != nalLengthSize) {
      throw const LanDecodeException('nal-length');
    }
    final width = view.getUint16(2, Endian.big);
    final height = view.getUint16(4, Endian.big);
    final fpsMilli = view.getUint32(6, Endian.big);
    final spsLength = view.getUint16(10, Endian.big);
    final spsEnd = 12 + spsLength;
    if (payload.length < spsEnd + 2) throw const LanDecodeException('sps');
    final sps = Uint8List.sublistView(payload, 12, spsEnd);
    final ppsLength = ByteData.sublistView(
      payload,
    ).getUint16(spsEnd, Endian.big);
    final ppsEnd = spsEnd + 2 + ppsLength;
    if (payload.length < ppsEnd) throw const LanDecodeException('pps');
    final pps = Uint8List.sublistView(payload, spsEnd + 2, ppsEnd);
    final viewTail = ByteData.sublistView(payload);
    return LanVideoConfig(
      width: width,
      height: height,
      fpsMilli: fpsMilli,
      sps: sps,
      pps: pps,
      bitrateMbps: payload.length >= ppsEnd + 4
          ? viewTail.getUint32(ppsEnd, Endian.big)
          : 0,
      maxFrameQp: payload.length >= ppsEnd + 8
          ? viewTail.getUint32(ppsEnd + 4, Endian.big)
          : 0,
    );
  }
}

class LanVideoFrame {
  const LanVideoFrame({
    required this.keyframe,
    required this.ptsUs,
    required this.senderLatencyUs,
    required this.nalus,
    this.sequence = 0,
    this.captureHostUs = 0,
    this.encoderInUs = 0,
    this.encoderOutUs = 0,
    this.sendUs = 0,
  });

  static const prefixSize = 48;
  static const keyframeFlag = 1;

  final bool keyframe;
  final int ptsUs;
  final int senderLatencyUs;
  final int sequence;
  final int captureHostUs;
  final int encoderInUs;
  final int encoderOutUs;
  final int sendUs;
  final Uint8List nalus;

  Uint8List encode() {
    final out = Uint8List(prefixSize + nalus.length);
    final view = ByteData.sublistView(out);
    view.setUint16(0, keyframe ? keyframeFlag : 0, Endian.big);
    view.setUint16(2, sequence & 0xffff, Endian.big);
    view.setUint64(4, ptsUs, Endian.big);
    view.setUint32(12, senderLatencyUs, Endian.big);
    view.setUint64(16, captureHostUs, Endian.big);
    view.setUint64(24, encoderInUs, Endian.big);
    view.setUint64(32, encoderOutUs, Endian.big);
    view.setUint64(40, sendUs, Endian.big);
    out.setRange(prefixSize, out.length, nalus);
    return out;
  }

  static LanVideoFrame decode(Uint8List payload) {
    if (payload.length < prefixSize) throw const LanDecodeException('frame');
    final view = ByteData.sublistView(payload);
    final flags = view.getUint16(0, Endian.big);
    return LanVideoFrame(
      keyframe: flags & keyframeFlag != 0,
      sequence: view.getUint16(2, Endian.big),
      ptsUs: view.getUint64(4, Endian.big),
      senderLatencyUs: view.getUint32(12, Endian.big),
      captureHostUs: view.getUint64(16, Endian.big),
      encoderInUs: view.getUint64(24, Endian.big),
      encoderOutUs: view.getUint64(32, Endian.big),
      sendUs: view.getUint64(40, Endian.big),
      nalus: Uint8List.sublistView(payload, prefixSize),
    );
  }
}

/// One UDP datagram. Fragment 0 carries [UdpTiming] ahead of the NAL bytes.
class UdpDatagram {
  const UdpDatagram({
    required this.flags,
    required this.frameId,
    required this.fragIndex,
    required this.fragCount,
    required this.payload,
  });

  static const headerSize = 12;
  static const timingSize = 32;
  static const datagramSize = 1200;
  static const keyframeFlag = 0x01;
  static const timingFlag = 0x02;
  static const keepaliveFlag = 0x40;
  static const bindFlag = 0x80;
  static const magic = [0x43, 0x50, 0x4C, 0x55];

  final int flags;
  final int frameId;
  final int fragIndex;
  final int fragCount;
  final Uint8List payload;

  bool get isBind => flags & bindFlag != 0;
  bool get isKeepalive => flags & keepaliveFlag != 0;
  bool get keyframe => flags & keyframeFlag != 0;
  bool get hasTiming => flags & timingFlag != 0;

  Uint8List encode() {
    final out = Uint8List(headerSize + payload.length);
    final view = ByteData.sublistView(out);
    out[0] = magic[0];
    out[1] = magic[1];
    out[2] = magic[2];
    out[3] = magic[3];
    view.setUint8(4, LanLimits.version);
    view.setUint8(5, flags);
    view.setUint16(6, frameId & 0xffff, Endian.big);
    view.setUint16(8, fragIndex & 0xffff, Endian.big);
    view.setUint16(10, fragCount & 0xffff, Endian.big);
    out.setRange(headerSize, out.length, payload);
    return out;
  }

  static UdpDatagram decode(Uint8List datagram) {
    if (datagram.length < headerSize) throw const LanDecodeException('udp');
    for (var i = 0; i < 4; i++) {
      if (datagram[i] != magic[i]) throw const LanDecodeException('udp-magic');
    }
    final view = ByteData.sublistView(datagram);
    if (view.getUint8(4) != LanLimits.version) {
      throw const LanDecodeException('udp-version');
    }
    return UdpDatagram(
      flags: view.getUint8(5),
      frameId: view.getUint16(6, Endian.big),
      fragIndex: view.getUint16(8, Endian.big),
      fragCount: view.getUint16(10, Endian.big),
      payload: Uint8List.sublistView(datagram, headerSize),
    );
  }
}

class UdpTiming {
  const UdpTiming({
    required this.captureUs,
    required this.encoderInUs,
    required this.encoderOutUs,
    required this.sendUs,
  });

  final int captureUs;
  final int encoderInUs;
  final int encoderOutUs;
  final int sendUs;

  Uint8List encode() {
    final out = Uint8List(UdpDatagram.timingSize);
    final view = ByteData.sublistView(out);
    view.setUint64(0, captureUs, Endian.big);
    view.setUint64(8, encoderInUs, Endian.big);
    view.setUint64(16, encoderOutUs, Endian.big);
    view.setUint64(24, sendUs, Endian.big);
    return out;
  }

  static UdpTiming decode(Uint8List bytes) {
    if (bytes.length < UdpDatagram.timingSize) {
      throw const LanDecodeException('udp-timing');
    }
    final view = ByteData.sublistView(bytes);
    return UdpTiming(
      captureUs: view.getUint64(0, Endian.big),
      encoderInUs: view.getUint64(8, Endian.big),
      encoderOutUs: view.getUint64(16, Endian.big),
      sendUs: view.getUint64(24, Endian.big),
    );
  }
}

class UdpFrame {
  const UdpFrame({
    required this.frameId,
    required this.keyframe,
    required this.timing,
    required this.nalus,
  });

  final int frameId;
  final bool keyframe;
  final UdpTiming timing;
  final Uint8List nalus;
}

Uint8List udpBindDatagram() {
  return UdpDatagram(
    flags: UdpDatagram.bindFlag,
    frameId: 0,
    fragIndex: 0,
    fragCount: 0,
    payload: Uint8List(0),
  ).encode();
}

/// Splits one access unit into MTU-sized datagrams. Fragment 0 starts with
/// the timing block so a lost tail cannot be displayed with a stale clock.
List<Uint8List> packetizeUdpFrame(UdpFrame frame) {
  if (frame.nalus.isEmpty) return const [];
  final firstBudget =
      UdpDatagram.datagramSize -
      UdpDatagram.headerSize -
      UdpDatagram.timingSize;
  final nextBudget = UdpDatagram.datagramSize - UdpDatagram.headerSize;
  final rest = frame.nalus.length > firstBudget
      ? frame.nalus.length - firstBudget
      : 0;
  final extra = rest == 0 ? 0 : (rest + nextBudget - 1) ~/ nextBudget;
  final count = 1 + extra;
  final packets = <Uint8List>[];
  var offset = 0;
  for (var index = 0; index < count; index++) {
    final budget = index == 0 ? firstBudget : nextBudget;
    final take = frame.nalus.length - offset;
    final size = take < budget ? take : budget;
    final piece = Uint8List.sublistView(frame.nalus, offset, offset + size);
    final payload = index == 0
        ? Uint8List.fromList([...frame.timing.encode(), ...piece])
        : Uint8List.fromList(piece);
    final flags =
        (frame.keyframe ? UdpDatagram.keyframeFlag : 0) |
        (index == 0 ? UdpDatagram.timingFlag : 0);
    packets.add(
      UdpDatagram(
        flags: flags,
        frameId: frame.frameId,
        fragIndex: index,
        fragCount: count,
        payload: payload,
      ).encode(),
    );
    offset += size;
  }
  return packets;
}

class UdpIngest {
  const UdpIngest({
    this.frame,
    this.droppedIncomplete = false,
    this.ignored = false,
  });

  final UdpFrame? frame;
  final bool droppedIncomplete;
  final bool ignored;
}

/// Keeps a single frame in flight. A newer frame id discards the partial one.
class UdpReassembler {
  int? _frameId;
  int _count = 0;
  List<Uint8List?> _parts = [];
  bool _keyframe = false;
  UdpTiming? _timing;
  int _got = 0;

  UdpIngest add(Uint8List datagram) {
    final packet = UdpDatagram.decode(datagram);
    if (packet.isBind || packet.isKeepalive || packet.fragCount == 0) {
      return const UdpIngest(ignored: true);
    }
    if (packet.fragIndex >= packet.fragCount) {
      throw const LanDecodeException('udp-frag');
    }
    if (_frameId != null && packet.frameId != _frameId) {
      final ahead = (packet.frameId - _frameId!) & 0xffff;
      if (ahead == 0 || ahead >= 0x8000) {
        return const UdpIngest(ignored: true);
      }
      final dropped = _got != _count;
      _reset();
      _start(packet);
      final done = _store(packet);
      return UdpIngest(frame: done, droppedIncomplete: dropped);
    }
    if (_frameId == null) _start(packet);
    if (packet.fragCount != _count) throw const LanDecodeException('udp-count');
    final done = _store(packet);
    return UdpIngest(frame: done);
  }

  void _start(UdpDatagram packet) {
    _frameId = packet.frameId;
    _count = packet.fragCount;
    _parts = List<Uint8List?>.filled(packet.fragCount, null);
    _keyframe = packet.keyframe;
    _got = 0;
    _timing = null;
  }

  UdpFrame? _store(UdpDatagram packet) {
    if (_parts[packet.fragIndex] != null) return null;
    if (packet.fragIndex == 0) {
      if (!packet.hasTiming || packet.payload.length < UdpDatagram.timingSize) {
        throw const LanDecodeException('udp-timing');
      }
      _timing = UdpTiming.decode(packet.payload);
      _parts[0] = Uint8List.sublistView(packet.payload, UdpDatagram.timingSize);
      _keyframe = packet.keyframe;
    } else {
      _parts[packet.fragIndex] = packet.payload;
    }
    _got += 1;
    if (_got != _count || _timing == null) return null;
    final nalus = Uint8List.fromList(_parts.expand((part) => part!).toList());
    final frame = UdpFrame(
      frameId: _frameId!,
      keyframe: _keyframe,
      timing: _timing!,
      nalus: nalus,
    );
    _reset();
    return frame;
  }

  void _reset() {
    _frameId = null;
    _count = 0;
    _parts = [];
    _got = 0;
    _timing = null;
  }
}

/// Reserved. The phone will send this later; neither side transmits it now.
class LanInputReport {
  const LanInputReport({
    required this.sequence,
    required this.buttons,
    this.lx = 0,
    this.ly = 0,
    this.rx = 0,
    this.ry = 0,
    this.l2 = 0,
    this.r2 = 0,
  });

  final int sequence;
  final int buttons;
  final int lx;
  final int ly;
  final int rx;
  final int ry;
  final int l2;
  final int r2;

  Uint8List encode() {
    final out = Uint8List(18);
    final view = ByteData.sublistView(out);
    view.setUint32(0, sequence, Endian.big);
    view.setUint32(4, buttons, Endian.big);
    view.setInt16(8, lx, Endian.big);
    view.setInt16(10, ly, Endian.big);
    view.setInt16(12, rx, Endian.big);
    view.setInt16(14, ry, Endian.big);
    view.setUint8(16, l2);
    view.setUint8(17, r2);
    return out;
  }

  static LanInputReport decode(Uint8List payload) {
    if (payload.length < 18) throw const LanDecodeException('input');
    final view = ByteData.sublistView(payload);
    return LanInputReport(
      sequence: view.getUint32(0, Endian.big),
      buttons: view.getUint32(4, Endian.big),
      lx: view.getInt16(8, Endian.big),
      ly: view.getInt16(10, Endian.big),
      rx: view.getInt16(12, Endian.big),
      ry: view.getInt16(14, Endian.big),
      l2: view.getUint8(16),
      r2: view.getUint8(17),
    );
  }
}

class LanPing {
  const LanPing(this.clientTimeUs);

  final int clientTimeUs;

  Uint8List encode() {
    final out = Uint8List(8);
    ByteData.sublistView(out).setUint64(0, clientTimeUs, Endian.big);
    return out;
  }

  static LanPing decode(Uint8List payload) {
    if (payload.length < 8) throw const LanDecodeException('ping');
    return LanPing(ByteData.sublistView(payload).getUint64(0, Endian.big));
  }
}

class LanPong {
  const LanPong({
    required this.clientTimeUs,
    required this.serverRecvUs,
    required this.serverSendUs,
  });

  final int clientTimeUs;
  final int serverRecvUs;
  final int serverSendUs;

  Uint8List encode() {
    final out = Uint8List(24);
    final view = ByteData.sublistView(out);
    view.setUint64(0, clientTimeUs, Endian.big);
    view.setUint64(8, serverRecvUs, Endian.big);
    view.setUint64(16, serverSendUs, Endian.big);
    return out;
  }

  static LanPong decode(Uint8List payload) {
    if (payload.length < 24) throw const LanDecodeException('pong');
    final view = ByteData.sublistView(payload);
    return LanPong(
      clientTimeUs: view.getUint64(0, Endian.big),
      serverRecvUs: view.getUint64(8, Endian.big),
      serverSendUs: view.getUint64(16, Endian.big),
    );
  }
}

/// How much to add to the receiver clock to estimate the sender clock.
///
/// T1 client send, T2 server receive, T3 server send, T4 client receive.
int clockOffsetUs({
  required int clientSendUs,
  required int serverRecvUs,
  required int serverSendUs,
  required int clientRecvUs,
}) {
  return ((serverRecvUs - clientSendUs) + (serverSendUs - clientRecvUs)) ~/ 2;
}

/// Capture stamp on the sender clock to display stamp on the receiver clock.
int glassLatencyUs({
  required int captureSenderUs,
  required int displayReceiverUs,
  required int offsetUs,
}) {
  return displayReceiverUs + offsetUs - captureSenderUs;
}

/// Client-observed round trip, with the server's processing time removed.
int roundTripUs({
  required int clientSendUs,
  required int serverRecvUs,
  required int serverSendUs,
  required int clientRecvUs,
}) {
  return (clientRecvUs - clientSendUs) - (serverSendUs - serverRecvUs);
}

/// The offset is doing real work when the two clocks disagree by more than
/// the trip. A 100 ms "latency" with a 2 ms RTT is the clock, not the link.
bool clockOffsetLooksSkewed({required int offsetUs, required int rttUs}) {
  final trip = rttUs < 0 ? -rttUs : rttUs;
  final skew = offsetUs < 0 ? -offsetUs : offsetUs;
  final allowance = trip > 5000 ? trip : 5000;
  return skew > allowance + 2000;
}

class StreamStages {
  const StreamStages({
    required this.captureToEncoderUs,
    required this.encodeUs,
    required this.sendQueueUs,
    required this.networkUs,
    required this.decodeUs,
    required this.toGlassUs,
    required this.totalUs,
  });

  final int captureToEncoderUs;
  final int encodeUs;
  final int sendQueueUs;
  final int networkUs;
  final int decodeUs;
  final int toGlassUs;
  final int totalUs;
}

/// Sender stamps share the Mac clock. Receiver stamps share the phone clock.
/// [offsetUs] converts a phone stamp into the Mac clock.
StreamStages stageDurations({
  required int captureUs,
  required int encoderInUs,
  required int encoderOutUs,
  required int sendUs,
  required int recvUs,
  required int decodeSubmitUs,
  required int decodedUs,
  required int glassUs,
  required int offsetUs,
}) {
  return StreamStages(
    captureToEncoderUs: encoderInUs - captureUs,
    encodeUs: encoderOutUs - encoderInUs,
    sendQueueUs: sendUs - encoderOutUs,
    networkUs: (recvUs + offsetUs) - sendUs,
    decodeUs: decodedUs - decodeSubmitUs,
    toGlassUs: glassUs - decodedUs,
    totalUs: (glassUs + offsetUs) - captureUs,
  );
}

int clampStreamBitrateMbps(int value) => value.clamp(10, 30);

/// How many encoded frames may be waiting on the socket.
///
/// One in flight looks like "lowest latency" but on Wi-Fi the previous send
/// is still completing when the next 16 ms frame arrives, so that rule drops
/// constantly and then freezes until a keyframe. Smooth keeps a short window.
int maxVideoSendsInFlight({required bool smooth}) => smooth ? 3 : 1;

int maxEncodeInFlight({required bool smooth}) => smooth ? 2 : 1;

class FrameSendDecision {
  const FrameSendDecision({
    required this.send,
    required this.requestKeyframe,
    required this.holdForKeyframe,
  });

  final bool send;
  final bool requestKeyframe;
  final bool holdForKeyframe;
}

FrameSendDecision decideFrameSend({
  required bool smooth,
  required int pendingSends,
  required bool keyframe,
  required bool dropUntilKeyframe,
}) {
  if (pendingSends >= maxVideoSendsInFlight(smooth: smooth)) {
    return const FrameSendDecision(
      send: false,
      requestKeyframe: true,
      holdForKeyframe: true,
    );
  }
  if (dropUntilKeyframe && !keyframe) {
    return const FrameSendDecision(
      send: false,
      requestKeyframe: false,
      holdForKeyframe: true,
    );
  }
  return const FrameSendDecision(
    send: true,
    requestKeyframe: false,
    holdForKeyframe: false,
  );
}

class StreamTune {
  const StreamTune({
    required this.lowLatency,
    required this.height,
    required this.bitrateMbps,
  });

  final bool lowLatency;
  final int height;
  final int bitrateMbps;
}

StreamTune tuneForLatency(bool lowLatency) {
  if (lowLatency) {
    return const StreamTune(lowLatency: true, height: 720, bitrateMbps: 15);
  }
  return const StreamTune(lowLatency: false, height: 1080, bitrateMbps: 20);
}

int normalizeStreamHeight(int height) => height <= 720 ? 720 : 1080;

/// A partial UDP frame older than this is discarded. Same value as
/// `UdpReassembler.partialTimeout` in LanWire.swift.
const udpPartialTimeoutUs = 8000;

bool udpPartialExpired({required int ageUs}) => ageUs >= udpPartialTimeoutUs;

/// Nearest rank. `LanWire`'s StageWindow uses the same rounding.
int percentileNearest(List<int> values, double p) {
  if (values.isEmpty) return -1;
  final sorted = [...values]..sort();
  final rank = ((sorted.length - 1) * p).round();
  final index = rank < 0
      ? 0
      : (rank >= sorted.length ? sorted.length - 1 : rank);
  return sorted[index];
}

/// The stage that contributed the most of a late frame.
String dominantStage({
  required int captureUs,
  required int encodeUs,
  required int queueUs,
  required int networkUs,
  required int decodeUs,
  required int glassUs,
}) {
  final stages = <String, int>{
    'cap': captureUs,
    'enc': encodeUs,
    'tx': queueUs,
    'rede': networkUs,
    'dec': decodeUs,
    'vidro': glassUs,
  };
  var name = 'rede';
  var best = -1 << 60;
  for (final entry in stages.entries) {
    if (entry.value > best) {
      best = entry.value;
      name = entry.key;
    }
  }
  return name;
}

class LatencySummary {
  const LatencySummary({
    required this.p50Us,
    required this.p95Us,
    required this.maxUs,
    required this.spikeCount,
    required this.spikeStage,
  });

  final int p50Us;
  final int p95Us;
  final int maxUs;
  final int spikeCount;
  final String spikeStage;
}

/// Keeps about two seconds of capture→glass samples.
class LatencyWindow {
  static const horizonUs = 2000000;
  static const spikeUs = 50000;

  final List<(int, int, String)> _samples = [];

  void add({required int nowUs, required int totalUs, required String stage}) {
    _samples.add((nowUs, totalUs, stage));
    _samples.removeWhere((sample) => nowUs - sample.$1 > horizonUs);
  }

  LatencySummary summarize() {
    final totals = [for (final sample in _samples) sample.$2];
    final spikes = [
      for (final sample in _samples)
        if (sample.$2 > spikeUs) sample.$3,
    ];
    var stage = '';
    if (spikes.isNotEmpty) {
      final counts = <String, int>{};
      for (final name in spikes) {
        counts[name] = (counts[name] ?? 0) + 1;
      }
      stage = counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
    }
    return LatencySummary(
      p50Us: percentileNearest(totals, 0.50),
      p95Us: percentileNearest(totals, 0.95),
      maxUs: percentileNearest(totals, 1),
      spikeCount: spikes.length,
      spikeStage: stage,
    );
  }
}

class ManualEndpoint {
  const ManualEndpoint(this.host, this.port);

  final String host;
  final int port;
}

ManualEndpoint? parseManualEndpoint(
  String raw, {
  int defaultPort = LanLimits.port,
}) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  if (text.startsWith('[')) {
    final end = text.indexOf(']');
    if (end <= 1) return null;
    final host = text.substring(1, end);
    var port = defaultPort;
    if (end + 1 < text.length && text[end + 1] == ':') {
      final parsed = int.tryParse(text.substring(end + 2));
      if (parsed == null || parsed <= 0 || parsed > 65535) return null;
      port = parsed;
    }
    return ManualEndpoint(host, port);
  }
  final colon = text.lastIndexOf(':');
  if (colon > 0 && !text.substring(0, colon).contains(':')) {
    final parsed = int.tryParse(text.substring(colon + 1));
    if (parsed != null && parsed > 0 && parsed <= 65535) {
      return ManualEndpoint(text.substring(0, colon), parsed);
    }
  }
  return ManualEndpoint(text, defaultPort);
}
