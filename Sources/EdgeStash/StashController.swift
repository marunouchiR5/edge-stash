import AppKit
import ApplicationServices
import EdgeStashCore
import QuartzCore

/// Keeps one window of the target app stashed past a screen edge and slides it in/out.
@MainActor
final class StashController {
    enum Status: Equatable {
        case disabled
        case needsPermission
        case targetNotRunning
        case noWindow
        case needsWindowSelection
        case blockedByStageManager
        case targetScreenUnavailable
        case stashed(screen: String, shown: Bool)
    }

    private(set) var status: Status = .disabled {
        didSet { if status != oldValue { onChange?() } }
    }
    /// The pinned window sits in Stage Manager's strip, outside the current group, so a hover
    /// reveal will switch groups instead of showing it next to the current window.
    private(set) var outsideCurrentStage = false {
        didSet { if outsideCurrentStage != oldValue { onChange?() } }
    }
    var onChange: (() -> Void)?
    let settings: StashSettings
    private let mouseLocation: @MainActor () -> CGPoint
    private let displayProvider: @MainActor () -> [StashDisplay]
    /// Prevents two controllers from acquiring the same window, including after external defaults edits.
    var canManage: ((AXWindow) -> Bool)?

    private struct Managed {
        var window: AXWindow
        var size: CGSize
        var y: CGFloat
        var screen: CGRect      // full screen frame, AX coords
        var area: CGRect        // visible frame (minus menu bar / Dock), AX coords
        var screenName: String
        var displayID: UInt32
        var edge: StashEdge
        var lastHiddenOrigin: CGPoint?
    }

    private struct Animation {
        var from: CGPoint
        var to: CGPoint
        var start: CFTimeInterval
        var duration: CFTimeInterval
        var raiseWhenFinished: Bool
    }

    private var managed: Managed?
    private var protectedWindows: [AXWindow] = []
    /// Shared by both sides so that moving from one side to the other restores the app
    /// the user was working in, not the side app activated by the other hover.
    private static var previousFrontmostPID: pid_t?
    private static var hoverActivatedPID: pid_t?
    private var policy = StashPolicy()
    private var animation: Animation?
    private var currentOrigin = CGPoint.zero
    private var timer: Timer?
    private var fastTimer = false
    private var pointerWasAtEdge = false
    private var trusted = false
    private var nextTrustCheck: CFTimeInterval = 0
    private var mouseMonitor: Any?
    private var nextAcquire: CFTimeInterval = 0
    private var nextValidate: CFTimeInterval = 0
    private var nextStageCheck: CFTimeInterval = 0
    private var observers: [NSObjectProtocol] = []
    private var dragStartedInWindow = false
    private var userDraggedWindow = false
    private var visibilityCheckAt: CFTimeInterval?
    private var suspendedForDisplay = false

    private var displays: [StashDisplay] { displayProvider() }

    init(settings: StashSettings, mouseLocation: @escaping @MainActor () -> CGPoint = { NSEvent.mouseLocation },
         displayProvider: @escaping @MainActor () -> [StashDisplay] = { StashDisplay.connected() }) {
        self.settings = settings
        self.mouseLocation = mouseLocation
        self.displayProvider = displayProvider
    }

    // MARK: - Lifecycle

    func start() {
        guard timer == nil else { return }
        scheduleTimer(fast: false)
        // Pointer movement wakes us immediately, so the idle timer can stay slow.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                       .rightMouseDragged, .otherMouseDragged]) { event in
            MainActor.assumeIsolated {
                self.trackDrag(event)
                if !self.fastTimer { self.tick() }
            }
        }

        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                        object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            MainActor.assumeIsolated { self.appActivated(pid: pid) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            // Keep the exact chosen window and policy when a display changes.
            MainActor.assumeIsolated { self.refreshDisplay() }
        })
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        fastTimer = false
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        release()
    }

    /// Puts the managed window back on screen (slid out) and stops managing it.
    func release() {
        animation = nil
        visibilityCheckAt = nil
        suspendedForDisplay = false
        if let m = managed {
            m.window.setOrigin(shownOrigin(m))
        }
        managed = nil
        outsideCurrentStage = false
        policy.reset()
        dragStartedInWindow = false
        userDraggedWindow = false
        nextAcquire = 0
        status = .disabled
    }

    /// Stash a specific window chosen by the user.
    func stash(_ window: AXWindow) {
        release()
        protectedWindows.removeAll { $0.isSame(as: window) }
        settings.enabled = true
        adopt(window)
    }

    /// Usable width of the screen the window is stashed on (for menu labels).
    var areaWidth: CGFloat? { managed?.area.width }

    func applyScreenSelection() { refreshDisplay() }

    /// Resizes the managed window to the selected width preset, keeping it anchored to the edge.
    func applyWidthPreset() {
        animation = nil
        resizeToPreset(anchorShown: policy.state != .hidden)
    }

    /// macOS won't let an on-screen window grow past the screen edge, so the window is first moved
    /// to where it will sit with the new width, then resized, then re-anchored with the size the
    /// app actually accepted (apps clamp to their own minimum width).
    private func resizeToPreset(anchorShown: Bool) {
        guard let m = managed, let width = settings.widthPreset.width(forAreaWidth: m.area.width) else { return }
        let anchor = { (m: Managed) in anchorShown ? self.shownOrigin(m) : self.hiddenOrigin(m) }
        managed?.size.width = width
        m.window.setOrigin(anchor(managed!))
        m.window.setSize(managed!.size)
        if let actual = m.window.frame?.size { managed?.size = actual }
        let origin = anchor(managed!)
        m.window.setOrigin(origin)
        currentOrigin = m.window.frame?.origin ?? origin
        if !anchorShown { managed?.lastHiddenOrigin = m.window.frame?.origin }
    }

    func targetWindows() -> [AXWindow] {
        guard let app = targetApp() else { return [] }
        return AXWindow.windows(pid: app.processIdentifier)
    }

    func isManaging(_ window: AXWindow) -> Bool {
        managed.map { $0.window.isSame(as: window) } ?? false
    }

    func targetApp() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: settings.targetBundleID).first
    }

    // MARK: - Tick

    /// 60 Hz while something is happening (pointer on the edge, window out, animating), 10 Hz otherwise.
    private func scheduleTimer(fast: Bool) {
        timer?.invalidate()
        let t = Timer(timeInterval: fast ? 1.0 / 60.0 : 1.0 / 10.0, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        fastTimer = fast
    }

    private func tick() {
        let now = CACurrentMediaTime()
        defer {
            let wantFast = animation != nil || policy.state != .hidden || pointerWasAtEdge
            if wantFast != fastTimer { scheduleTimer(fast: wantFast) }
        }
        stepAnimation(now)
        if let check = visibilityCheckAt, now >= check, let m = managed, policy.state != .hidden {
            if StageManager.isEnabled, !m.window.isVisibleAtCurrentFrame() {
                status = .blockedByStageManager
                visibilityCheckAt = now + 1
            } else {
                status = .stashed(screen: m.screenName, shown: true)
                visibilityCheckAt = nil
            }
        }
        pointerWasAtEdge = false
        if now >= nextTrustCheck {
            trusted = AXIsProcessTrusted()
            nextTrustCheck = now + 1
        }

        guard settings.enabled else {
            if managed != nil { release() }
            status = .disabled
            return
        }
        guard trusted else {
            managed = nil
            status = .needsPermission
            return
        }
        guard synchronizeSelectedDisplay() else { return }
        guard managed != nil else {
            outsideCurrentStage = false
            if now >= nextAcquire { acquire(); nextAcquire = now + 1 }
            return
        }
        if managed!.edge != settings.edge { release(); return }
        if now >= nextValidate {
            nextValidate = now + 0.25
            validate()
            guard managed != nil else { return }
        }
        if now >= nextStageCheck, animation == nil {
            nextStageCheck = now + 1
            let window = managed!.window
            // Stages beyond the strip's capacity go to an overflow area that has no tiles, so
            // a window that isn't rendered at its own frame counts as outside the group too.
            outsideCurrentStage = StageManager.isEnabled
                && (window.windowID.map { StageManager.stripWindowIDs().contains($0) } == true
                    || !window.isVisibleAtCurrentFrame())
        }

        let m = managed!
        let mouse = StashGeometry.axPoint(fromCocoa: mouseLocation(), primaryHeight: primaryHeight)
        let shownFrame = CGRect(origin: shownOrigin(m), size: m.size).insetBy(dx: -8, dy: -8)
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        policy.revealDelay = settings.revealDelay
        policy.hideDelay = settings.hideDelay
        policy.keepVisible = settings.keepVisible
        let screens = displays
        let eligible = screens.filter { settings.screenSelection.matches(uuid: $0.uuid, isBuiltIn: $0.isBuiltIn) }
        let edgeDisplay = StashGeometry.edgeScreenIndex(for: mouse, screens: eligible.map(\.frame), edge: m.edge)
        let atEdge = policy.state == .hidden ? edgeDisplay != nil
            : StashGeometry.isAtEdge(mouse, screen: m.screen, edge: m.edge)
        pointerWasAtEdge = atEdge
        let action = policy.update(.init(
            now: now,
            pointerAtEdge: atEdge,
            pointerInWindow: shownFrame.contains(mouse),
            mouseButtonDown: NSEvent.pressedMouseButtons != 0,
            // Focus given by a hover reveal is ours, not the user's: it must not pin the window.
            targetIsFrontmost: frontPID == m.window.pid && Self.hoverActivatedPID != m.window.pid
                && AXWindow.focusedWindow(pid: m.window.pid)?.isSame(as: m.window) == true))
        if let action {
            if action == .reveal(.hover), let edgeDisplay {
                let target = eligible[edgeDisplay]
                if target.id != managed?.displayID { move(to: target, shown: false) }
            }
            perform(action)
        }
    }

    private func appActivated(pid: pid_t?) {
        guard let m = managed, pid == m.window.pid else { return }
        // Only react if the activation is about the stashed window, not another window of the app.
        guard AXWindow.focusedWindow(pid: m.window.pid)?.isSame(as: m.window) == true else { return }
        if let action = policy.targetActivated() { perform(action) }
    }

    // MARK: - Actions

    private func perform(_ action: StashPolicy.Action) {
        guard let m = managed else { return }
        switch action {
        case .reveal(let reason):
            if reason == .hover && !settings.keepVisible {
                // A hover reveal activates the app like the original flow did: without it,
                // Stage Manager keeps a background app's window in its thumbnail strip.
                let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
                if front != Self.hoverActivatedPID { Self.previousFrontmostPID = front }
                Self.hoverActivatedPID = m.window.pid
                animate(to: shownOrigin(m))
                AXWindow.activate(pid: m.window.pid)
                m.window.raise()
                visibilityCheckAt = CACurrentMediaTime() + settings.animationDuration + 0.35
            } else {
                // Keep Visible must not steal focus; raise only once the window is on screen.
                animate(to: shownOrigin(m), raiseWhenFinished: true)
            }
            status = .stashed(screen: m.screenName, shown: true)

        case .hide:
            visibilityCheckAt = nil
            if animation == nil, let f = m.window.frame {
                managed?.size = f.size
                managed?.y = f.minY
            }
            animate(to: hiddenOrigin(managed!))
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if front == m.window.pid, Self.hoverActivatedPID == m.window.pid,
               let prev = Self.previousFrontmostPID, NSRunningApplication(processIdentifier: prev) != nil {
                AXWindow.activate(pid: prev)
            }
            if Self.hoverActivatedPID == m.window.pid { Self.hoverActivatedPID = nil }
            status = .stashed(screen: m.screenName, shown: false)
        }
    }

    private func acquire() {
        guard let app = targetApp() else { status = .targetNotRunning; return }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
        let focused = AXWindow.focusedWindow(pid: app.processIdentifier)
        // Keep this protection after the user switches apps; discovering a current window
        // must not silently turn it into a stash one second after it loses focus.
        protectedWindows.removeAll { $0.frame == nil }
        if frontmost, let focused, !protectedWindows.contains(where: { $0.isSame(as: focused) }) {
            protectedWindows.append(focused)
        }
        guard let window = AXWindow.preferred(pid: app.processIdentifier, eligible: { window in
            StashAcquisitionPolicy.mayAutomaticallyStash(
                available: (self.canManage?(window) ?? true)
                    && !self.protectedWindows.contains(where: { $0.isSame(as: window) }),
                appIsFrontmost: frontmost,
                windowIsFocused: focused.map { $0.isSame(as: window) })
        }) else {
            status = AXWindow.windows(pid: app.processIdentifier).isEmpty ? .noWindow : .needsWindowSelection
            return
        }
        adopt(window)
    }

    private func adopt(_ window: AXWindow) {
        guard canManage?(window) ?? true else { status = .noWindow; return }
        guard let frame = window.frame else { status = .noWindow; return }
        let screens = displays
        guard !screens.isEmpty else { status = .noWindow; return }
        let full = screens.map(\.frame)
        let originalIndex = StashGeometry.bestScreenIndex(for: frame, screens: full) ?? 0
        let idx: Int
        if settings.screenSelection == .followPointer {
            idx = originalIndex
        } else if let selected = screens.firstIndex(where: { settings.screenSelection.matches(uuid: $0.uuid, isBuiltIn: $0.isBuiltIn) }) {
            idx = selected
        } else {
            status = .targetScreenUnavailable
            return
        }
        let area = screens[idx].area
        let y = area.minY + max(0, frame.minY - screens[originalIndex].area.minY)
        managed = Managed(window: window, size: frame.size, y: y, screen: full[idx], area: area,
                          screenName: screens[idx].name, displayID: screens[idx].id, edge: settings.edge)
        currentOrigin = frame.origin
        dragStartedInWindow = false
        userDraggedWindow = false
        policy.reset()
        policy.keepVisible = settings.keepVisible
        resizeToPreset(anchorShown: true)   // resize in view, then slide away
        if settings.keepVisible {
            // Initial placement and subsequent reveals share the nonactivating action path.
            if let action = policy.update(.init(now: CACurrentMediaTime(), pointerAtEdge: false,
                                                pointerInWindow: false, mouseButtonDown: false,
                                                targetIsFrontmost: false)) { perform(action) }
        } else {
            animate(to: hiddenOrigin(managed!))
            status = .stashed(screen: screens[idx].name, shown: false)
        }
    }

    /// Detects closed windows, user drags (unstash) and resizes.
    private func validate() {
        guard let m = managed else { return }
        guard let frame = m.window.frame else {
            managed = nil
            policy.reset()
            status = .noWindow
            return
        }
        guard animation == nil, NSEvent.pressedMouseButtons == 0 else { return }

        switch policy.state {
        case .shown:
            defer { userDraggedWindow = false }
            if StashGeometry.distanceFromEdge(frame, area: m.area, edge: m.edge) > 40 {
                if userDraggedWindow {
                    managed = nil
                    policy.reset()
                    settings.enabled = false
                    status = .disabled
                } else {
                    // macOS / Stage Manager can reposition a background window. A system
                    // adjustment is not a user request to unpin it.
                    managed?.size = frame.size
                    m.window.setOrigin(shownOrigin(managed!))
                    currentOrigin = m.window.frame?.origin ?? shownOrigin(managed!)
                }
                return
            }
            managed?.size = frame.size
            managed?.y = frame.minY
            currentOrigin = frame.origin
        case .hidden:
            managed?.size = frame.size
            let expected = m.lastHiddenOrigin ?? hiddenOrigin(m)
            if abs(frame.minX - expected.x) > 2 || abs(frame.minY - expected.y) > 2 {
                // Something (the app itself, Mission Control, …) moved it back on screen.
                currentOrigin = frame.origin
                animate(to: hiddenOrigin(managed!))
            }
        }
    }

    // MARK: - Animation

    private func trackDrag(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            userDraggedWindow = false
            let point = StashGeometry.axPoint(fromCocoa: mouseLocation(), primaryHeight: primaryHeight)
            dragStartedInWindow = policy.state != .hidden && managed?.window.frame?.contains(point) == true
        case .leftMouseDragged:
            if dragStartedInWindow { userDraggedWindow = true }
        case .leftMouseUp:
            dragStartedInWindow = false
        default: break
        }
    }

    private func refreshDisplay() {
        guard synchronizeSelectedDisplay() else { return }
        guard let m = managed else { return }
        let screens = displays
        let fixed = settings.screenSelection == .followPointer ? nil
            : screens.firstIndex { settings.screenSelection.matches(uuid: $0.uuid, isBuiltIn: $0.isBuiltIn) }
        let index = fixed ?? screens.firstIndex { $0.id == m.displayID }
            ?? StashGeometry.bestScreenIndex(for: CGRect(origin: shownOrigin(m), size: m.size),
                                            screens: screens.map(\.frame))
            ?? screens.indices.first
        guard let index else { return }
        move(to: screens[index], shown: policy.state != .hidden)
    }

    /// A missing selected display pauses this side; it must never fall back to triggering
    /// on the built-in display. Keep the window identity so reconnecting resumes it.
    private func synchronizeSelectedDisplay() -> Bool {
        let screens = displays
        if settings.screenSelection != .followPointer {
            guard let selected = screens.first(where: { settings.screenSelection.matches(uuid: $0.uuid, isBuiltIn: $0.isBuiltIn) }) else {
                if !suspendedForDisplay {
                    animation = nil
                    visibilityCheckAt = nil
                    if let fallback = screens.first { move(to: fallback, shown: true) }
                    suspendedForDisplay = true
                }
                status = .targetScreenUnavailable
                return false
            }
            if let m = managed, suspendedForDisplay || m.displayID != selected.id {
                move(to: selected, shown: policy.state != .hidden)
            }
        } else if suspendedForDisplay, let m = managed, let display = screens.first(where: { $0.id == m.displayID }) {
            move(to: display, shown: policy.state != .hidden)
        }
        suspendedForDisplay = false
        return true
    }

    private func move(to display: StashDisplay, shown: Bool) {
        guard let m = managed else { return }
        animation = nil
        managed?.y = display.area.minY + max(0, m.y - m.area.minY)
        managed?.screen = display.frame
        managed?.area = display.area
        managed?.screenName = display.name
        managed?.displayID = display.id
        let target = shown ? shownOrigin(managed!) : hiddenOrigin(managed!)
        m.window.setOrigin(target)
        currentOrigin = m.window.frame?.origin ?? target
        resizeToPreset(anchorShown: shown)
        if !shown { managed?.lastHiddenOrigin = m.window.frame?.origin }
        status = .stashed(screen: display.name, shown: shown)
    }

    private func animate(to target: CGPoint, raiseWhenFinished: Bool = false) {
        animation = Animation(from: currentOrigin, to: target, start: CACurrentMediaTime(),
                              duration: max(0.001, settings.animationDuration), raiseWhenFinished: raiseWhenFinished)
        stepAnimation(CACurrentMediaTime())
    }

    private func stepAnimation(_ now: CFTimeInterval) {
        guard let a = animation, let m = managed else { animation = nil; return }
        let t = min(1, (now - a.start) / a.duration)
        let e = 1 - pow(1 - t, 3) // ease-out cubic
        let p = CGPoint(x: a.from.x + (a.to.x - a.from.x) * e, y: a.from.y + (a.to.y - a.from.y) * e)
        m.window.setOrigin(p)
        currentOrigin = p
        if t >= 1 {
            animation = nil
            if a.raiseWhenFinished {
                m.window.raiseWithoutActivating()
                visibilityCheckAt = now + 0.35
            }
            if policy.state == .hidden {
                // Record where macOS actually put it (it may clamp off-screen positions).
                managed?.lastHiddenOrigin = m.window.frame?.origin
            }
        }
    }

    // MARK: - Geometry

    private var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    private func shownOrigin(_ m: Managed) -> CGPoint {
        StashGeometry.shownOrigin(size: m.size, y: m.y, area: m.area, edge: m.edge)
    }

    private func hiddenOrigin(_ m: Managed) -> CGPoint {
        StashGeometry.hiddenOrigin(size: m.size, y: m.y, screen: m.screen, area: m.area,
                                   edge: m.edge, peek: settings.peek)
    }
}
