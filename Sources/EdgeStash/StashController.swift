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
        case stashed(screen: String, shown: Bool)
    }

    private(set) var status: Status = .disabled {
        didSet { if status != oldValue { onChange?() } }
    }
    var onChange: (() -> Void)?
    let settings: Settings

    private struct Managed {
        var window: AXWindow
        var size: CGSize
        var y: CGFloat
        var screen: CGRect      // full screen frame, AX coords
        var area: CGRect        // visible frame (minus menu bar / Dock), AX coords
        var screenName: String
        var edge: StashEdge
        var lastHiddenOrigin: CGPoint?
    }

    private struct Animation {
        var from: CGPoint
        var to: CGPoint
        var start: CFTimeInterval
        var duration: CFTimeInterval
    }

    private var managed: Managed?
    private var policy = StashPolicy()
    private var animation: Animation?
    private var currentOrigin = CGPoint.zero
    private var previousFrontmostPID: pid_t?
    private var timer: Timer?
    private var fastTimer = false
    private var pointerWasAtEdge = false
    private var trusted = false
    private var nextTrustCheck: CFTimeInterval = 0
    private var mouseMonitor: Any?
    private var nextAcquire: CFTimeInterval = 0
    private var nextValidate: CFTimeInterval = 0
    private var observers: [NSObjectProtocol] = []

    init(settings: Settings) {
        self.settings = settings
    }

    // MARK: - Lifecycle

    func start() {
        scheduleTimer(fast: false)
        // Pointer movement wakes us immediately, so the idle timer can stay slow.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { _ in
            MainActor.assumeIsolated { if !self.fastTimer { self.tick() } }
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
            // Screens moved or resized: put the window back and re-stash with fresh geometry.
            MainActor.assumeIsolated { self.release() }
        })
    }

    /// Puts the managed window back on screen (slid out) and stops managing it.
    func release() {
        animation = nil
        if let m = managed {
            m.window.setOrigin(shownOrigin(m))
        }
        managed = nil
        policy.reset()
        nextAcquire = 0
    }

    /// Stash a specific window chosen by the user.
    func stash(_ window: AXWindow) {
        release()
        settings.enabled = true
        adopt(window)
    }

    /// Usable width of the screen the window is stashed on (for menu labels).
    var areaWidth: CGFloat? { managed?.area.width }

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
        currentOrigin = origin
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
        guard managed != nil else {
            if now >= nextAcquire { acquire(); nextAcquire = now + 1 }
            return
        }
        if managed!.edge != settings.edge { release(); return }
        if now >= nextValidate {
            nextValidate = now + 0.25
            validate()
            guard managed != nil else { return }
        }

        let m = managed!
        let mouse = StashGeometry.axPoint(fromCocoa: NSEvent.mouseLocation, primaryHeight: primaryHeight)
        let shownFrame = CGRect(origin: shownOrigin(m), size: m.size).insetBy(dx: -8, dy: -8)
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        policy.revealDelay = settings.revealDelay
        policy.hideDelay = settings.hideDelay
        let atEdge = StashGeometry.isAtEdge(mouse, screen: m.screen, edge: m.edge)
        pointerWasAtEdge = atEdge
        let action = policy.update(.init(
            now: now,
            pointerAtEdge: atEdge,
            pointerInWindow: shownFrame.contains(mouse),
            mouseButtonDown: NSEvent.pressedMouseButtons != 0,
            targetIsFrontmost: frontPID == m.window.pid))
        if let action { perform(action) }
    }

    private func appActivated(pid: pid_t?) {
        guard let m = managed, pid == m.window.pid else { return }
        // Only react if the activation is about the stashed window, not another window of the app.
        if let focused = AXWindow.focusedWindow(pid: m.window.pid), !focused.isSame(as: m.window) { return }
        if let action = policy.targetActivated() { perform(action) }
    }

    // MARK: - Actions

    private func perform(_ action: StashPolicy.Action) {
        guard let m = managed else { return }
        switch action {
        case .reveal(let reason):
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if front != m.window.pid { previousFrontmostPID = front }
            animate(to: shownOrigin(m))
            if reason == .hover { AXWindow.activate(pid: m.window.pid) }
            m.window.raise()
            status = .stashed(screen: m.screenName, shown: true)

        case .hide:
            if animation == nil, let f = m.window.frame {
                managed?.size = f.size
                managed?.y = f.minY
            }
            animate(to: hiddenOrigin(managed!))
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if front == m.window.pid, let prev = previousFrontmostPID,
               NSRunningApplication(processIdentifier: prev) != nil {
                AXWindow.activate(pid: prev)
            }
            status = .stashed(screen: m.screenName, shown: false)
        }
    }

    private func acquire() {
        guard let app = targetApp() else { status = .targetNotRunning; return }
        guard let window = AXWindow.preferred(pid: app.processIdentifier) else { status = .noWindow; return }
        adopt(window)
    }

    private func adopt(_ window: AXWindow) {
        guard let frame = window.frame else { status = .noWindow; return }
        let screens = NSScreen.screens
        let full = screens.map { StashGeometry.axRect(fromCocoa: $0.frame, primaryHeight: primaryHeight) }
        let idx = StashGeometry.bestScreenIndex(for: frame, screens: full) ?? 0
        let area = StashGeometry.axRect(fromCocoa: screens[idx].visibleFrame, primaryHeight: primaryHeight)
        managed = Managed(window: window, size: frame.size, y: frame.minY, screen: full[idx], area: area,
                          screenName: screens[idx].localizedName, edge: settings.edge)
        currentOrigin = frame.origin
        policy.reset()
        resizeToPreset(anchorShown: true)   // resize in view, then slide away
        animate(to: hiddenOrigin(managed!))
        status = .stashed(screen: screens[idx].localizedName, shown: false)
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
            if StashGeometry.distanceFromEdge(frame, area: m.area, edge: m.edge) > 40 {
                // The user dragged the window away from the edge: stop pinning it.
                managed = nil
                policy.reset()
                settings.enabled = false
                status = .disabled
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

    private func animate(to target: CGPoint) {
        animation = Animation(from: currentOrigin, to: target, start: CACurrentMediaTime(),
                              duration: max(0.001, settings.animationDuration))
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
