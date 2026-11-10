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
- O áudio do jogo fica no Mac. O iPhone recebe só vídeo.

## Onde está o código

- `lib/` — interface em pt-BR, atalhos, barra, estado.
- `packages/captura_capture/` — API Dart testável (escolha de dispositivo, formato e o protocolo da rede) e o plugin Swift.
- `CaptureEngine.swift` — sessão, formatos, áudio, sono da tela.
- `LanSender.swift` — H.264 e o servidor na LAN. Só entra como `CaptureMediaSink` enquanto a transmissão está ligada.
- `CapturaReceiverPlugin.swift` — receptor do iPhone.
- `lib/src/lan_protocol.dart` — o formato dos bytes. O Swift (`LanWire.swift`) tem de bater com ele.

## Transmitir para o iPhone

O mesmo projeto Flutter vira receptor no iPhone. No Mac, com a captura já rodando, toque em **Transmitir na rede**. O app anuncia `_capturaplay._tcp` (Bonjour) e escuta TCP na porta **47731**. O vídeo é H.264 em hardware (VideoToolbox): tempo real, sem frame B. No ritmo **Suave** o perfil é High (CABAC), o GOP fica em cerca de 2 s e um keyframe extra só sai quando um quadro é descartado. **Ultra baixa latência** continua em Constrained Baseline, GOP de 0,5 s e um único envio em voo. A taxa padrão é 1080p a 20 Mb/s; a barra escolhe 10, 20 ou 30 Mb/s e 720p ou 1080p. O encoder não usa mais um teto de 1 segundo que esmagava o keyframe, e recusa QP pior que 32 no Suave (38 no Ultra) quando o sistema aceita `MaxAllowedFrameQP`.

A prévia de quem joga no Mac continua no `AVCaptureVideoPreviewLayer`. O encoder não desenha essa prévia. Ele só existe com a transmissão ligada, numa fila própria, e descarta o quadro se ainda estiver ocupado com o anterior. O áudio local não muda: continua no `AVCaptureAudioPreviewOutput`. O iPhone fica sem som. Áudio no stream é um TODO de propósito, para não mexer nesse caminho.

No iPhone (Flutter 3.47.5, iOS 16 ou mais novo), o aparelho e o Mac na mesma Wi-Fi, sem VPN e sem isolamento de cliente no roteador:

```bash
flutter pub get
flutter devices
flutter run -d <id-do-iphone>
```

Na primeira vez o Xcode pede um time de assinatura. Abra `ios/Runner.xcworkspace` (ou `ios/Runner.xcodeproj`, se o Flutter local usar Swift Package Manager), no alvo Runner → Signing & Capabilities, escolha o seu Apple Team e deixe o bundle `dev.capturaplay.capturaplay`. O iPhone precisa confiar no perfil de desenvolvimento em Ajustes → Geral → VPN e gerenciamento de dispositivo.

O app abre deitado, sem barra de status, e procura o Mac sozinho. Se o Bonjour não aparecer, digite o IP do Mac. A permissão de rede local tem de ser aceita. Toque na imagem para ver os dados (fps e latência estimada) e para desconectar. Se a ligação cair, ele tenta de novo. A tela não apaga enquanto o receptor está aberto.

O modo **Latência** manda 720p a 15 Mb/s. **Qualidade** usa 1080p a 20 Mb/s. O ritmo **Suave** (padrão) deixa dois ou três quadros no caminho para o movimento não pular e continua em TCP. **Ultra baixa latência** manda o vídeo em UDP (pedaços de 1200 bytes). Um pedaço perdido expira em 8 ms e o iPhone pede um keyframe na hora; o GOP do Ultra é cerca de 8 quadros para a imagem não ficar esperando meio segundo. O telefone mostra só o quadro decodificado mais novo. Os dois lados mandam um UDP pequeno a cada 4 ms e marcam o tráfego como vídeo interativo (a classe que o sistema traduz em DSCP), para o rádio do iPhone não dormir entre beacons de 102,4 ms. O encoder solta cada quadro na hora (`CompleteFrames`). No iPhone o Suave solta cada quadro na hora do PTS de origem (59,94 ou 60). Os dados mostram p50/p95/max dos últimos 2 s, quantos quadros passaram de 50 ms e qual etapa dominou. Se `off` for muito maior que `rtt`, o número inclui o relógio.

Picos de ~100 ms com a etapa **rede** no topo batem com o beacon do Wi-Fi ou com o AWDL do Mac (AirDrop, Continuity, Sidecar). O app vê se `awdl0` existe e avisa na barra, mas não desliga isso: no Mac seria `sudo ifconfig awdl0 down`, e a interface volta sozinha. Para jogar, desligue o AirDrop e solte o Sidecar. O Console do Mac registra `intervalo de envio` quando o próprio envio pausa mais de 50 ms.

O número no iPhone, “captura → vidro”, vai do instante em que o quadro entrou no sink no Mac até o próximo vsync em que o iPhone o apresenta, com o relógio alinhado por um ping no estilo NTP. Não é fotodiodo. “Rede” conta buracos na sequência. “Tela” conta quadro que saiu do buffer sem ser mostrado. “Espera IDR” conta o que chegou enquanto o decoder estava sem referência. No Suave, fps na tela deve ficar ao lado dos fps que chegam. O Console do Mac mostra a mesma divisão (`category` `lan` no Mac, `lan.recv` no iPhone) cerca de uma vez por segundo.

O fio é TCP com mensagens `CPL1`: configuração H.264 (SPS/PPS, e no final a taxa em Mb/s e o teto de QP) e quadros em AVCC, com tamanho de NAL de 4 bytes. O iPhone monta um `CMSampleBuffer` e entrega para um `AVSampleBufferDisplayLayer`, que decodifica e mostra sem passar pela textura do Flutter. No Suave o quadro atrasado espera o PTS dele; não é jogado fora só porque chegou cedo ou a camada estava ocupada. No Ultra, o quadro que não cabe é descartado e os P-frames seguintes esperam um keyframe. Só um aparelho por vez: uma ligação nova substitui a anterior.

O tipo de mensagem `0x30` está reservado para o controle do iPhone voltar ao Mac. O formato está em `LanInputReport` e tem teste. Ninguém envia isso ainda.

Limites desta transmissão:

- Sem áudio no iPhone.
- Wi-Fi 5 GHz ou cabo no Mac. 2,4 GHz costuma não aguentar 1080p60.
- O firewall do macOS pode pedir permissão na primeira vez.
- Release precisa de `com.apple.security.network.server` e `network.client` (já estão nos entitlements) e de `NSLocalNetworkUsageDescription` / `NSBonjourServices` nos dois Info.plist.
- TV webOS / Tizen / browser continuam fora. O protocolo não é WebRTC.

## O que este ambiente verificou

O ambiente em que o projeto foi escrito é Linux. Ele não compila target macOS e não abre câmera.

Rodou aqui:

- `flutter analyze` no app e no plugin
- `flutter test` no app e no plugin (escolha de dispositivo e formato, textos, decodificação do estado nativo, controlador com um cliente falso, a tela sem hardware, e o enquadramento do protocolo da rede)

Ainda precisa de um Mac e de um iPhone de verdade:

- `flutter run -d macos` e `flutter build macos` no Xcode
- diálogo de câmera e microfone, e o app sandboxed enxergando o Cam Link
- 1080p60 de fato, aspecto da imagem, áudio sem estalo e sincronia
- tela cheia, cursor, volume, mudo, sono da tela
- o número da latência com o Cam Link ligado, com a sobreposição ligada e desligada
- OBS capturando a janela enquanto o CapturaPlay segura o USB, e o erro quando o OBS segura o USB primeiro
- `flutter run -d macos` com “Transmitir na rede” ligado, e `flutter run -d <iphone>` no mesmo Wi-Fi
- Bonjour, a permissão de rede local, a porta 47731, 1080p e 720p, e a latência estimada no telefone
- a prévia do Mac continuar lisa com a transmissão ligada
