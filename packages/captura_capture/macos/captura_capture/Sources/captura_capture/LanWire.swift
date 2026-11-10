import Foundation

/// Binary framing for CapturaPlay LAN video.
///
/// The layout is specified by `packages/captura_capture/lib/src/lan_protocol.dart`.
/// Keep the two in lockstep. This file is Foundation-only so it can be copied
/// into the iOS target without pulling in AppKit or UIKit.
enum LanType {
    static let hello: UInt8 = 1
    static let helloAck: UInt8 = 2
    static let videoConfig: UInt8 = 0x10
    static let videoFrame: UInt8 = 0x11
    static let keyframeRequest: UInt8 = 0x12
    static let transport: UInt8 = 0x14
    static let audioConfig: UInt8 = 0x20
    static let audioFrame: UInt8 = 0x21
    static let input: UInt8 = 0x30
    static let ping: UInt8 = 0x40
    static let pong: UInt8 = 0x41
    static let bye: UInt8 = 0x7F
}

enum LanLimits {
    static let version: UInt8 = 1
    static let headerSize = 12
    static let maxPayload = 4_000_000
    static let port: UInt16 = 47731
    static let serviceType = "_capturaplay._tcp"
    static let magic: [UInt8] = [0x43, 0x50, 0x4C, 0x31]
}

enum LanFeatures {
    static let video: UInt16 = 1
    static let audio: UInt16 = 2
    static let input: UInt16 = 4
    static let udp: UInt16 = 8
}

enum LanDecodeError: Error {
    case magic
    case version
    case length
    case payload
}

struct LanMessage {
    var type: UInt8
    var flags: UInt16
    var payload: Data
}

enum LanWire {
    static func encode(_ message: LanMessage) -> Data {
        var data = Data()
        data.append(contentsOf: LanLimits.magic)
        data.append(LanLimits.version)
        data.append(message.type)
        data.appendU16(message.flags)
        data.appendU32(UInt32(message.payload.count))
        data.append(message.payload)
        return data
    }

    static func hello(features: UInt16) -> Data {
        var payload = Data()
        payload.append(LanLimits.version)
        payload.appendU16(features)
        return encode(LanMessage(type: LanType.hello, flags: 0, payload: payload))
    }

    static func helloAck(features: UInt16) -> Data {
        var payload = Data()
        payload.append(LanLimits.version)
        payload.appendU16(features)
        return encode(LanMessage(type: LanType.helloAck, flags: 0, payload: payload))
    }

    static func videoConfig(width: Int, height: Int, fpsMilli: Int, sps: Data, pps: Data, bitrateMbps: Int = 0, maxFrameQp: Int = 0) -> Data {
        var payload = Data()
        payload.append(1)
        payload.append(4)
        payload.appendU16(UInt16(width))
        payload.appendU16(UInt16(height))
        payload.appendU32(UInt32(fpsMilli))
        payload.appendU16(UInt16(sps.count))
        payload.append(sps)
        payload.appendU16(UInt16(pps.count))
        payload.append(pps)
        if bitrateMbps > 0 {
            payload.appendU32(UInt32(bitrateMbps))
            payload.appendU32(UInt32(max(0, maxFrameQp)))
        }
        return encode(LanMessage(type: LanType.videoConfig, flags: 0, payload: payload))
    }

    static func videoFrame(
        keyframe: Bool,
        sequence: UInt16,
        ptsUs: UInt64,
        senderLatencyUs: UInt32,
        captureHostUs: UInt64,
        encoderInUs: UInt64,
        encoderOutUs: UInt64,
        sendUs: UInt64,
        nalus: Data
    ) -> Data {
        var payload = Data()
        payload.appendU16(keyframe ? 1 : 0)
        payload.appendU16(sequence)
        payload.appendU64(ptsUs)
        payload.appendU32(senderLatencyUs)
        payload.appendU64(captureHostUs)
        payload.appendU64(encoderInUs)
        payload.appendU64(encoderOutUs)
        payload.appendU64(sendUs)
        payload.append(nalus)
        return encode(LanMessage(type: LanType.videoFrame, flags: 0, payload: payload))
    }

    static func keyframeRequest() -> Data {
        encode(LanMessage(type: LanType.keyframeRequest, flags: 0, payload: Data()))
    }

    static func transport(udp: Bool) -> Data {
        encode(LanMessage(type: LanType.transport, flags: 0, payload: Data([udp ? 1 : 0])))
    }

    static func ping(clientTimeUs: UInt64) -> Data {
        var payload = Data()
        payload.appendU64(clientTimeUs)
        return encode(LanMessage(type: LanType.ping, flags: 0, payload: payload))
    }

    static func pong(clientTimeUs: UInt64, serverRecvUs: UInt64, serverSendUs: UInt64) -> Data {
        var payload = Data()
        payload.appendU64(clientTimeUs)
        payload.appendU64(serverRecvUs)
        payload.appendU64(serverSendUs)
        return encode(LanMessage(type: LanType.pong, flags: 0, payload: payload))
    }

    static func framePrefix(of payload: Data) -> (keyframe: Bool, sequence: UInt16, ptsUs: UInt64, senderLatencyUs: UInt32, captureHostUs: UInt64, encoderInUs: UInt64, encoderOutUs: UInt64, sendUs: UInt64, nalus: Data)? {
        guard payload.count >= 48 else { return nil }
        let flags = payload.u16(0)
        return (
            keyframe: flags & 1 != 0,
            sequence: payload.u16(2),
            ptsUs: payload.u64(4),
            senderLatencyUs: payload.u32(12),
            captureHostUs: payload.u64(16),
            encoderInUs: payload.u64(24),
            encoderOutUs: payload.u64(32),
            sendUs: payload.u64(40),
            nalus: payload.subdata(in: 48..<payload.count)
        )
    }

    static func transportIsUdp(of payload: Data) -> Bool? {
        guard payload.count >= 1 else { return nil }
        return payload[0] == 1
    }

    /// Same formula as `clockOffsetUs` in lan_protocol.dart.
    static func clockOffsetUs(clientSend: UInt64, serverRecv: UInt64, serverSend: UInt64, clientRecv: UInt64) -> Int64 {
        let first = Int64(bitPattern: serverRecv) - Int64(bitPattern: clientSend)
        let second = Int64(bitPattern: serverSend) - Int64(bitPattern: clientRecv)
        return (first + second) / 2
    }

    static func roundTripUs(clientSend: UInt64, serverRecv: UInt64, serverSend: UInt64, clientRecv: UInt64) -> Int64 {
        let total = Int64(bitPattern: clientRecv) - Int64(bitPattern: clientSend)
        let server = Int64(bitPattern: serverSend) - Int64(bitPattern: serverRecv)
        return total - server
    }

    static func parameterSets(of payload: Data) -> (width: Int, height: Int, fpsMilli: Int, sps: Data, pps: Data)? {
        guard payload.count >= 14, payload[0] == 1, payload[1] == 4 else { return nil }
        let width = Int(payload.u16(2))
        let height = Int(payload.u16(4))
        let fpsMilli = Int(payload.u32(6))
        let spsLength = Int(payload.u16(10))
        let spsEnd = 12 + spsLength
        guard payload.count >= spsEnd + 2 else { return nil }
        let sps = payload.subdata(in: 12..<spsEnd)
        let ppsLength = Int(payload.u16(spsEnd))
        let ppsEnd = spsEnd + 2 + ppsLength
        guard payload.count >= ppsEnd else { return nil }
        let pps = payload.subdata(in: (spsEnd + 2)..<ppsEnd)
        return (width, height, fpsMilli, sps, pps)
    }

    static func configBitrateMbps(of payload: Data) -> Int? {
        guard let sets = parameterSets(of: payload) else { return nil }
        let end = 12 + sets.sps.count + 2 + sets.pps.count
        guard payload.count >= end + 4 else { return nil }
        return Int(payload.u32(end))
    }

    static func configMaxFrameQp(of payload: Data) -> Int? {
        guard let sets = parameterSets(of: payload) else { return nil }
        let end = 12 + sets.sps.count + 2 + sets.pps.count
        guard payload.count >= end + 8 else { return nil }
        return Int(payload.u32(end + 4))
    }

    static func pingTime(of payload: Data) -> UInt64? {
        guard payload.count >= 8 else { return nil }
        return payload.u64(0)
    }

    static func pongTimes(of payload: Data) -> (t1: UInt64, t2: UInt64, t3: UInt64)? {
        guard payload.count >= 24 else { return nil }
        return (payload.u64(0), payload.u64(8), payload.u64(16))
    }
}

enum UdpFlag {
    static let keyframe: UInt8 = 0x01
    static let timing: UInt8 = 0x02
    static let keepalive: UInt8 = 0x40
    static let bind: UInt8 = 0x80
}

enum UdpLimits {
    static let headerSize = 12
    static let timingSize = 32
    static let datagramSize = 1200
    static let magic: [UInt8] = [0x43, 0x50, 0x4C, 0x55]
}

struct UdpTiming {
    var captureUs: UInt64
    var encoderInUs: UInt64
    var encoderOutUs: UInt64
    var sendUs: UInt64
}

struct UdpPacket {
    var flags: UInt8
    var frameId: UInt16
    var fragIndex: UInt16
    var fragCount: UInt16
    var payload: Data

    var isBind: Bool { flags & UdpFlag.bind != 0 }
    var isKeepalive: Bool { flags & UdpFlag.keepalive != 0 }
    var keyframe: Bool { flags & UdpFlag.keyframe != 0 }
    var hasTiming: Bool { flags & UdpFlag.timing != 0 }
}

struct UdpAssembled {
    var frameId: UInt16
    var keyframe: Bool
    var timing: UdpTiming
    var nalus: Data
}

enum LanUdp {
    static func bindPacket() -> Data {
        packet(flags: UdpFlag.bind, frameId: 0, fragIndex: 0, fragCount: 0, payload: Data())
    }

    static func isBind(_ data: Data) -> Bool {
        guard let parsed = parse(data) else { return false }
        return parsed.isBind
    }

    static func keepalivePacket() -> Data {
        packet(flags: UdpFlag.keepalive, frameId: 0, fragIndex: 0, fragCount: 0, payload: Data())
    }

    static func isKeepalive(_ data: Data) -> Bool {
        guard let parsed = parse(data) else { return false }
        return parsed.isKeepalive
    }

    static func packets(frameId: UInt16, keyframe: Bool, timing: UdpTiming, nalus: Data) -> [Data] {
        guard !nalus.isEmpty else { return [] }
        let firstBudget = UdpLimits.datagramSize - UdpLimits.headerSize - UdpLimits.timingSize
        let nextBudget = UdpLimits.datagramSize - UdpLimits.headerSize
        let rest = nalus.count > firstBudget ? nalus.count - firstBudget : 0
        let extra = rest == 0 ? 0 : (rest + nextBudget - 1) / nextBudget
        let count = 1 + extra
        var packets: [Data] = []
        var offset = 0
        for index in 0..<count {
            let budget = index == 0 ? firstBudget : nextBudget
            let size = min(nalus.count - offset, budget)
            var payload = Data()
            if index == 0 {
                payload.appendU64(timing.captureUs)
                payload.appendU64(timing.encoderInUs)
                payload.appendU64(timing.encoderOutUs)
                payload.appendU64(timing.sendUs)
            }
            payload.append(nalus.subdata(in: offset..<(offset + size)))
            var flags: UInt8 = keyframe ? UdpFlag.keyframe : 0
            if index == 0 { flags |= UdpFlag.timing }
            packets.append(packet(flags: flags, frameId: frameId, fragIndex: UInt16(index), fragCount: UInt16(count), payload: payload))
            offset += size
        }
        return packets
    }

    static func parse(_ data: Data) -> UdpPacket? {
        guard data.count >= UdpLimits.headerSize else { return nil }
        for index in 0..<4 where data[index] != UdpLimits.magic[index] { return nil }
        guard data[4] == LanLimits.version else { return nil }
        return UdpPacket(
            flags: data[5],
            frameId: data.u16(6),
            fragIndex: data.u16(8),
            fragCount: data.u16(10),
            payload: data.subdata(in: UdpLimits.headerSize..<data.count)
        )
    }

    private static func packet(flags: UInt8, frameId: UInt16, fragIndex: UInt16, fragCount: UInt16, payload: Data) -> Data {
        var data = Data()
        data.append(contentsOf: UdpLimits.magic)
        data.append(LanLimits.version)
        data.append(flags)
        data.appendU16(frameId)
        data.appendU16(fragIndex)
        data.appendU16(fragCount)
        data.append(payload)
        return data
    }
}

final class UdpReassembler {
    static let partialTimeout: TimeInterval = 0.008

    private var frameId: UInt16?
    private var count = 0
    private var parts: [Data?] = []
    private var keyframe = false
    private var timing: UdpTiming?
    private var got = 0
    private var startedAt: TimeInterval?

    /// Drops a partial frame that has sat longer than [partialTimeout].
    /// A lost tail must not wait for the next beacon or the next keyframe.
    func expire(now: TimeInterval) -> Bool {
        guard let startedAt, frameId != nil, got != count else { return false }
        guard now - startedAt >= Self.partialTimeout else { return false }
        reset()
        return true
    }

    /// Completed frame, and whether the previous partial frame was discarded.
    func add(_ data: Data, now: TimeInterval) -> (frame: UdpAssembled?, droppedIncomplete: Bool) {
        guard let packet = LanUdp.parse(data) else { return (nil, false) }
        if packet.isBind || packet.isKeepalive || packet.fragCount == 0 { return (nil, false) }
        guard packet.fragIndex < packet.fragCount else { return (nil, false) }
        if let current = frameId, packet.frameId != current {
            let ahead = UInt16(truncatingIfNeeded: Int(packet.frameId) &- Int(current))
            if ahead == 0 || ahead >= 0x8000 { return (nil, false) }
            let dropped = got != count
            reset()
            start(packet, now: now)
            let done = store(packet)
            return (done, dropped)
        }
        if frameId == nil { start(packet, now: now) }
        guard packet.fragCount == count else { return (nil, false) }
        return (store(packet), false)
    }

    private func start(_ packet: UdpPacket, now: TimeInterval) {
        frameId = packet.frameId
        count = Int(packet.fragCount)
        parts = Array(repeating: nil, count: count)
        keyframe = packet.keyframe
        got = 0
        timing = nil
        startedAt = now
    }

    private func store(_ packet: UdpPacket) -> UdpAssembled? {
        let index = Int(packet.fragIndex)
        guard parts.indices.contains(index), parts[index] == nil else { return nil }
        if index == 0 {
            guard packet.hasTiming, packet.payload.count >= UdpLimits.timingSize else { return nil }
            timing = UdpTiming(
                captureUs: packet.payload.u64(0),
                encoderInUs: packet.payload.u64(8),
                encoderOutUs: packet.payload.u64(16),
                sendUs: packet.payload.u64(24)
            )
            parts[0] = packet.payload.subdata(in: UdpLimits.timingSize..<packet.payload.count)
            keyframe = packet.keyframe
        } else {
            parts[index] = packet.payload
        }
        got += 1
        guard got == count, let timing, let frameId else { return nil }
        var nalus = Data()
        for part in parts {
            guard let part else { return nil }
            nalus.append(part)
        }
        let frame = UdpAssembled(frameId: frameId, keyframe: keyframe, timing: timing, nalus: nalus)
        reset()
        return frame
    }

    private func reset() {
        frameId = nil
        count = 0
        parts = []
        got = 0
        timing = nil
        keyframe = false
        startedAt = nil
    }
}

final class LanStreamParser {
    private var buffer = Data()

    func add(_ chunk: Data) throws -> [LanMessage] {
        buffer.append(chunk)
        var messages: [LanMessage] = []
        while buffer.count >= LanLimits.headerSize {
            for index in 0..<4 where buffer[index] != LanLimits.magic[index] {
                throw LanDecodeError.magic
            }
            if buffer[4] != LanLimits.version {
                throw LanDecodeError.version
            }
            let type = buffer[5]
            let flags = buffer.u16(6)
            let length = Int(buffer.u32(8))
            if length > LanLimits.maxPayload {
                throw LanDecodeError.length
            }
            let total = LanLimits.headerSize + length
            if buffer.count < total { break }
            let payload = buffer.subdata(in: LanLimits.headerSize..<total)
            buffer.removeSubrange(0..<total)
            messages.append(LanMessage(type: type, flags: flags, payload: payload))
        }
        return messages
    }

    func reset() {
        buffer.removeAll(keepingCapacity: true)
    }
}

private extension Data {
    mutating func appendU16(_ value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xff))
    }

    mutating func appendU32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendU64(_ value: UInt64) {
        appendU32(UInt32((value >> 32) & 0xffff_ffff))
        appendU32(UInt32(value & 0xffff_ffff))
    }

    func u16(_ offset: Int) -> UInt16 {
        (UInt16(self[offset]) << 8) | UInt16(self[offset + 1])
    }

    func u32(_ offset: Int) -> UInt32 {
        (UInt32(self[offset]) << 24)
            | (UInt32(self[offset + 1]) << 16)
            | (UInt32(self[offset + 2]) << 8)
            | UInt32(self[offset + 3])
    }

    func u64(_ offset: Int) -> UInt64 {
        (UInt64(u32(offset)) << 32) | UInt64(u32(offset + 4))
    }
}
