import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Set self as delegate to intercept close
    self.delegate = self

    super.awakeFromNib()
  }

  // Intercept window close - hide instead of close
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    // Hide the window instead of closing
    self.orderOut(nil)
    return false
  }
}
