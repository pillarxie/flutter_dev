import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.title = "Flutter Dev"
    self.styleMask.insert(.resizable)
    self.contentMinSize = NSSize(width: 560, height: 500)
    if let screen = NSScreen.main {
      self.setContentSize(NSSize(width: min(1280, screen.visibleFrame.width),
                                 height: min(800, screen.visibleFrame.height - 40)))
      self.center()
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
