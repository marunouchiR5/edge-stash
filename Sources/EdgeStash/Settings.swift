import Foundation
import EdgeStashCore

/// User preferences, persisted in UserDefaults (`defaults read io.github.marunouchir5.EdgeStash`).
@MainActor
final class Settings {
    private let d = UserDefaults.standard

    init() {
        d.register(defaults: [
            "enabled": true,
            "targetBundleID": "notion.id",
            "edge": StashEdge.right.rawValue,
            "widthPreset": WidthPreset.current.rawValue,
            "peek": 1.0,
            "revealDelay": 0.08,
            "hideDelay": 0.35,
            "animationDuration": 0.16,
        ])
    }

    var enabled: Bool {
        get { d.bool(forKey: "enabled") }
        set { d.set(newValue, forKey: "enabled") }
    }

    var targetBundleID: String {
        get { d.string(forKey: "targetBundleID") ?? "notion.id" }
        set { d.set(newValue, forKey: "targetBundleID") }
    }

    var edge: StashEdge {
        get { StashEdge(rawValue: d.string(forKey: "edge") ?? "") ?? .right }
        set { d.set(newValue.rawValue, forKey: "edge") }
    }

    var widthPreset: WidthPreset {
        get { WidthPreset(rawValue: d.string(forKey: "widthPreset") ?? "") ?? .current }
        set { d.set(newValue.rawValue, forKey: "widthPreset") }
    }

    /// Points of the window left on screen while stashed. macOS refuses to place a window
    /// completely off screen (it snaps back with 40pt visible), so the minimum is 1.
    var peek: CGFloat { max(1, CGFloat(d.double(forKey: "peek"))) }
    var revealDelay: TimeInterval { d.double(forKey: "revealDelay") }
    var hideDelay: TimeInterval { d.double(forKey: "hideDelay") }
    var animationDuration: TimeInterval { d.double(forKey: "animationDuration") }
}
