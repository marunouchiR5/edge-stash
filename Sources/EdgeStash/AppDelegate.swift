import AppKit
import ApplicationServices
import EdgeStashCore
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = StashEdge.allCases.map { StashSettings(edge: $0) }
    private lazy var controllers = settings.map { StashController(settings: $0) }
    private var statusItem: NSStatusItem!
    private var signalSources: [DispatchSourceSignal] = []

    private enum MenuAction {
        case toggle(StashEdge)
        case app(StashEdge, String)
        case window(StashEdge, AXWindow)
        case width(StashEdge, WidthPreset)
        case keepVisible(StashEdge)
        case screen(StashEdge, StashScreenSelection)

        var edge: StashEdge {
            switch self {
            case .toggle(let edge), .app(let edge, _), .window(let edge, _), .width(let edge, _),
                 .keepVisible(let edge), .screen(let edge, _): return edge
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        for controller in controllers {
            controller.onChange = { [weak self] in self?.updateIcon() }
            controller.canManage = { [weak self, weak controller] window in
                guard let self, let controller else { return false }
                return !self.controllers.contains { $0 !== controller && $0.isManaging(window) }
            }
        }
        updateIcon()

        if !AXIsProcessTrusted() {
            // Shows the system prompt that links to Privacy & Security › Accessibility.
            // Literal value of kAXTrustedCheckOptionPrompt (the global isn't concurrency-safe in Swift 6).
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        controllers.forEach { $0.start() }
        installSignalHandlers()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controllers.forEach { $0.release() }
    }

    /// Restore the window when killed (`kill`, `pkill`, Ctrl-C) so it never stays stuck off screen.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.controllers.forEach { $0.release() } }
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }

    // MARK: - Status item

    private func updateIcon() {
        let symbol: String
        let active = controllers.filter { if case .stashed = $0.status { return true }; return false }
        let outside = controllers.filter(\.outsideCurrentStage)
        if controllers.contains(where: { $0.status == .needsPermission || $0.status == .blockedByStageManager }) {
            symbol = "exclamationmark.triangle"
        } else if !outside.isEmpty {
            symbol = "rectangle.stack.badge.plus"
        } else if active.count == 2 {
            symbol = "rectangle.split.3x1"
        } else if let controller = active.first {
            symbol = controller.settings.edge == .right ? "sidebar.right" : "sidebar.left"
        } else {
            symbol = "rectangle.dashed"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "EdgeStash")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = outside.isEmpty ? nil
            : outside.map { stageHint(for: $0) }.joined(separator: "\n")
    }

    private func stageHint(for controller: StashController) -> String {
        "Drag \(targetName(for: controller)) into the current Stage Manager group"
    }

    private func targetName(for controller: StashController) -> String {
        let settings = controller.settings
        if let app = controller.targetApp(), let name = app.localizedName { return name }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: settings.targetBundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return settings.targetBundleID
    }

    private func statusText(for controller: StashController) -> String {
        let targetName = targetName(for: controller)
        switch controller.status {
        case .disabled: return "Paused"
        case .needsPermission: return "Needs Accessibility permission"
        case .targetNotRunning: return "\(targetName) is not running"
        case .noWindow: return "\(targetName) has no open window"
        case .needsWindowSelection: return "Current window kept in place · choose another window"
        case .blockedByStageManager: return "Stage Manager is keeping this window in its thumbnail strip"
        case .targetScreenUnavailable: return "Selected display is disconnected · waiting to resume"
        case .stashed(_, let shown):
            return "\(targetName) \(shown ? "shown" : "stashed")"
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if controllers.contains(where: { $0.status == .needsPermission }) {
            menu.addItem(item("Grant Accessibility Access…", #selector(openAccessibilitySettings)))
            menu.addItem(.separator())
        }

        for controller in controllers {
            let name = controller.settings.edge == .left ? "Left Edge" : "Right Edge"
            let side = NSMenuItem(title: "\(name) · \(targetName(for: controller))", action: nil, keyEquivalent: "")
            side.submenu = sideMenu(for: controller)
            menu.addItem(side)
        }

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

    private func sideMenu(for controller: StashController) -> NSMenu {
        let settings = controller.settings
        let edge = settings.edge
        let targetName = targetName(for: controller)
        let menu = NSMenu()
        let header = NSMenuItem(title: statusText(for: controller), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if controller.outsideCurrentStage {
            for title in [stageHint(for: controller), "Until then, hovering switches to its group"] {
                let hint = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                hint.isEnabled = false
                menu.addItem(hint)
            }
        }
        if controller.status == .blockedByStageManager {
            let hint = NSMenuItem(title: "Try a different screen or Stage Manager group", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
            menu.addItem(item("Desktop & Dock Settings…", #selector(openDesktopSettings)))
        }
        menu.addItem(.separator())

        let pin = selectionItem("Pin \(targetName) to \(edge == .left ? "Left" : "Right") Edge", .toggle(edge))
        pin.state = settings.enabled ? .on : .off
        menu.addItem(pin)
        let keepVisible = selectionItem("Keep Visible", .keepVisible(edge))
        keepVisible.state = settings.keepVisible ? .on : .off
        menu.addItem(keepVisible)

        let screenItem = NSMenuItem(title: "Screen", action: nil, keyEquivalent: "")
        let screenMenu = NSMenu()
        screenMenu.autoenablesItems = false
        let automatic = selectionItem("Follow Pointer (All Displays)", .screen(edge, .followPointer))
        automatic.state = settings.screenSelection == .followPointer ? .on : .off
        screenMenu.addItem(automatic)
        screenMenu.addItem(.separator())
        let displays = StashDisplay.connected()
        for display in displays {
            let i = selectionItem(display.name, .screen(edge, display.selection))
            i.state = settings.screenSelection == display.selection ? .on : .off
            screenMenu.addItem(i)
        }
        if settings.screenSelection != .followPointer,
           !displays.contains(where: { settings.screenSelection.matches(uuid: $0.uuid, isBuiltIn: $0.isBuiltIn) }) {
            let missing = NSMenuItem(title: "Selected Display (Disconnected)", action: nil, keyEquivalent: "")
            missing.isEnabled = false
            missing.state = .on
            screenMenu.addItem(missing)
        }
        screenItem.submenu = screenMenu
        menu.addItem(screenItem)

        // Target app
        let appsItem = NSMenuItem(title: "App", action: nil, keyEquivalent: "")
        let apps = NSMenu()
        apps.autoenablesItems = false
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil
                && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .sorted { ($0.localizedName ?? "") .localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
        // Keep the configured app visible even when it is not running (e.g. Slack on first launch).
        if !running.contains(where: { $0.bundleIdentifier == settings.targetBundleID }) {
            let current = NSMenuItem(title: "\(targetName) (not running)", action: nil, keyEquivalent: "")
            current.state = .on
            current.isEnabled = false
            apps.addItem(current)
            apps.addItem(.separator())
        }
        for app in running {
            let id = app.bundleIdentifier!
            let i = selectionItem(app.localizedName ?? id, .app(edge, id))
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
        winMenu.autoenablesItems = false
        for (index, w) in windows.enumerated() {
            // Window titles can contain workspace names, conversations or document titles.
            // Bind the exact AX window instead of resolving an index again after the menu closes.
            let i = selectionItem("Window \(index + 1)", .window(edge, w))
            i.state = controller.isManaging(w) ? .on : .off
            i.isEnabled = controller.canManage?(w) ?? true
            winMenu.addItem(i)
        }
        winItem.submenu = winMenu
        winItem.isEnabled = !windows.isEmpty
        menu.addItem(winItem)

        // Width
        let widthItem = NSMenuItem(title: "Width", action: nil, keyEquivalent: "")
        let widthMenu = NSMenu()
        for preset in WidthPreset.allCases {
            var title = preset.title
            if let area = controller.areaWidth, let w = preset.width(forAreaWidth: area), preset != .minimum {
                title += " · \(Int(w)) pt"
            }
            let i = selectionItem(title, .width(edge, preset))
            i.state = settings.widthPreset == preset ? .on : .off
            widthMenu.addItem(i)
            if preset == .current { widthMenu.addItem(.separator()) }
        }
        widthItem.submenu = widthMenu
        menu.addItem(widthItem)

        return menu
    }

    private func selectionItem(_ title: String, _ selection: MenuAction) -> NSMenuItem {
        let i = item(title, #selector(performMenuAction(_:)))
        i.representedObject = selection
        return i
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openDesktopSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")!)
    }

    @objc private func performMenuAction(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? MenuAction,
              let controller = controllers.first(where: { $0.settings.edge == selection.edge }) else { return }
        let settings = controller.settings
        switch selection {
        case .toggle:
            settings.enabled.toggle()
            if !settings.enabled { controller.release() }
        case .app(_, let id):
            guard id != settings.targetBundleID else { return }
            controller.release()
            settings.targetBundleID = id
            settings.enabled = true
        case .window(_, let window):
            guard controller.canManage?(window) ?? true else { return }
            controller.stash(window)
        case .width(_, let preset):
            settings.widthPreset = preset
            controller.applyWidthPreset()
        case .keepVisible:
            settings.keepVisible.toggle()
        case .screen(_, let selection):
            settings.screenSelection = selection
            controller.applyScreenSelection()
        }
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
