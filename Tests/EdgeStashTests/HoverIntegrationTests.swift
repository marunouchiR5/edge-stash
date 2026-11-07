import AppKit
import ApplicationServices
import Foundation
import Testing
import EdgeStashCore
@testable import EdgeStash

/// Real AX windows and the production timers/controller, with a deterministic pointer.
/// Opt in on a local macOS desktop: EDGESTASH_NATIVE_TESTS=1 swift test --filter HoverIntegrationTests
@Suite @MainActor struct HoverIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EDGESTASH_NATIVE_TESTS"] == "1"
                  && UserDefaults(suiteName: "com.apple.WindowManager")?.bool(forKey: "GloballyEnabled") == true))
    func configuredExternalDisplayKeepsBuiltInEdgesInactive() async throws {
        try #require(AXIsProcessTrusted())
        let connected = StashDisplay.connected()
        let external = try #require(connected.first { !$0.isBuiltIn }, "Requires an external display")
        let builtInIndex = try #require(connected.firstIndex { $0.isBuiltIn }, "Requires a built-in display")
        let builtIn = connected[builtInIndex]
        let stageManagerBefore = UserDefaults(suiteName: "com.apple.WindowManager")?.bool(forKey: "GloballyEnabled")
        let fixtures = try Fixtures(mainDisplayIndex: builtInIndex)
        defer { fixtures.close() }
        try await fixtures.launch()
        let suite = "EdgeStashFixedScreenTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(0.03, forKey: "revealDelay")
        defaults.set(0.1, forKey: "hideDelay")
        defaults.set(0.03, forKey: "animationDuration")
        let pointer = Pointer()
        let displayList = DisplayList(connected)
        let leftSettings = StashSettings(edge: .left, defaults: defaults)
        let rightSettings = StashSettings(edge: .right, defaults: defaults)
        leftSettings.targetBundleID = fixtures.id("Left")
        rightSettings.targetBundleID = fixtures.id("Right")
        leftSettings.screenSelection = external.selection
        rightSettings.screenSelection = external.selection
        let left = StashController(settings: leftSettings, mouseLocation: { pointer.location },
                                   displayProvider: { displayList.values })
        let right = StashController(settings: rightSettings, mouseLocation: { pointer.location },
                                    displayProvider: { displayList.values })
        left.canManage = { [weak right] in !(right?.isManaging($0) ?? false) }
        right.canManage = { [weak left] in !(left?.isManaging($0) ?? false) }
        defer { left.stop(); right.stop() }
        left.start()
        right.start()
        try #require(await eventually { isShown(left, false) && isShown(right, false) })
        let current = try #require(AXWindow.focusedWindow(pid: fixtures.pid("Main")))
        let original = try #require(current.frame)
        let leftWindow = try #require(fixtures.window("Left"))
        let rightWindow = try #require(fixtures.window("Right"))
        let height = NSScreen.screens[0].frame.height
        for x in [builtIn.frame.minX + 1, builtIn.frame.maxX - 1] {
            pointer.location = CGPoint(x: x, y: height - builtIn.frame.midY)
            try await Task.sleep(for: .milliseconds(300))
            let neitherShown = isShown(left, false) && isShown(right, false)
            #expect(neitherShown, "The built-in display must not trigger windows pinned to the external display")
        }
        for (edge, controller, role) in [(StashEdge.left, left, "Left"), (.right, right, "Right")] {
            let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
            pointer.location = CGPoint(x: edge == .left ? external.frame.minX + 1 : external.frame.maxX - 1,
                                       y: height - external.frame.midY)
            let revealed = await eventually {
                guard let frame = fixtures.window(role)?.frame else { return false }
                return isShown(controller, true)
                    && StashGeometry.distanceFromEdge(frame, area: external.area, edge: edge) < 3
            }
            #expect(revealed)
            try await Task.sleep(for: .milliseconds(600))
            let rendered = await eventually { fixtures.hasFullSizeOnscreenWindow(role) }
            if !rendered { fixtures.describeGeometry(role) }
            #expect(rendered, "External-display preview must be a real full-size window with Stage Manager unchanged")
            #expect(current.frame == original)
            pointer.location = CGPoint(x: external.frame.midX, y: height - external.frame.midY)
            #expect(await eventually { isShown(controller, false) })
            // Hover activates the side app (Stage Manager needs it); hiding hands focus back.
            let focusRestored = await eventually { NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground }
            #expect(focusRestored)
            #expect(AXWindow.focusedWindow(pid: fixtures.pid("Main"))?.isSame(as: current) == true)
            #expect(current.frame == original)
        }
        displayList.values.removeAll { $0.uuid == external.uuid }
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #expect(left.status == .targetScreenUnavailable && right.status == .targetScreenUnavailable)
        #expect(leftSettings.enabled && rightSettings.enabled)
        pointer.location = CGPoint(x: builtIn.frame.minX + 1, y: height - builtIn.frame.midY)
        try await Task.sleep(for: .milliseconds(300))
        #expect(left.status == .targetScreenUnavailable)
        displayList.values = connected
        pointer.location = CGPoint(x: external.frame.midX, y: height - external.frame.midY)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #expect(await eventually { isShown(left, false) && isShown(right, false) })
        let bindingsPreserved = left.isManaging(leftWindow) && right.isManaging(rightWindow)
        #expect(bindingsPreserved)
        let selectionsPreserved = leftSettings.screenSelection == external.selection && rightSettings.screenSelection == external.selection
        #expect(selectionsPreserved)
        #expect(UserDefaults(suiteName: "com.apple.WindowManager")?.bool(forKey: "GloballyEnabled") == stageManagerBefore)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["EDGESTASH_NATIVE_TESTS"] == "1"
                  && UserDefaults(suiteName: "com.apple.WindowManager")?.bool(forKey: "GloballyEnabled") != true))
    func revealsAndHidesOnBothEdgesOfEveryDisplay() async throws {
        try #require(AXIsProcessTrusted(), "Native regression needs Accessibility on the terminal")
        let fixtures = try Fixtures()
        defer { fixtures.close() }
        try await fixtures.launch()
        let suite = "EdgeStashHoverTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(0.03, forKey: "revealDelay")
        defaults.set(0.1, forKey: "hideDelay")
        defaults.set(0.03, forKey: "animationDuration")
        let pointer = Pointer()
        let leftSettings = StashSettings(edge: .left, defaults: defaults)
        let rightSettings = StashSettings(edge: .right, defaults: defaults)
        leftSettings.targetBundleID = fixtures.id("Left")
        rightSettings.targetBundleID = fixtures.id("Right")
        let left = StashController(settings: leftSettings, mouseLocation: { pointer.location })
        let right = StashController(settings: rightSettings, mouseLocation: { pointer.location })
        left.canManage = { !right.isManaging($0) }
        right.canManage = { !left.isManaging($0) }
        defer { left.stop(); right.stop() }
        left.start()
        right.start()
        try #require(await eventually { isShown(left, false) && isShown(right, false) })
        let current = try #require(AXWindow.focusedWindow(pid: fixtures.pid("Main")))
        let original = try #require(current.frame)

        // Test the external display first, matching the reported failure, then the built-in.
        for (screenIndex, screen) in NSScreen.screens.enumerated().reversed() {
            let height = NSScreen.screens[0].frame.height
            let full = StashGeometry.axRect(fromCocoa: screen.frame, primaryHeight: height)
            let area = StashGeometry.axRect(fromCocoa: screen.visibleFrame, primaryHeight: height)
            for (edge, controller, role) in [(StashEdge.left, left, "Left"), (.right, right, "Right")] {
                let foregroundBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
                pointer.location = CGPoint(x: edge == .left ? full.minX + 1 : full.maxX - 1,
                                           y: height - full.midY)
                let revealed = await eventually {
                    guard let frame = fixtures.window(role)?.frame else { return false }
                    return isShown(controller, true)
                        && StashGeometry.distanceFromEdge(frame, area: area, edge: edge) < 3
                }
                #expect(revealed, "Hover must reveal on the pointer's display")
                try await Task.sleep(for: .milliseconds(600)) // includes multiple validation ticks
                #expect(controller.settings.enabled, "System placement must not silently unpin the window")
                let stillShown = isShown(controller, true)
                #expect(stillShown)
                let rendered = await eventually {
                    fixtures.hasFullSizeOnscreenWindow(role)
                }
                if !rendered { fixtures.describeGeometry(role) }
                #expect(rendered, "Display \(screenIndex), \(edge.rawValue): a frame change alone does not prove visibility")
                #expect(current.frame == original)
                pointer.location = CGPoint(x: full.midX, y: height - full.midY)
                #expect(await eventually { isShown(controller, false) }, "Leaving the edge must hide the preview")
                let focusRestored = await eventually {
                    NSWorkspace.shared.frontmostApplication?.processIdentifier == foregroundBefore
                }
                #expect(focusRestored, "Hiding must hand focus back to the app in use before the hover")
                #expect(AXWindow.focusedWindow(pid: fixtures.pid("Main"))?.isSame(as: current) == true)
            }
        }

        // A display notification must retain an explicitly chosen window, rather than
        // discarding it and choosing a different spare window of the same app.
        let spare = try #require(AXWindow.windows(pid: fixtures.pid("Main")).last { !$0.isSame(as: current) })
        leftSettings.targetBundleID = fixtures.id("Main")
        left.stash(spare)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        try await Task.sleep(for: .milliseconds(1200))
        let bindingPreserved = left.isManaging(spare)
        #expect(bindingPreserved, "Display changes must preserve the selected window")

        // Simulate an OS adjustment, not a physical user drag. It must not clear Pin.
        leftSettings.keepVisible = true
        try #require(await eventually { isShown(left, true) })
        try await Task.sleep(for: .milliseconds(100))
        let anchored = try #require(spare.frame)
        spare.setOrigin(CGPoint(x: anchored.minX + 90, y: anchored.minY))
        let repaired = await eventually { left.isManaging(spare) && spare.frame?.minX == anchored.minX }
        #expect(repaired, "A system move must be reanchored without unpinning")
        #expect(leftSettings.enabled)
    }

    private func isShown(_ controller: StashController, _ shown: Bool) -> Bool {
        if case .stashed(_, let actual) = controller.status { return actual == shown }
        return false
    }
}

@MainActor private final class Pointer {
    var location = CGPoint(x: 500, y: 500)
}

@MainActor private final class DisplayList {
    var values: [StashDisplay]
    init(_ values: [StashDisplay]) { self.values = values }
}

@MainActor private func eventually(attempts: Int = 60, _ condition: () -> Bool) async -> Bool {
    for _ in 0..<attempts {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return false
}

@MainActor private final class Fixtures {
    let directory: URL
    let prefix = "io.github.marunouchir5.EdgeStash.HoverQA.r\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))."
    private let installedWasRunning: Bool
    private let installedID = "io.github.marunouchir5.EdgeStash"

    init(mainDisplayIndex: Int? = nil) throws {
        installedWasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: installedID).isEmpty
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("EdgeStashHoverQA-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try run("/usr/bin/swiftc", [root.appendingPathComponent("Scripts/qa/WindowFixture.swift").path,
                                   "-o", directory.appendingPathComponent("Fixture").path])
        for role in ["Left", "Right", "Main"] {
            let app = directory.appendingPathComponent("\(role).app/Contents")
            try FileManager.default.createDirectory(at: app.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: directory.appendingPathComponent("Fixture"), to: app.appendingPathComponent("MacOS/Fixture"))
            let plist: [String: Any] = ["CFBundleIdentifier": id(role), "CFBundleExecutable": "Fixture",
                                      "CFBundleName": "EdgeStash Hover QA \(role)", "CFBundlePackageType": "APPL",
                                      "QARole": role,
                                      "QAScreenIndex": role == "Main" ? (mainDisplayIndex ?? NSScreen.screens.count - 1) : NSScreen.screens.count - 1]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: app.appendingPathComponent("Info.plist"))
        }
    }

    func id(_ role: String) -> String { prefix + role.lowercased() }
    func pid(_ role: String) -> pid_t { NSRunningApplication.runningApplications(withBundleIdentifier: id(role)).first?.processIdentifier ?? -1 }
    func window(_ role: String) -> AXWindow? {
        let process = pid(role)
        return process > 0 ? AXWindow.windows(pid: process).first : nil
    }

    func launch() async throws {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: installedID).first {
            kill(app.processIdentifier, SIGTERM)
            _ = await eventually { NSRunningApplication.runningApplications(withBundleIdentifier: self.installedID).isEmpty }
        }
        for role in ["Left", "Right", "Main"] {
            try run("/usr/bin/open", (role == "Main" ? [] : ["-g"]) + ["-n", directory.appendingPathComponent("\(role).app").path])
            try #require(await eventually { !NSRunningApplication.runningApplications(withBundleIdentifier: self.id(role)).isEmpty })
            try #require(await eventually { self.window(role)?.frame != nil })
        }
        try #require(await eventually(attempts: 200) {
            NSRunningApplication.runningApplications(withBundleIdentifier: self.id("Main")).first?.isActive == true
        })
    }

    func hasFullSizeOnscreenWindow(_ role: String) -> Bool {
        guard let expected = window(role)?.frame,
              let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return false }
        // Only scalar geometry for our synthetic PID is inspected. Never read window names.
        return list.contains { entry in
            guard entry[kCGWindowOwnerPID as String] as? Int32 == pid(role),
                  entry[kCGWindowLayer as String] as? Int == 0,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
            return abs(rect.width - expected.width) < 3 && abs(rect.height - expected.height) < 3
                && abs(rect.minX - expected.minX) < 3 && abs(rect.minY - expected.minY) < 3
        }
    }

    func describeGeometry(_ role: String) {
        print("Synthetic \(role) AX frame: \(String(describing: window(role)?.frame))")
        let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        for entry in list where entry[kCGWindowOwnerPID as String] as? Int32 == pid(role)
            && entry[kCGWindowLayer as String] as? Int == 0 {
            print("Synthetic server bounds: \(entry[kCGWindowBounds as String] ?? "none"), onscreen=\(entry[kCGWindowIsOnscreen as String] ?? false)")
        }
    }

    func close() {
        for role in ["Left", "Right", "Main"] {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: id(role)) { kill(app.processIdentifier, SIGTERM) }
        }
        try? FileManager.default.removeItem(at: directory)
        if installedWasRunning { try? run("/usr/bin/open", ["-g", "/Applications/EdgeStash.app"]) }
    }

    private func run(_ command: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = args
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
    }
}
