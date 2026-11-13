import Foundation

// Caminho 3: chamada direta (dart:ffi).
//
// Dart chama estas funções como se fossem funções C: sem mensagem, sem codec,
// sem fila. Cada uma é um `@convention(c)` closure, ou seja, um ponteiro de
// função C comum.
//
// Por que uma tabela e não `@_cdecl` + `DynamicLibrary.process().lookup`?
// Em Release o Xcode remove (strip) os símbolos globais do executável, e o
// `lookup` por nome deixa de achar a função. Entregar os endereços numa tabela
// não depende de nome nenhum. O Dart pede o endereço da tabela uma única vez
// pelo canal (`directTable`) e, a partir daí, nunca mais usa canal.

typealias PingFn = @convention(c) (Int64) -> Int64
typealias SetVolumeFn = @convention(c) (Double) -> Void
typealias GetVolumeFn = @convention(c) () -> Double
typealias IsMainThreadFn = @convention(c) () -> Bool

private let ping: PingFn = { value in value &+ 1 }

private let setVolume: SetVolumeFn = { volume in
    // Uma chamada FFI roda na thread de quem chamou. Com a thread de UI unida à
    // thread de plataforma (padrão no Flutter novo), essa é a main thread, então
    // dá para mexer em AppKit aqui. `isMainThread` abaixo confirma isso em runtime.
    LabEngine.shared.volume = volume
}

private let getVolume: GetVolumeFn = { LabEngine.shared.volume }

private let isMainThread: IsMainThreadFn = { Thread.isMainThread }

/// Layout, 8 bytes per slot. Dart mirrors it in `direct_lab.dart` (`_Slot`).
///   [0] ping   [1] setVolume   [2] getVolume   [3] isMainThread   [4] stats memory
enum DirectTable {
    static let slots = 5

    static let pointer: UnsafeMutablePointer<UnsafeRawPointer?> = {
        let table = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: slots)
        table[0] = unsafeBitCast(ping, to: UnsafeRawPointer.self)
        table[1] = unsafeBitCast(setVolume, to: UnsafeRawPointer.self)
        table[2] = unsafeBitCast(getVolume, to: UnsafeRawPointer.self)
        table[3] = unsafeBitCast(isMainThread, to: UnsafeRawPointer.self)
        table[4] = UnsafeRawPointer(LabEngine.shared.stats)
        return table
    }()

    static var address: Int64 { Int64(Int(bitPattern: pointer)) }
}
