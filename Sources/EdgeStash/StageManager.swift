import AppKit
import ApplicationServices

/// Read-only view of Stage Manager. There is no public API; the strip is exposed through the
/// WindowManager process's accessibility tree. Only window IDs are read, never titles.
enum StageManager {
    static var isEnabled: Bool {
        UserDefaults(suiteName: "com.apple.WindowManager")?.bool(forKey: "GloballyEnabled") == true
    }

    /// Windows shown as thumbnails in the strip, i.e. outside the current group of their display.
    static func stripWindowIDs() -> Set<CGWindowID> {
        guard let wm = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.WindowManager").first
        else { return [] }
        var ids = Set<CGWindowID>()
        for space in children(AXUIElementCreateApplication(wm.processIdentifier)) {
            for strip in children(space) where identifier(strip) == "sm.strip" {
                for item in children(strip) {
                    var value: AnyObject?
                    guard AXUIElementCopyAttributeValue(item, "AXWindowsIDs" as CFString, &value) == .success,
                          let numbers = value as? [NSNumber] else { continue }
                    ids.formUnion(numbers.map(\.uint32Value))
                }
            }
        }
        return ids
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func identifier(_ element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
