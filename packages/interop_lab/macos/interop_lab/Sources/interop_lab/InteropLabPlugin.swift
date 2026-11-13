import Cocoa
import FlutterMacOS

/// Registers paths 1 (MethodChannel) and 2 (Pigeon), and hands out the
/// address of the direct-call table (path 3).
public class InteropLabPlugin: NSObject, FlutterPlugin, LabPigeonApi {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = InteropLabPlugin()
        _ = LabEngine.shared

        let channel = FlutterMethodChannel(name: "interop_lab/methods", binaryMessenger: registrar.messenger)
        registrar.addMethodCallDelegate(instance, channel: channel)

        LabPigeonApiSetup.setUp(binaryMessenger: registrar.messenger, api: instance)
    }

    // MARK: - Caminho 1: MethodChannel
    //
    // Cada chamada chega como `FlutterMethodCall`: um nome em String e
    // argumentos `Any?` que você precisa converter na mão. Errou o nome ou o
    // tipo? Só descobre em runtime.

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "ping":
            let value = (call.arguments as? NSNumber)?.int64Value ?? 0
            result(value &+ 1)
        case "setVolume":
            let args = call.arguments as? [String: Any]
            LabEngine.shared.volume = (args?["volume"] as? NSNumber)?.doubleValue ?? 1
            result(nil)
        case "getStats":
            let s = LabEngine.shared.snapshot()
            result([
                "fps": s.fps,
                "latencyMs": s.latencyMs,
                "dropped": s.dropped,
                "frames": s.frames,
            ])
        case "directTable":
            // Única ponte entre os mundos: o endereço da tabela do caminho 3.
            result(DirectTable.address)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Caminho 2: Pigeon
    //
    // Mesmas operações, mas com assinatura tipada gerada pelo Pigeon. O
    // compilador reclama se a interface mudar. O transporte continua sendo
    // mensagem + codec + fila.

    func ping(value: Int64) throws -> Int64 { value &+ 1 }

    func setVolume(volume: Double) throws { LabEngine.shared.volume = volume }

    func getStats() throws -> LabStatsMessage {
        let s = LabEngine.shared.snapshot()
        return LabStatsMessage(fps: s.fps, latencyMs: s.latencyMs, dropped: s.dropped, frames: s.frames)
    }
}
