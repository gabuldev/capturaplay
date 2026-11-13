/// Mesmas operações por três caminhos. Compare os arquivos lado a lado:
///   - src/channel_lab.dart  (MethodChannel, como o app faz hoje)
///   - src/pigeon_lab.dart   (Pigeon, canal tipado e gerado)
///   - src/direct_lab.dart   (dart:ffi, chamada direta)
library;

export 'src/bench.dart';
export 'src/channel_lab.dart';
export 'src/direct_lab.dart';
export 'src/lab_stats.dart';
export 'src/pigeon_lab.dart';
