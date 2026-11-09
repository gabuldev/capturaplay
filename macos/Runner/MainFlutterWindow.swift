import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.title = "CapturaPlay"
    self.setContentSize(NSSize(width: 1280, height: 720))
    self.minSize = NSSize(width: 960, height: 540)
    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden
    self.styleMask.insert(.fullSizeContentView)
    self.collectionBehavior.insert(.fullScreenPrimary)
    self.isMovableByWindowBackground = true
    self.backgroundColor = NSColor(srgbRed: 0.047, green: 0.051, blue: 0.043, alpha: 1)
    self.appearance = NSAppearance(named: .darkAqua)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
