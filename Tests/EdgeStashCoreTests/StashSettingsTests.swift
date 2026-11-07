import Foundation
import Testing
@testable import EdgeStashCore

@Suite @MainActor struct StashSettingsTests {
    /// Every test uses an isolated domain, never the user's app preferences.
    private func withDefaults(_ test: (UserDefaults) -> Void) {
        let name = "EdgeStashTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        test(defaults)
    }

    @Test func freshInstallUsesSlackLeftAndNotionRight() {
        withDefaults { defaults in
            let left = StashSettings(edge: .left, defaults: defaults)
            let right = StashSettings(edge: .right, defaults: defaults)
            #expect(left.targetBundleID == "com.tinyspeck.slackmacgap")
            #expect(right.targetBundleID == "notion.id")
            #expect(left.enabled && right.enabled)
            #expect(left.widthPreset == .current && right.widthPreset == .current)
        }
    }

    @Test func sidesPersistIndependentlyAcrossRestart() {
        withDefaults { defaults in
            let left = StashSettings(edge: .left, defaults: defaults)
            let right = StashSettings(edge: .right, defaults: defaults)
            left.targetBundleID = "com.example.chat"
            left.widthPreset = .half
            left.enabled = false
            left.keepVisible = true
            right.targetBundleID = "com.example.notes"
            right.widthPreset = .third
            // Legacy keys must never overwrite the new settings after migration.
            defaults.set("com.example.legacy", forKey: "targetBundleID")
            defaults.set("full", forKey: "widthPreset")

            let reloadedLeft = StashSettings(edge: .left, defaults: defaults)
            let reloadedRight = StashSettings(edge: .right, defaults: defaults)
            #expect(reloadedLeft.targetBundleID == "com.example.chat")
            #expect(reloadedLeft.widthPreset == .half)
            #expect(!reloadedLeft.enabled)
            #expect(reloadedLeft.keepVisible)
            #expect(!reloadedRight.keepVisible)
            #expect(reloadedRight.targetBundleID == "com.example.notes")
            #expect(reloadedRight.widthPreset == .third)
            #expect(reloadedRight.enabled)
        }
    }

    @Test(arguments: StashEdge.allCases)
    func migratesOriginalSideAndKeepsPausedState(edge: StashEdge) {
        withDefaults { defaults in
            defaults.set(edge.rawValue, forKey: "edge")
            defaults.set("com.example.legacy", forKey: "targetBundleID")
            defaults.set(false, forKey: "enabled")
            defaults.set("half", forKey: "widthPreset")
            let original = StashSettings(edge: edge, defaults: defaults)
            let other = StashSettings(edge: edge == .left ? .right : .left, defaults: defaults)
            #expect(original.targetBundleID == "com.example.legacy")
            #expect(original.widthPreset == .half)
            #expect(!original.enabled && !other.enabled)
            #expect(other.targetBundleID != original.targetBundleID)
            #expect(other.widthPreset == .current)
        }
    }

    @Test(arguments: StashEdge.allCases)
    func migrationAvoidsAssigningSameDefaultAppToBothEdges(edge: StashEdge) {
        withDefaults { defaults in
            defaults.set(edge.rawValue, forKey: "edge")
            let legacyApp = edge == .left ? "notion.id" : "com.tinyspeck.slackmacgap"
            defaults.set(legacyApp, forKey: "targetBundleID")
            let original = StashSettings(edge: edge, defaults: defaults)
            let other = StashSettings(edge: edge == .left ? .right : .left, defaults: defaults)
            #expect(original.targetBundleID == legacyApp)
            #expect(other.targetBundleID != legacyApp)
        }
    }

    @Test func timingsRemainSharedAndInvalidWidthsFallBack() {
        withDefaults { defaults in
            defaults.set(0.2, forKey: "revealDelay")
            defaults.set(0.6, forKey: "hideDelay")
            defaults.set(0.25, forKey: "animationDuration")
            defaults.set(0, forKey: "peek")
            defaults.set("invalid", forKey: "left.widthPreset")
            let left = StashSettings(edge: .left, defaults: defaults)
            let right = StashSettings(edge: .right, defaults: defaults)
            for side in [left, right] {
                #expect(side.revealDelay == 0.2)
                #expect(side.hideDelay == 0.6)
                #expect(side.animationDuration == 0.25)
                #expect(side.peek == 1)
                #expect(side.widthPreset == .current)
            }
        }
    }

    @Test func displayChoicesPersistIndependently() {
        withDefaults { defaults in
            let external = "11111111-2222-3333-4444-555555555555"
            let left = StashSettings(edge: .left, defaults: defaults)
            let right = StashSettings(edge: .right, defaults: defaults)
            #expect(left.screenSelection == .followPointer)
            left.screenSelection = .display(uuid: external)
            right.screenSelection = .builtIn
            #expect(StashSettings(edge: .left, defaults: defaults).screenSelection == .display(uuid: external))
            #expect(StashSettings(edge: .right, defaults: defaults).screenSelection == .builtIn)
            defaults.set("display:invalid", forKey: "left.screenSelection")
            #expect(left.screenSelection == .followPointer)
        }
    }

    @Test func explicitDisplayNeverMatchesAnotherDisplay() {
        let selection = StashScreenSelection.display(uuid: "11111111-2222-3333-4444-555555555555")
        #expect(selection.matches(uuid: "11111111-2222-3333-4444-555555555555", isBuiltIn: false))
        #expect(!selection.matches(uuid: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", isBuiltIn: true))
        #expect(StashScreenSelection.builtIn.matches(uuid: "unused", isBuiltIn: true))
        #expect(!StashScreenSelection.builtIn.matches(uuid: "unused", isBuiltIn: false))
    }
}

@Suite struct AcquisitionPolicyTests {
    @Test func keepsTheCurrentWindowInPlace() {
        #expect(!StashAcquisitionPolicy.mayAutomaticallyStash(
            available: true, appIsFrontmost: true, windowIsFocused: true))
        #expect(!StashAcquisitionPolicy.mayAutomaticallyStash(
            available: true, appIsFrontmost: true, windowIsFocused: nil))
    }

    @Test func permitsAnotherWindowOfTheCurrentApp() {
        #expect(StashAcquisitionPolicy.mayAutomaticallyStash(
            available: true, appIsFrontmost: true, windowIsFocused: false))
    }

    @Test func neverTakesTheWindowAssignedToTheOtherSide() {
        #expect(!StashAcquisitionPolicy.mayAutomaticallyStash(
            available: false, appIsFrontmost: false, windowIsFocused: false))
    }

    @Test func permitsBackgroundAppWindows() {
        #expect(StashAcquisitionPolicy.mayAutomaticallyStash(
            available: true, appIsFrontmost: false, windowIsFocused: nil))
    }
}
