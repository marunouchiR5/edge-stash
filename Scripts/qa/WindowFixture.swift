import AppKit

// Self-contained native fixtures: never open user apps, documents or messages.
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let role = Bundle.main.infoDictionary?["QARole"] as? String ?? "Main"
let requestedScreen = Bundle.main.infoDictionary?["QAScreenIndex"] as? Int ?? 0
let area = NSScreen.screens[min(requestedScreen, NSScreen.screens.count - 1)].visibleFrame
var windows: [NSWindow] = []
let count = role == "Main" ? 3 : 1
for index in 0..<count {
    let size = index == count - 1 && role == "Main"
        ? NSSize(width: 580, height: 420) : NSSize(width: 360, height: 500)
    let rect = NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                      width: size.width, height: size.height)
    let window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
    window.title = "Synthetic \(role) \(index + 1)"
    window.minSize = NSSize(width: 280, height: 240)
    window.isReleasedWhenClosed = false
    let label = NSTextField(labelWithString: "Synthetic \(role) \(index + 1)\nNo personal data")
    label.alignment = .center
    label.frame = NSRect(x: 10, y: 150, width: size.width - 20, height: 70)
    label.autoresizingMask = [.width]
    window.contentView!.addSubview(label)
    window.makeKeyAndOrderFront(nil)
    windows.append(window)
}
final class FixtureDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if role == "Main" {
            app.activate(ignoringOtherApps: true)
            windows.last?.makeKeyAndOrderFront(nil)
        }
    }
}
let delegate = FixtureDelegate()
app.delegate = delegate
app.run()
