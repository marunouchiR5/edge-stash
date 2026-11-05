import AppKit
import ApplicationServices

/// Thin wrapper over an Accessibility window element of another app.
struct AXWindow {
    let element: AXUIElement
    let pid: pid_t

    /// Current frame in AX coordinates, or nil if the window is gone.
    var frame: CGRect? {
        guard let posValue = Self.copy(element, kAXPositionAttribute),
              let sizeValue = Self.copy(element, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    var title: String { Self.copy(element, kAXTitleAttribute) as? String ?? "" }

    @discardableResult
    func setOrigin(_ point: CGPoint) -> Bool {
        var p = point
        guard let value = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success
    }

    @discardableResult
    func setSize(_ size: CGSize) -> Bool {
        var s = size
        guard let value = AXValueCreate(.cgSize, &s) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) == .success
    }

    /// Brings this window to the front of its app and makes it the main window.
    func raise() {
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    func isSame(as other: AXWindow) -> Bool { CFEqual(element, other.element) }

    // MARK: - Lookup

    /// Standard, non-minimized windows of an app.
    static func windows(pid: pid_t) -> [AXWindow] {
        let app = AXUIElementCreateApplication(pid)
        guard let list = copy(app, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        return list.compactMap { el in
            guard copy(el, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole as String,
                  copy(el, kAXMinimizedAttribute) as? Bool != true else { return nil }
            return AXWindow(element: el, pid: pid)
        }
    }

    /// The window the user most likely means: focused, then main, then the first one.
    static func preferred(pid: pid_t) -> AXWindow? {
        let all = windows(pid: pid)
        let app = AXUIElementCreateApplication(pid)
        for attr in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let el = copy(app, attr), CFGetTypeID(el) == AXUIElementGetTypeID() {
                let w = AXWindow(element: el as! AXUIElement, pid: pid)
                if all.contains(where: { $0.isSame(as: w) }) { return w }
            }
        }
        return all.first
    }

    static func focusedWindow(pid: pid_t) -> AXWindow? {
        let app = AXUIElementCreateApplication(pid)
        guard let el = copy(app, kAXFocusedWindowAttribute), CFGetTypeID(el) == AXUIElementGetTypeID() else { return nil }
        return AXWindow(element: el as! AXUIElement, pid: pid)
    }

    /// Makes an app frontmost. Uses AX because `NSRunningApplication.activate()` from a
    /// background agent is subject to cooperative activation and may be ignored.
    static func activate(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    private static func copy(_ el: AXUIElement, _ attr: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success ? value : nil
    }
}
