import Foundation

/// A tiny stand-in for `CaptureEngine`: it owns a volume and produces stats at
/// 60 Hz on a background queue, the same shape as the real capture stats.
/// The three interop paths read and write this one object, so any difference
/// you measure is the cost of the path, not of the work.
final class LabEngine {
    static let shared = LabEngine()

    /// Read and written on the main thread only.
    var volume: Double = 1

    /// Shared memory that Dart reads directly (path 3).
    ///
    /// Layout, 8 bytes per field, little endian (both Apple Silicon and Intel):
    ///   [0] Int64  seq        odd while a write is in progress
    ///   [1] Double fps
    ///   [2] Double latencyMs
    ///   [3] Int64  dropped
    ///   [4] Int64  frames
    /// Dart mirrors this in `direct_lab.dart` (`_LabStatsLayout`).
    let stats: UnsafeMutableRawPointer

    private let queue = DispatchQueue(label: "interop_lab.stats", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var frames: Int64 = 0
    private var dropped: Int64 = 0

    private init() {
        stats = UnsafeMutableRawPointer.allocate(byteCount: 5 * 8, alignment: 8)
        stats.initializeMemory(as: UInt8.self, repeating: 0, count: 5 * 8)
        start()
    }

    private func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        frames += 1
        if frames % 600 == 0 { dropped += 1 }
        let fps = 59.5 + Double(frames % 10) / 10
        let latency = 18 + Double(frames % 7)

        // Seqlock writer: odd seq means "being written", even means "stable".
        // A reader that sees an odd seq, or a seq that changed during its read,
        // tries again. There are no memory fences here (Dart has no way to issue
        // one on a raw pointer), so a torn read is possible in theory. For
        // display-only stats that is fine; for anything that must be exact, use
        // a callback or a lock instead.
        let seq = stats.load(fromByteOffset: 0, as: Int64.self)
        stats.storeBytes(of: seq &+ 1, toByteOffset: 0, as: Int64.self)
        stats.storeBytes(of: fps, toByteOffset: 8, as: Double.self)
        stats.storeBytes(of: latency, toByteOffset: 16, as: Double.self)
        stats.storeBytes(of: dropped, toByteOffset: 24, as: Int64.self)
        stats.storeBytes(of: frames, toByteOffset: 32, as: Int64.self)
        stats.storeBytes(of: seq &+ 2, toByteOffset: 0, as: Int64.self)
    }

    /// Copy for the channel paths: they must serialize a value, not a pointer.
    func snapshot() -> (fps: Double, latencyMs: Double, dropped: Int64, frames: Int64) {
        while true {
            let before = stats.load(fromByteOffset: 0, as: Int64.self)
            if before & 1 == 1 { continue }
            let value = (
                stats.load(fromByteOffset: 8, as: Double.self),
                stats.load(fromByteOffset: 16, as: Double.self),
                stats.load(fromByteOffset: 24, as: Int64.self),
                stats.load(fromByteOffset: 32, as: Int64.self)
            )
            if stats.load(fromByteOffset: 0, as: Int64.self) == before { return value }
        }
    }
}
