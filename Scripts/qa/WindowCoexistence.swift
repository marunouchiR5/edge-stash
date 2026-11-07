import AppKit
import ApplicationServices

// Tests the installed executable against known synthetic windows. AX reads are limited
// to these fixtures; no screenshot, real window title, or message data is collected.
let installed = CommandLine.arguments[1]
let directory = CommandLine.arguments[2]
let productID = "io.github.marunouchir5.EdgeStash"
let prefix = "io.github.marunouchir5.EdgeStash.QA."

func running(_ id: String) -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: id).first
}

func waitUntil(_ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        if condition() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    return false
}

func stop(_ id: String) {
    guard let app = running(id) else { return }
    kill(app.processIdentifier, SIGTERM)
    _ = waitUntil { running(id) == nil }
}

func launch(_ path: String, args: [String] = [], background: Bool = true) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = (background ? ["-g"] : []) + ["-n", path] + (args.isEmpty ? [] : ["--args"] + args)
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 { throw Failure.failed("could not launch test app") }
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func appElement(_ id: String) -> AXUIElement {
    AXUIElementCreateApplication(running(id)!.processIdentifier)
}

func windows(_ id: String) -> [AXUIElement] {
    (attribute(appElement(id), kAXWindowsAttribute) as? [AXUIElement] ?? []).filter {
        attribute($0, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole as String
    }
}

func focused(_ id: String) -> AXUIElement? {
    guard let value = attribute(appElement(id), kAXFocusedWindowAttribute),
          CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

func frame(_ window: AXUIElement) -> CGRect? {
    guard let position = attribute(window, kAXPositionAttribute),
          let size = attribute(window, kAXSizeAttribute) else { return nil }
    var p = CGPoint.zero, s = CGSize.zero
    AXValueGetValue(position as! AXValue, .cgPoint, &p)
    AXValueGetValue(size as! AXValue, .cgSize, &s)
    return CGRect(origin: p, size: s)
}

enum Failure: Error { case failed(String) }
func require(_ value: Bool, _ message: String) throws {
    if !value { throw Failure.failed(message) }
}

let wasRunning = running(productID) != nil
var succeeded = false
do {
    try require(AXIsProcessTrusted(), "test runner needs Accessibility access")
    stop(productID)
    for role in ["Left", "Right", "Main"] {
        try launch("\(directory)/\(role).app", background: role != "Main")
        try require(waitUntil { running(prefix + role.lowercased()) != nil }, "fixture did not launch")
    }
    let mainID = prefix + "main"
    try require(waitUntil { running(mainID)?.isActive == true }, "synthetic current app did not activate")
    try require(waitUntil { focused(mainID).flatMap(frame) != nil && windows(mainID).count == 3 },
                "synthetic current window did not finish opening")
    guard let current = focused(mainID), let original = frame(current) else {
        throw Failure.failed("synthetic current window is unavailable")
    }
    let mainPID = running(mainID)!.processIdentifier
    func currentIsPreserved() -> Bool {
        let appPreserved = NSWorkspace.shared.frontmostApplication?.processIdentifier == mainPID
        let windowPreserved = focused(mainID).map { CFEqual($0, current) } ?? false
        let framePreserved = frame(current) == original
        if !appPreserved || !windowPreserved || !framePreserved {
            print("Synthetic current app preserved: \(appPreserved), focused window preserved: \(windowPreserved), frame preserved: \(framePreserved)")
        }
        return appPreserved && windowPreserved && framePreserved
    }
    let screen = NSScreen.screens[0]
    let area = CGRect(x: screen.visibleFrame.minX, y: screen.frame.height - screen.visibleFrame.maxY,
                      width: screen.visibleFrame.width, height: screen.visibleFrame.height)
    func atLeft(_ rect: CGRect) -> Bool { abs(rect.minX - area.minX) < 3 }
    func atRight(_ rect: CGRect) -> Bool { abs(rect.maxX - area.maxX) < 3 }
    func start(left: String, right: String, visible: Bool) throws {
        try launch(installed, args: [
            "-independentEdgesV1", "YES", "-left.enabled", "YES", "-right.enabled", "YES",
            "-left.targetBundleID", left, "-right.targetBundleID", right,
            "-left.widthPreset", "current", "-right.widthPreset", "current",
            "-left.screenSelection", "followPointer", "-right.screenSelection", "followPointer",
            "-left.keepVisible", visible ? "YES" : "NO", "-right.keepVisible", visible ? "YES" : "NO",
        ])
        try require(waitUntil { running(productID) != nil }, "installed app did not launch")
    }
    try start(left: mainID, right: mainID, visible: false)
    RunLoop.current.run(until: Date().addingTimeInterval(1.5))
    try require(currentIsPreserved(), "automatic discovery moved or replaced the current window")
    print("PASS: automatic discovery leaves the currently focused window in place")
    stop(productID)
    try start(left: prefix + "left", right: prefix + "right", visible: true)
    try require(waitUntil {
        guard let left = windows(prefix + "left").first.flatMap(frame),
              let right = windows(prefix + "right").first.flatMap(frame) else { return false }
        return atLeft(left) && atRight(right)
    }, "different-app side windows did not both appear at their edges")
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    try require(currentIsPreserved(), "different-app reveal changed the current app, window or frame")
    print("PASS: two different apps shown at the edges; current app, focused window and frame preserved")
    stop(productID)
    try require(currentIsPreserved(), "exit changed the current app or window")
    print("PASS: exit restores both side windows without switching the current window")

    try start(left: mainID, right: mainID, visible: true)
    try require(waitUntil {
        let spareFrames = windows(mainID).filter { !CFEqual($0, current) }.compactMap(frame)
        return spareFrames.contains(where: atLeft) && spareFrames.contains(where: atRight)
    }, "two spare windows of one app did not reach separate edges")
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    try require(currentIsPreserved(), "same-app discovery moved or replaced the current window")
    print("PASS: two different windows of one app shown at opposite edges; current window preserved")
    stop(productID)
    succeeded = true
} catch {
    print("FAIL: \(error)")
}
stop(productID)
for role in ["main", "left", "right"] { stop(prefix + role) }
if wasRunning { try? launch(installed) }
exit(succeeded ? 0 : 1)
