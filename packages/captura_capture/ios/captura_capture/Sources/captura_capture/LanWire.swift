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
        nalus: Data
    ) -> Data {
        var payload = Data()
        payload.appendU16(keyframe ? 1 : 0)
        payload.appendU16(sequence)
        payload.appendU64(ptsUs)
        payload.appendU32(senderLatencyUs)
        payload.appendU64(captureHostUs)
        payload.append(nalus)
        return encode(LanMessage(type: LanType.videoFrame, flags: 0, payload: payload))
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

    static func framePrefix(of payload: Data) -> (keyframe: Bool, sequence: UInt16, ptsUs: UInt64, senderLatencyUs: UInt32, captureHostUs: UInt64, nalus: Data)? {
        guard payload.count >= 24 else { return nil }
        let flags = payload.u16(0)
        return (
            keyframe: flags & 1 != 0,
            sequence: payload.u16(2),
            ptsUs: payload.u64(4),
            senderLatencyUs: payload.u32(12),
            captureHostUs: payload.u64(16),
            nalus: payload.subdata(in: 24..<payload.count)
        )
    }

    /// Same formula as `clockOffsetUs` in lan_protocol.dart.
    static func clockOffsetUs(clientSend: UInt64, serverRecv: UInt64, serverSend: UInt64, clientRecv: UInt64) -> Int64 {
        let first = Int64(bitPattern: serverRecv) - Int64(bitPattern: clientSend)
        let second = Int64(bitPattern: serverSend) - Int64(bitPattern: clientRecv)
        return (first + second) / 2
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
