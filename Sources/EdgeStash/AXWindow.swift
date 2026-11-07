import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

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

    /// Raising a sibling of the foreground window makes it key on macOS, even without
    /// activating the app. Move those siblings into view without raising them.
    func raiseWithoutActivating() {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != pid else { return }
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    func isSame(as other: AXWindow) -> Bool { CFEqual(element, other.element) }

    /// WindowServer ID, needed to match Stage Manager's strip entries. There is no public
    /// AX attribute for it; this private call is the one window managers commonly rely on.
    var windowID: CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(element, &id) == .success && id != 0 ? id : nil
    }

    /// Stage Manager may report a full-size AX frame while rendering only a thumbnail.
    /// Inspect scalar WindowServer metadata, without reading titles or capturing pixels.
    func isVisibleAtCurrentFrame() -> Bool {
        guard let expected = frame,
              let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return false }
        return list.contains { entry in
            guard entry[kCGWindowOwnerPID as String] as? Int32 == pid,
                  entry[kCGWindowLayer as String] as? Int == 0,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
            return abs(rect.minX - expected.minX) < 3 && abs(rect.minY - expected.minY) < 3
                && abs(rect.width - expected.width) < 3 && abs(rect.height - expected.height) < 3
        }
    }

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
    static func preferred(pid: pid_t, eligible: (AXWindow) -> Bool = { _ in true }) -> AXWindow? {
        let all = windows(pid: pid).filter(eligible)
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
