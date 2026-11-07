import AppKit
import ApplicationServices
import Testing
import EdgeStashCore
@testable import EdgeStash

/// Explicitly opt in to test the locally configured right-side app, including an
/// existing Stage Manager group. No app IDs, titles or display identifiers are logged.
@Suite @MainActor struct LiveWindowIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EDGESTASH_LIVE_TESTS"] == "1"))
    func configuredBackgroundWindowReallyRenders() async throws {
        try #require(AXIsProcessTrusted())
        let saved = StashSettings(edge: .right)
        let app = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: saved.targetBundleID).first)
        try #require(!app.isActive, "Leave a different app focused before this opt-in test")
        let foreground = try #require(NSWorkspace.shared.frontmostApplication)
        let focused = AXWindow.focusedWindow(pid: foreground.processIdentifier)
        let focusedFrame = focused?.frame
        let installed = NSRunningApplication.runningApplications(withBundleIdentifier: "io.github.marunouchir5.EdgeStash").first
        if let installed {
            kill(installed.processIdentifier, SIGTERM)
            try #require(await eventually { installed.isTerminated })
        }
        defer {
            if installed != nil {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = ["-g", "/Applications/EdgeStash.app"]
                try? process.run()
                process.waitUntilExit()
            }
        }
        let display = try #require(StashDisplay.connected().first {
            saved.screenSelection.matches(uuid: $0.uuid, isBuiltIn: $0.isBuiltIn)
        })
        let suite = "EdgeStashLiveQA.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = StashSettings(edge: .right, defaults: defaults)
        settings.targetBundleID = saved.targetBundleID
        settings.screenSelection = display.selection
        settings.widthPreset = saved.widthPreset
        var pointer = CGPoint(x: display.frame.midX, y: display.frame.midY)
        let controller = StashController(settings: settings, mouseLocation: {
            CGPoint(x: pointer.x, y: NSScreen.screens[0].frame.height - pointer.y)
        })
        defer { controller.stop() }
        controller.start()
        try #require(await eventually {
            if case .stashed(_, false) = controller.status { return true }
            return false
        })
        let window = try #require(controller.targetWindows().first { controller.isManaging($0) })
        pointer = CGPoint(x: display.frame.maxX - 1, y: display.frame.midY)
        let rendered = await eventually {
            guard let frame = window.frame else { return false }
            return StashGeometry.distanceFromEdge(frame, area: display.area, edge: .right) < 3
                && window.isVisibleAtCurrentFrame()
        }
        #expect(rendered, "A real background app must render at full size; AX placement alone is insufficient")
        try await Task.sleep(for: .milliseconds(600))
        if let focused {
            #expect(focused.frame == focusedFrame)
            #expect(focused.isVisibleAtCurrentFrame(), "The existing current window must stay visible")
        }
        pointer = CGPoint(x: display.frame.minX + 20, y: display.frame.midY)
        #expect(await eventually {
            if case .stashed(_, false) = controller.status { return true }
            return false
        })
        // A hover reveal activates the side app; hiding it must hand focus back.
        #expect(await eventually {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground.processIdentifier
        })
        if let focused {
            #expect(AXWindow.focusedWindow(pid: foreground.processIdentifier)?.isSame(as: focused) == true)
            #expect(focused.frame == focusedFrame)
        }
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<80 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
}
