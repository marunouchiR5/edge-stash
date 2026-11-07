import Foundation

/// User preferences, persisted in UserDefaults (`defaults read io.github.marunouchir5.EdgeStash`).
@MainActor
public final class StashSettings {
    private let d: UserDefaults
    public let edge: StashEdge

    public init(edge: StashEdge, defaults: UserDefaults = .standard) {
        self.edge = edge
        self.d = defaults
        Self.migrate(defaults)
        d.register(defaults: [
            "peek": 1.0,
            "revealDelay": 0.08,
            "hideDelay": 0.35,
            "animationDuration": 0.16,
        ])
    }

    private func key(_ name: String) -> String { "\(edge.rawValue).\(name)" }

    public var enabled: Bool {
        get { d.bool(forKey: key("enabled")) }
        set { d.set(newValue, forKey: key("enabled")) }
    }

    public var targetBundleID: String {
        get { d.string(forKey: key("targetBundleID")) ?? Self.defaultApp(for: edge) }
        set { d.set(newValue, forKey: key("targetBundleID")) }
    }

    public var widthPreset: WidthPreset {
        get { WidthPreset(rawValue: d.string(forKey: key("widthPreset")) ?? "") ?? .current }
        set { d.set(newValue.rawValue, forKey: key("widthPreset")) }
    }

    public var keepVisible: Bool {
        get { d.bool(forKey: key("keepVisible")) }
        set { d.set(newValue, forKey: key("keepVisible")) }
    }

    public var screenSelection: StashScreenSelection {
        get { StashScreenSelection(rawValue: d.string(forKey: key("screenSelection")) ?? "") ?? .followPointer }
        set { d.set(newValue.rawValue, forKey: key("screenSelection")) }
    }

    /// Points of the window left on screen while stashed. macOS refuses to place a window
    /// completely off screen (it snaps back with 40pt visible), so the minimum is 1.
    public var peek: CGFloat { max(1, CGFloat(d.double(forKey: "peek"))) }
    public var revealDelay: TimeInterval { d.double(forKey: "revealDelay") }
    public var hideDelay: TimeInterval { d.double(forKey: "hideDelay") }
    public var animationDuration: TimeInterval { d.double(forKey: "animationDuration") }

    private static func defaultApp(for edge: StashEdge) -> String {
        edge == .left ? "com.tinyspeck.slackmacgap" : "notion.id"
    }

    /// Upgrade the single-edge preferences once, retaining the selected side and paused state.
    private static func migrate(_ d: UserDefaults) {
        guard !d.bool(forKey: "independentEdgesV1") else { return }
        let legacyEdge = StashEdge(rawValue: d.string(forKey: "edge") ?? "") ?? .right
        let legacyApp = d.string(forKey: "targetBundleID") ?? "notion.id"
        let enabled = d.object(forKey: "enabled") as? Bool ?? true
        for edge in StashEdge.allCases {
            let prefix = edge.rawValue + "."
            var app = edge == legacyEdge ? legacyApp : defaultApp(for: edge)
            if edge != legacyEdge && app == legacyApp {
                app = legacyApp == "notion.id" ? "com.tinyspeck.slackmacgap" : "notion.id"
            }
            if d.object(forKey: prefix + "targetBundleID") == nil { d.set(app, forKey: prefix + "targetBundleID") }
            if d.object(forKey: prefix + "enabled") == nil { d.set(enabled, forKey: prefix + "enabled") }
            if d.object(forKey: prefix + "widthPreset") == nil {
                let width = edge == legacyEdge ? d.string(forKey: "widthPreset") : nil
                d.set(width ?? WidthPreset.current.rawValue, forKey: prefix + "widthPreset")
            }
        }
        d.set(true, forKey: "independentEdgesV1")
    }
}
