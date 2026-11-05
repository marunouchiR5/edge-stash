import AppKit
import ApplicationServices
import EdgeStashCore
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings()
    private lazy var controller = StashController(settings: settings)
    private var statusItem: NSStatusItem!
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        controller.onChange = { [weak self] in self?.updateIcon() }
        updateIcon()

        if !AXIsProcessTrusted() {
            // Shows the system prompt that links to Privacy & Security › Accessibility.
            // Literal value of kAXTrustedCheckOptionPrompt (the global isn't concurrency-safe in Swift 6).
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        controller.start()
        installSignalHandlers()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.release()
    }

    /// Restore the window when killed (`kill`, `pkill`, Ctrl-C) so it never stays stuck off screen.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.controller.release() }
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }

    // MARK: - Status item

    private func updateIcon() {
        let symbol: String
        switch controller.status {
        case .needsPermission: symbol = "exclamationmark.triangle"
        case .disabled, .targetNotRunning, .noWindow: symbol = "rectangle.dashed"
        case .stashed: symbol = settings.edge == .right ? "sidebar.right" : "sidebar.left"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "EdgeStash")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    private var targetName: String {
        if let app = controller.targetApp(), let name = app.localizedName { return name }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: settings.targetBundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return settings.targetBundleID
    }

    private var statusText: String {
        switch controller.status {
        case .disabled: return "Paused"
        case .needsPermission: return "Needs Accessibility permission"
        case .targetNotRunning: return "\(targetName) is not running"
        case .noWindow: return "\(targetName) has no open window"
        case .stashed(let screen, let shown):
            return "\(targetName) \(shown ? "shown" : "stashed") · \(settings.edge.rawValue) edge of \(screen)"
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if controller.status == .needsPermission {
            menu.addItem(item("Grant Accessibility Access…", #selector(openAccessibilitySettings)))
        }
        menu.addItem(.separator())

        let pin = item("Pin \(targetName) to Edge", #selector(toggleEnabled))
        pin.state = settings.enabled ? .on : .off
        menu.addItem(pin)

        // Target app
        let appsItem = NSMenuItem(title: "App", action: nil, keyEquivalent: "")
        let apps = NSMenu()
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil
                && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .sorted { ($0.localizedName ?? "") .localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
        for app in running {
            let i = item(app.localizedName ?? app.bundleIdentifier!, #selector(chooseApp(_:)))
            i.representedObject = app.bundleIdentifier
            i.state = app.bundleIdentifier == settings.targetBundleID ? .on : .off
            i.image = app.icon.map { icon in
                let copy = icon.copy() as! NSImage
                copy.size = NSSize(width: 16, height: 16)
                return copy
            }
            apps.addItem(i)
        }
        appsItem.submenu = apps
        menu.addItem(appsItem)

        // Window of the target app
        let windows = controller.targetWindows()
        let winItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let winMenu = NSMenu()
        for (index, w) in windows.enumerated() {
            let title = w.title.isEmpty ? "Window \(index + 1)" : w.title
            let i = item(String(title.prefix(60)), #selector(chooseWindow(_:)))
            i.tag = index
            i.state = controller.isManaging(w) ? .on : .off
            winMenu.addItem(i)
        }
        winItem.submenu = winMenu
        winItem.isEnabled = !windows.isEmpty
        menu.addItem(winItem)

        // Edge
        let edgeItem = NSMenuItem(title: "Edge", action: nil, keyEquivalent: "")
        let edgeMenu = NSMenu()
        for edge in StashEdge.allCases {
            let i = item(edge == .left ? "Left" : "Right", #selector(chooseEdge(_:)))
            i.representedObject = edge.rawValue
            i.state = settings.edge == edge ? .on : .off
            edgeMenu.addItem(i)
        }
        edgeItem.submenu = edgeMenu
        menu.addItem(edgeItem)

        menu.addItem(.separator())
        let login = item("Launch at Login", #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let about = NSMenuItem(title: "EdgeStash \(version)", action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)
        menu.addItem(item("Quit EdgeStash", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func toggleEnabled() {
        settings.enabled.toggle()
        if !settings.enabled { controller.release() }
    }

    @objc private func chooseApp(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, id != settings.targetBundleID else { return }
        controller.release()
        settings.targetBundleID = id
        settings.enabled = true
    }

    @objc private func chooseWindow(_ sender: NSMenuItem) {
        let windows = controller.targetWindows()
        guard windows.indices.contains(sender.tag) else { return }
        controller.stash(windows[sender.tag])
    }

    @objc private func chooseEdge(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let edge = StashEdge(rawValue: raw) else { return }
        controller.release()
        settings.edge = edge
        updateIcon()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Could not change Launch at Login"
            alert.runModal()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
