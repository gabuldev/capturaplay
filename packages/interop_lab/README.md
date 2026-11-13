# interop_lab

Laboratório: as **mesmas três operações** (`ping`, `setVolume`, `getStats`) feitas por três caminhos entre Dart e Swift no macOS, para comparar código e custo.

| Caminho | Dart | Swift |
|---|---|---|
| 1. MethodChannel (como o `captura_capture` faz hoje) | `lib/src/channel_lab.dart` | `InteropLabPlugin.swift`, `handle(_:result:)` |
| 2. Pigeon (canal tipado, código gerado) | `lib/src/pigeon_lab.dart` + `pigeon/messages.dart` | `InteropLabPlugin.swift`, métodos do `LabPigeonApi` |
| 3. FFI direto (`dart:ffi`) | `lib/src/direct_lab.dart` | `DirectExports.swift` + memória em `LabEngine.swift` |

Os três leem e escrevem o mesmo `LabEngine`. Qualquer diferença medida é o custo do caminho, não do trabalho.

## Rodar

```bash
cd packages/interop_lab/example
flutter run --profile -d macos   # profile ou release: debug distorce os números
```

## Resultado (Flutter 3.50.0, macOS, profile, 20 mil chamadas)

| Operação | MethodChannel | Pigeon | FFI direto |
|---|---|---|---|
| ping | 27.0 µs | 40.0 µs | **0.005 µs** |
| setVolume | 29.5 µs | 24.9 µs | **0.005 µs** |
| getStats | 33.4 µs | 24.0 µs | **0.015 µs** |

Em **release** (mesma máquina): canais entre 18 e 26 µs, FFI entre 0.005 e 0.021 µs. A tabela de endereços funciona normalmente com os símbolos removidos.

A chamada direta é cerca de **4.000 a 5.000x mais barata**. MethodChannel e Pigeon ficam no mesmo patamar, porque usam o mesmo transporte. A variação entre os dois é ruído.

## Por que tanta diferença

**Canal (1 e 2):** Dart codifica a mensagem em bytes → engine enfileira → Swift decodifica, executa, codifica a resposta → volta pela fila → completa um `Future` no próximo giro do event loop. São ~25 µs de cerimônia para somar 1.

**FFI (3):** é uma chamada de função C. O argumento vai num registrador, a função roda na mesma thread e devolve o valor na hora. Por isso é **síncrono**: `direct.ping(1)` devolve `int`, não `Future<int>`.

**Stats por memória compartilhada:** no caminho 3, o Swift escreve os stats num bloco de memória e o Dart **lê direto do ponteiro**, a cada frame (ver o `Ticker` no `example/`). Não tem mensagem nenhuma: nem push a 4 Hz, nem cópia. Um seqlock (contador `seq`) evita ler um valor no meio da escrita.

**Thread:** no Flutter 3.50 a thread de UI do Dart é a main thread da plataforma (o app imprime `ui thread == main thread: true`). Uma função chamada por FFI roda nela, então pode mexer em AppKit sem `DispatchQueue.main.async`.

## O preço do FFI

- **Contrato escrito à mão:** tipos C, ordem dos slots da tabela, layout da memória. Se mudar de um lado e esquecer o outro, não dá exceção, **dá crash** (ou lixo).
- **Trava a UI:** a chamada é síncrona na thread de UI. Uma função nativa de 20 ms trava 20 ms de frame. Trabalho pesado continua tendo que ir para outra fila no Swift.
- **Nativo → Dart é mais difícil:** eventos (como "dispositivo desconectou") pedem `NativeCallable.listener` ou um canal. Aqui o exemplo só lê memória.
- **Símbolos em Release:** `@_cdecl` + `DynamicLibrary.process().lookup('nome')` pode quebrar em Release, porque o Xcode remove os símbolos globais do executável. Por isso o lab entrega os endereços numa tabela: o Dart pede o endereço **uma vez** pelo canal (`directTable`) e depois nunca mais usa canal.

## E o CapturaPlay?

O vídeo **nunca passa pelo Dart**: Cam Link → AVFoundation → preview e encoder nativos. Pelo canal só passam comandos e stats a 4 Hz: 4 × ~30 µs ≈ **0,1 ms por segundo**. Trocar por FFI economiza isso e não muda o FPS da captura.

O FFI vale a pena quando:
- a chamada acontece **muitas vezes por frame** (ex.: ler o estado do encoder a cada frame)
- você precisa da resposta **síncrona**, sem `await`
- o dado é **grande** e copiar custa caro (ex.: um buffer de áudio ou um histograma de latência)
