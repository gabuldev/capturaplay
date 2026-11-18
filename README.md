# CapturaPlay

A macOS app for playing games by looking at a USB (UVC) capture card, in this case an Elgato Cam Link 4K, with the lowest latency AVFoundation can deliver. The video fills the window. The capture card's audio goes to your speakers or headphones.

There is no splitter in between. HDMI leaves the console, goes into the Cam Link, and the USB goes into the Mac. This window is the screen.

The app bundle is called `capturaplay.app`. The name in the Dock and on the window is **CapturaPlay**.

## Why the preview takes this path

The image does not go through Flutter's texture registry.

`AVCaptureVideoPreviewLayer` is the preview Apple draws inside the capture session itself. On macOS, Flutter embeds platform views through hybrid composition: the `NSView` really enters the window hierarchy, and the layer updates on AVFoundation's clock, not on Impeller's next frame. Pushing `CVPixelBuffer`s through `FlutterTexture` would require an `AVCaptureVideoDataOutput`, at least one extra frame, and handing the buffer over on the raster thread.

That is why the preview is the backing layer of an `NSView` (`PreviewHostView`). The `CapturePreview` widget must not get a clip, opacity or transform: any of those makes Flutter recomposite the native view and brings back the latency this path avoids.

Audio goes through `AVCaptureAudioPreviewOutput`, straight to the system's default output. There is no buffer on the app side. The audio runs in its own `AVCaptureSession`: with the audio preview output in the same session as the video, the picture waited for the audio and the preview lagged noticeably. The size of AVFoundation's internal buffer is not public; if it seems too large on some Mac, the phase 2 hook is the place for a Core Audio tap with a short buffer.

Capture and display are separate. `CaptureEngine` owns the `AVCaptureSession`. The layer only receives the session. Video buffers (NV12 backed by IOSurface, when there is a consumer) and audio buffers (PCM) only leave through `CaptureMediaSink`, and the data outputs only join the session while a sink exists — or while the stats overlay is on. Playing does not pay for an encoder that isn't running.

The overlay (`I` key) turns on a data output that only counts frames. The latency number is the difference between the sample's PTS and the session clock at the moment that tap receives the buffer. It is an estimate of the capture pipeline, and an upper bound for the preview, which usually arrives a little earlier. A negative value or one above 2 s shows as "—": the clocks didn't line up. Turn the overlay off to go back to the minimal path.

While the session is open, the process requests `idleDisplaySleepDisabled`. The display doesn't sleep. Closing the lid can still suspend the Mac.

## Requirements

- A Mac running macOS 14 or later
- Current Xcode, with the command line tools
- Flutter stable (the project currently builds with Flutter 3.50.0 and Dart 3.14)
- A UVC capture card. The app picks a device whose name contains "Cam Link" on its own
- A USB 3, USB 4 or Thunderbolt port directly on the Mac

This repository's Flutter setup uses Swift Package Manager for the plugin, which is the default on current stable. If your local Flutter has it turned off:

```bash
flutter config --enable-swift-package-manager
```

## Build and run

From the repository root:

```bash
flutter pub get
flutter run -d macos
```

Release:

```bash
flutter build macos
open build/macos/Build/Products/Release/capturaplay.app
```

On first launch the system asks for camera and microphone access. Both permissions belong to the capture card: the video comes in as a USB camera and the sound comes in as an audio input. It is not the Mac's microphone, unless you pick it in the bar.

Strings in `Info.plist`:

- `NSCameraUsageDescription`
- `NSMicrophoneUsageDescription`

Sandbox, in the Debug and Release entitlements:

- `com.apple.security.device.camera`
- `com.apple.security.device.audio-input`

To check the binary:

```bash
codesign -d --entitlements :- build/macos/Build/Products/Release/capturaplay.app
```

If the dialog doesn't appear, open System Settings → Privacy & Security → Camera and Microphone, and allow CapturaPlay. The "Open System Settings" button on the permission screen tries to open that pane.

The last choice of video, audio, format, volume and mute is stored in `UserDefaults`. The first time, with nothing remembered, the app picks the device with "Cam Link" in its name and 1920×1080 @ 60 fps, if the hardware offers it. The built-in microphone is never picked on its own.

If the Cam Link drops off USB and comes back, the app waits 1 s and reopens it by itself. If the session fails while the device is still connected, it retries up to 3 times in a row.

## Setting the console to 1080p without HDCP

For this use, the Cam Link 4K wants 1080p60 SDR. 4K on it is 30 fps. 120 Hz and VRR are not a stable mode for this card.

Cabling, with no splitter and no TV in the path:

1. Console HDMI out → Cam Link HDMI in.
2. Cam Link USB → a USB 3 port on the Mac, directly.

On the console:

1. Settings → Screen and Video → Video Output → Resolution → **1080p**.
2. 120 Hz Output → **Off**.
3. VRR → **Off**.
4. HDR → **Off**. The target here is 1080p SDR. HDR pushes a different mode and doesn't help latency.
5. Settings → System → HDMI → HDCP → **Off**.

Turning HDCP off is the console's own switch for capture. Without it the capture card receives a protected image and the window stays black or shows an error screen. Games keep working. Streaming apps on the console may refuse to open while HDCP is off; that is the console's expected behavior, not a bug in this app.

If the image doesn't lock to 1080p60, pick the format in the bar. The chip at the top shows the format the session actually activated.

## Using it together with OBS

A UVC device has one active video stream. On macOS, `UVCAssistant` holds the USB interface and apps talk to it through CoreMedia. In practice the Cam Link isn't stable with OBS and another `AVCaptureSession` at the same time: the second one fails, gets no frames, or both renegotiate the format and the image flickers. The `isInUseByAnotherApplication` property is no use as a sentinel — it flags an exclusive configuration lock, not "a session is open". Treat it as having a single owner.

The owner has to be this app. Whoever is playing looks at the `AVCaptureVideoPreviewLayer`. The delay of a window capture ends up in the stream, where OBS already holds a buffer. The other way around (OBS owning the Cam Link, and this app filming OBS's preview) puts that delay in front of the player.

```
console --HDMI--> Cam Link --USB--> CapturaPlay
                                      |  native preview (you play here)
                                      |  audio straight to the Mac's output
                                      v
                                    OBS captures the CapturaPlay WINDOW
                                      |
                                      v
                                    live stream / recording
```

In OBS:

1. Don't create a "Video Capture Device" source on the Cam Link. If one exists, delete it and restart OBS so it releases the USB device.
2. Add a **macOS Screen Capture** source, **Window Capture** mode, window **CapturaPlay**.
3. OBS will ask for Screen Recording permission. That is for OBS, not for this app.
4. Window capture keeps macOS notifications out of the stream. Full screen capture also works if CapturaPlay is full screen on a monitor of its own, but notifications and menus show up in the video.
5. Sound: the game plays on the Mac's default output. In OBS, include that screen capture's audio (macOS 13+) or a desktop audio source. Use headphones. Loud speakers plus a microphone re-record the game and cause echo.

Don't use OBS's virtual camera as the source for playing. It adds an encode in the path to your eyes.

If CapturaPlay says the device is in use, close the Cam Link source in OBS (or the other app) and click "Try again".

## Shortcuts

| Action | How |
| --- | --- |
| Full screen | `F`, double-click the image, or `⌘⌃F` (View menu) |
| Mute | `M` or the volume button |
| Volume | Slider, or `↑` / `↓` |
| Stats (fps and estimated latency) | `I` |
| Cursor | Hides with the bar after a moment without mouse movement, and comes back when you move it |

`Esc` leaves full screen, like any macOS window.

## Known limitations

- One app at a time on the Cam Link. See the OBS section.
- Content with HDCP on doesn't show. The switch is the console's.
- The app doesn't record. Streaming is LAN-only, to the iPhone receiver (see below).
- Real latency depends on the Cam Link, the USB port and macOS. The overlay number is an estimate from the stats tap, not an end-to-end photodiode measurement.
- The `AVCaptureAudioPreviewOutput` buffer has no public setting.
- The stats overlay adds a data output. Turn it off with `I` for the minimal path.
- Cam Link 4K: 1080p60 or 4K30, not 4K60.
- Platform views on macOS still have rough edges. Double-click depends on the `NSView` returning `nil` from hit testing. `F` and `⌘⌃F` don't depend on that.
- The display doesn't sleep during the session. Suspending via the lid is still possible.
- Game audio stays on the Mac. The iPhone only receives video.
- The UI is in Brazilian Portuguese.

## Where the code is

- `lib/` — UI (pt-BR), shortcuts, bar, state.
- `packages/captura_capture/` — testable Dart API (device and format selection, the network protocol) and the Swift plugin.
- `CaptureEngine.swift` — session, formats, audio, display sleep.
- `LanSender.swift` — H.264 and the LAN server. It only joins as a `CaptureMediaSink` while streaming is on.
- `CapturaReceiverPlugin.swift` — the iPhone receiver.
- `lib/src/lan_protocol.dart` — the byte format. The Swift side (`LanWire.swift`) has to match it.
- `packages/interop_lab/` — a lab comparing MethodChannel, Pigeon and direct FFI between Dart and Swift (see its README).

## Streaming to the iPhone

The same Flutter project becomes a receiver on the iPhone. On the Mac, with capture already running, click **Transmitir na rede** (stream on the network). The app advertises `_capturaplay._tcp` (Bonjour) and listens on TCP port **47731**. Video is hardware H.264 (VideoToolbox): real time, no B-frames. In **Suave** (smooth) pacing the profile is High (CABAC), the GOP is about 2 s, and an extra keyframe is only sent when a frame is dropped. **Ultra baixa latência** (ultra low latency) stays on Constrained Baseline, a 0.5 s GOP and a single send in flight. The default rate is 1080p at 20 Mb/s; the bar picks 10, 20 or 30 Mb/s and 720p or 1080p. The encoder no longer uses a 1-second cap that crushed the keyframe, and refuses a QP worse than 32 in Suave (38 in Ultra) when the system accepts `MaxAllowedFrameQP`.

The preview for the player on the Mac stays on `AVCaptureVideoPreviewLayer`. The encoder doesn't draw that preview. It only exists while streaming is on, on its own queue, and drops the frame if it is still busy with the previous one. Local audio doesn't change: it stays on `AVCaptureAudioPreviewOutput`. The iPhone has no sound. Audio in the stream is a deliberate TODO, so that path isn't touched.

On the iPhone (iOS 16 or later), with the phone and the Mac on the same Wi-Fi, no VPN and no client isolation on the router:

```bash
flutter pub get
flutter devices
flutter run -d <iphone-id>
```

The first time, Xcode asks for a signing team. Open `ios/Runner.xcworkspace` (or `ios/Runner.xcodeproj`, if your local Flutter uses Swift Package Manager), go to the Runner target → Signing & Capabilities, pick your Apple Team and set your bundle id. The iPhone has to trust the development profile in Settings → General → VPN & Device Management.

The app opens in landscape, without a status bar, and finds the Mac by itself. If Bonjour doesn't show up, type the Mac's IP. The local network permission must be accepted. Tap the image to see the stats (fps and estimated latency) and to disconnect. If the connection drops, it tries again. The display doesn't sleep while the receiver is open.

1080p in Ultra uses the High profile without B-frames and, when entering that pacing, drops to 12 Mb/s (10 Mb/s picked by hand stays). The native frame in 420v or BGRA isn't copied again before the encoder. 720p Ultra doesn't change profile or rate. The `1080p · último` line on the iPhone is the frame that just arrived; each stage's `p50/p95/max` stays in the summary.

**Latência** (latency) mode sends 720p at 15 Mb/s. **Qualidade** (quality) uses 1080p at 20 Mb/s. **Suave** pacing (the default) keeps two or three frames in flight so motion doesn't skip, and stays on TCP. **Ultra baixa latência** sends video over UDP (1200-byte chunks). A lost chunk expires in 8 ms and the iPhone asks for a keyframe right away; the Ultra GOP is about 8 frames so the image doesn't wait half a second. The phone only shows the newest decoded frame. Both sides send a small UDP packet every 4 ms and mark the traffic as interactive video (the class the system maps to DSCP), so the iPhone's radio doesn't sleep between 102.4 ms beacons. The encoder emits each frame immediately (`CompleteFrames`). On the iPhone, Suave releases each frame at its source PTS (59.94 or 60). The stats show p50/p95/max over the last 2 s, how many frames went over 50 ms, and which stage dominated. If `off` is much larger than `rtt`, the number includes clock offset.

Spikes of ~100 ms with the **rede** (network) stage on top line up with the Wi-Fi beacon or with the Mac's AWDL (AirDrop, Continuity, Sidecar). The app checks whether `awdl0` exists and warns in the bar, but doesn't turn it off: on the Mac that would be `sudo ifconfig awdl0 down`, and the interface comes back on its own. To play, turn AirDrop off and disconnect Sidecar. The Mac's Console logs `intervalo de envio` (send interval) when sending itself pauses for more than 50 ms.

The number on the iPhone, "captura → vidro" (capture → glass), runs from the moment the frame entered the sink on the Mac to the next vsync in which the iPhone presents it, with clocks aligned by an NTP-style ping. It isn't a photodiode. "Rede" (network) counts gaps in the sequence. "Tela" (display) counts frames that left the buffer without being shown. "Espera IDR" (IDR wait) counts what arrived while the decoder had no reference. In Suave, displayed fps should sit next to received fps. The Mac's Console shows the same breakdown (`category` `lan` on the Mac, `lan.recv` on the iPhone) about once per second.

The wire is TCP with `CPL1` messages: H.264 configuration (SPS/PPS, and at the end the rate in Mb/s and the QP cap) and frames in AVCC, with a 4-byte NAL length. The iPhone builds a `CMSampleBuffer` and hands it to an `AVSampleBufferDisplayLayer`, which decodes and displays without going through Flutter's texture. In Suave, a late frame waits for its PTS; it isn't thrown away just because it arrived early or the layer was busy. In Ultra, a frame that doesn't fit is dropped and the following P-frames wait for a keyframe. Only one device at a time: a new connection replaces the previous one.

Message type `0x30` is reserved for the iPhone's controller input going back to the Mac. The format is in `LanInputReport` and is tested. Nothing sends it yet.

Limits of this stream:

- No audio on the iPhone.
- 5 GHz Wi-Fi or Ethernet on the Mac. 2.4 GHz usually can't keep up with 1080p60.
- The macOS firewall may ask for permission the first time.
- Release needs `com.apple.security.network.server` and `network.client` (already in the entitlements) and `NSLocalNetworkUsageDescription` / `NSBonjourServices` in both Info.plist files.
- webOS / Tizen TVs and browsers are still out. The protocol isn't WebRTC.

## Tests

```bash
flutter analyze
flutter test
```

Run them in the app and in `packages/captura_capture`. They cover device and format selection, copy, decoding the native state, the controller against a fake client (including the automatic Cam Link recovery), the screen without hardware, and the network protocol framing.
