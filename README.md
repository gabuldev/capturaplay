# CapturaPlay

App de macOS para jogar olhando para um capturador USB (UVC), no caso um Elgato Cam Link 4K, com a menor latência que o AVFoundation entrega. O vídeo ocupa a janela. O áudio do capturador sai nas caixas ou no fone.

Não há splitter no meio. O HDMI sai do console, entra no Cam Link, e o USB entra no Mac. Esta janela é a tela.

O arquivo do app se chama `capturaplay.app`. O nome na Dock e na janela é **CapturaPlay**.

## Por que a prévia é este caminho

A imagem não passa pelo registro de texturas do Flutter.

O `AVCaptureVideoPreviewLayer` é a prévia que a Apple desenha dentro da própria sessão de captura. No macOS o Flutter embute platform view por composição híbrida: o `NSView` entra de verdade na hierarquia da janela, e a layer atualiza no relógio do AVFoundation, não no frame seguinte do Impeller. Empurrar `CVPixelBuffer` pelo `FlutterTexture` exigiria um `AVCaptureVideoDataOutput`, pelo menos um quadro a mais, e a entrega do buffer na thread de raster.

Por isso a prévia é a backing layer de um `NSView` (`PreviewHostView`). O widget `CapturePreview` não pode levar clip, opacidade ou transformada: isso faz o Flutter recompor a view nativa e devolve a latência que este caminho evita.

O áudio vai por `AVCaptureAudioPreviewOutput`, direto para a saída padrão do sistema. Não há buffer do lado do app. O tamanho do buffer interno do AVFoundation não é público; se num Mac ele parecer alto demais, o gancho da fase 2 é o lugar para um tap Core Audio com buffer curto. Enquanto isso, este é o caminho mais curto que continua no mesmo relógio da sessão.

A captura e a tela estão separadas. `CaptureEngine` é dono da `AVCaptureSession`. A layer só recebe a sessão. Buffers de vídeo (NV12 com IOSurface, quando há consumidor) e de áudio (PCM) só saem por `CaptureMediaSink`, e os data outputs só entram na sessão enquanto existe um sink — ou enquanto a sobreposição de dados está ligada. Jogar não paga o custo de um encoder que não está rodando.

A sobreposição (tecla `I`) liga um data output que só conta quadros. O número de latência é a diferença entre o PTS do sample e o relógio da sessão no momento em que esse tap recebe o buffer. É uma estimativa do pipeline de captura, e um teto para a prévia, que costuma ser um pouco mais cedo. Valor negativo ou acima de 2 s aparece como "—": o relógio não fechou. Desligue a sobreposição para voltar ao caminho mínimo.

Enquanto a sessão está aberta, o processo pede `idleDisplaySleepDisabled`. A tela não apaga. Fechar a tampa ainda pode suspender o Mac.

## Requisitos

- Mac com macOS 14 ou mais novo
- Xcode atual, com as ferramentas de linha de comando
- Flutter stable (este projeto foi gerado com Flutter 3.47.9 e Dart 3.13.7)
- Capturador UVC. O app escolhe sozinho um dispositivo cujo nome contém "Cam Link"
- Porta USB 3, USB 4 ou Thunderbolt direto no Mac

O Flutter deste repositório usa Swift Package Manager para o plugin, que é o padrão do stable atual. Se o Flutter local tiver isso desligado:

```bash
flutter config --enable-swift-package-manager
```

## Compilar e rodar

Na raiz do repositório:

```bash
flutter pub get
flutter run -d macos
```

Release:

```bash
flutter build macos
open build/macos/Build/Products/Release/capturaplay.app
```

Na primeira abertura o sistema pede câmera e microfone. As duas permissões são do capturador: o vídeo entra como câmera USB e o som entra como entrada de áudio. Não é o microfone do Mac, a menos que você o escolha na barra.

Textos no `Info.plist`:

- `NSCameraUsageDescription`
- `NSMicrophoneUsageDescription`

Sandbox, nos entitlements de Debug e Release:

- `com.apple.security.device.camera`
- `com.apple.security.device.audio-input`

Para conferir o binário:

```bash
codesign -d --entitlements :- build/macos/Build/Products/Release/capturaplay.app
```

Se o diálogo não aparecer, abra Ajustes do Sistema → Privacidade e Segurança → Câmera e Microfone, e autorize o CapturaPlay. O botão "Abrir Ajustes do Sistema" na tela de permissão tenta esse painel.

A última escolha de vídeo, áudio, formato, volume e mudo fica no `UserDefaults`. Na primeira vez, sem memória, entra o dispositivo com "Cam Link" no nome e o formato 1920×1080 @ 60 fps, se o hardware oferecer. O microfone interno nunca é escolhido sozinho.

## Ligar o console em 1080p sem HDCP

O Cam Link 4K, neste uso, quer 1080p60 SDR. 4K nele é 30 fps. 120 Hz e VRR não são o modo estável dessa placa.

Cabo, sem splitter e sem TV no caminho:

1. HDMI out do console → HDMI in do Cam Link.
2. USB do Cam Link → porta USB 3 do Mac, direto.

No console (os nomes abaixo são os da interface em português; em inglês é Settings → Screen and Video → Video Output, e Settings → System → HDMI):

1. Ajustes → Tela e Vídeo → Saída de Vídeo → Resolução → **1080p**.
2. Saída de 120 Hz → **Desligada**.
3. VRR → **Desligado**.
4. HDR → **Desligado**. O alvo daqui é 1080p SDR. HDR empurra outro modo e não ajuda a latência.
5. Ajustes → Sistema → HDMI → HDCP → **Desligado**.

HDCP desligado é o interruptor do próprio console para captura. Sem isso o capturador recebe uma imagem protegida e a janela fica preta ou numa tela de erro. Jogos seguem. Apps de streaming do console podem recusar abrir enquanto o HDCP está desligado; isso é o comportamento esperado do console, não um defeito do app.

Se a imagem não travar em 1080p60, escolha o formato na barra. O chip no alto mostra o formato que a sessão realmente ativou.

## Usar junto com o OBS

Um dispositivo UVC tem um fluxo de vídeo ativo. No macOS o `UVCAssistant` segura a interface USB e os apps falam com ele pelo CoreMedia. Na prática o Cam Link não fica estável com o OBS e outro `AVCaptureSession` ao mesmo tempo: o segundo falha, fica sem quadro, ou os dois renegociam o formato e a imagem pisca. A propriedade `isInUseByAnotherApplication` não serve de sentinela — ela marca trava exclusiva de configuração, não "tem uma sessão aberta". Trate como um único dono.

O dono tem de ser este app. Quem joga olha para o `AVCaptureVideoPreviewLayer`. O atraso de uma captura de janela fica no stream, onde o OBS já segura buffer. O contrário (OBS dono do Cam Link, e este app filmando a prévia do OBS) põe esse atraso na frente de quem está jogando.

```
console --HDMI--> Cam Link --USB--> CapturaPlay
                                      |  prévia nativa (você joga aqui)
                                      |  áudio direto na saída do Mac
                                      v
                                    OBS captura a JANELA do CapturaPlay
                                      |
                                      v
                                    live / gravação
```

No OBS:

1. Não crie fonte "Dispositivo de captura de vídeo" no Cam Link. Se já existir, apague e reinicie o OBS para ele soltar o USB.
2. Fonte **Captura de tela do macOS**, modo **Captura de janela**, janela **CapturaPlay**.
3. O OBS vai pedir permissão de Gravação de Tela. Isso é do OBS, não deste app.
4. Captura de janela evita que notificação do macOS entre no stream. Captura de tela inteira também funciona se o CapturaPlay estiver em tela cheia num monitor só dele, mas notificação e menu aparecem no vídeo.
5. Som: o jogo sai na saída padrão do Mac. No OBS, inclua o áudio dessa captura de tela (macOS 13+) ou uma fonte de áudio do desktop. Use fone. Caixa alta mais microfone regrava o jogo e gera eco.

Não use a câmera virtual do OBS como fonte para jogar. Ela acrescenta uma codificação no caminho dos olhos.

Se o CapturaPlay disser que o dispositivo está em uso, feche a fonte do Cam Link no OBS (ou o outro app) e toque em "Tentar de novo".

## Atalhos

| Ação | Como |
| --- | --- |
| Tela cheia | `F`, duplo clique na imagem, ou `⌘⌃F` (menu Visualizar) |
| Mudo | `M` ou o botão de volume |
| Volume | Slider, ou `↑` / `↓` |
| Dados (fps e latência estimada) | `I` |
| Cursor | Some com a barra depois de um instante sem mexer o mouse, e volta no movimento |

`Esc` sai da tela cheia, como em qualquer janela do macOS.

## Limitações conhecidas

- Um app por vez no Cam Link. Ver a seção do OBS.
- Conteúdo com HDCP ligado não aparece. O interruptor é o do console.
- O app não grava e não transmite. A fase 2 está só desenhada.
- A latência real depende do Cam Link, da porta USB e do macOS. O número da sobreposição é estimativa do tap de estatística, não uma medição de ponta a ponta com fotodiodo. Ela não foi medida em hardware neste repositório.
- O buffer do `AVCaptureAudioPreviewOutput` não tem ajuste público.
- A sobreposição de dados acrescenta um data output. Desligue com `I` para o caminho mínimo.
- Cam Link 4K: 1080p60 ou 4K30, não 4K60.
- Plataform view no macOS ainda tem arestas. O duplo clique depende do `NSView` devolver `nil` no hit test. `F` e `⌘⌃F` não dependem disso.
- A tela não apaga durante a sessão. Suspender pela tampa continua possível.
- O entitlement de rede de servidor não está no Release. A fase 2 vai precisar dele.

## Onde está o código

- `lib/` — interface em pt-BR, atalhos, barra, estado.
- `packages/captura_capture/` — API Dart testável (escolha de dispositivo e formato) e o plugin Swift.
- `CaptureEngine.swift` — sessão, formatos, áudio, sono da tela.
- `CaptureMediaSink.swift` — contrato do futuro encoder.
- `PreviewHostView.swift` — a layer de prévia.

Para um módulo de streaming no mesmo target Swift, registre o sink em `CaptureEngine.addMediaSink`. De outro target, o plugin é publicado no registry com a chave `CapturaCapturePlugin` (`CapturaCapturePlugin.registryKey`) e o `engine` é público. O callback do sink roda na fila de captura: retenha o pixel buffer se ainda precisar dele e saia logo. Não mande o frame pelo method channel.

## Fase 2: streaming na rede local

Não está implementado. O desenho, para quando for a hora:

O Mac continua capturando. Um `LanStreamService` no mesmo processo implementa `CaptureMediaSink` e recebe os mesmos sample buffers, sem cópia para o Dart.

```
CaptureEngine
  ├─ AVCaptureVideoPreviewLayer     quem joga no Mac, hoje
  ├─ AVCaptureAudioPreviewOutput    som local, hoje
  └─ CaptureMediaSink               só quando alguém registra
        ├─ vídeo NV12 + IOSurface
        └─ áudio PCM
              │
              v
        VideoToolbox (H.264, baixa latência, sem frame B)
        + WebRTC (pista de vídeo e áudio)
              │
              v
        TV (webOS ou Tizen, página web) ou um browser na mesma Wi-Fi
```

WebRTC é a proposta porque a TV abre uma página, sem app nativo, e o orçamento de latência é melhor que HLS. Sinalização mínima na LAN (HTTP ou WebSocket na máquina) e candidatos ICE só do tipo host, sem STUN, numa rede simples.

Perguntas em aberto, de propósito:

1. **O que o browser da TV aceita.** webOS e Tizen usam Chromium, mas a versão e o WebRTC variam por ano de modelo. H.264 Constrained Baseline é o perfil seguro. HEVC no browser da TV é aposta ruim. Dá para confirmar só com um aparelho na mesa.
2. **Medir o data output com a prévia ligada.** Se ligar o sink atrasar a imagem de quem joga, as opções são aceitar esse custo ou desenhar a mesma IOSurface numa textura Flutter e ter um consumidor só. A troca fica na ponta da tela; a sessão não muda de dono.
3. **Encoder de hardware.** `VTCompressionSession` em tempo real, GOP curto ou intra-refresh, sem frame B. O OBS, capturando a janela, também pode estar codificando. Apple Silicon aguenta mais de uma sessão VideoToolbox, mas o limite existe e precisa ser medido com os dois ligados.
4. **Relógio do áudio.** A prévia local continua no `AVCaptureAudioPreviewOutput` para quem joga no Mac. O stream usa o data output de áudio, sincronizado pelo PTS. TV e caixas do Mac no mesmo cômodo geram eco: o desenho assume fone, ou a TV muda.
5. **Achar o Mac na rede.** mDNS contra digitar o IP. Isolamento de cliente no roteador, e alguns browsers de TV que exigem TURN mesmo na LAN, podem impedir o par direto. Isso só se descobre na rede de casa.
6. **Sandbox.** Release hoje não tem `com.apple.security.network.server` nem `network.client`. A fase 2 precisa dos dois, e de uma nova revisão da App Sandbox.
7. **Bitrate.** 1080p60 limpo de jogo fica na casa de 8–15 Mbit/s. Wi-Fi 5 GHz ou cabo. 2,4 GHz fica como pergunta, não como plano.
8. **HDCP.** Só sai o que o console já entregou desprotegido. Não há plano de furar proteção.
9. **Onde mora o código.** No processo do CapturaPlay, como sink. Um processo auxiliar copiaria o frame de novo.

A página da TV (webOS / Tizen / browser) não faz parte deste repositório.

## O que este ambiente verificou

O ambiente em que o projeto foi escrito é Linux. Ele não compila target macOS e não abre câmera.

Rodou aqui:

- `flutter analyze` no app e no plugin
- `flutter test` no app e no plugin (escolha de dispositivo e formato, textos, decodificação do estado nativo, controlador com um cliente falso, e a tela sem hardware)

Ainda precisa de um Mac de verdade:

- `flutter run -d macos` e `flutter build macos` no Xcode
- diálogo de câmera e microfone, e o app sandboxed enxergando o Cam Link
- 1080p60 de fato, aspecto da imagem, áudio sem estalo e sincronia
- tela cheia, cursor, volume, mudo, sono da tela
- o número da latência com o Cam Link ligado, com a sobreposição ligada e desligada
- OBS capturando a janela enquanto o CapturaPlay segura o USB, e o erro quando o OBS segura o USB primeiro
