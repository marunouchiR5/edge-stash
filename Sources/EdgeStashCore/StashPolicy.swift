import Foundation

/// Decides when a stashed window should slide out or back in. Pure state machine fed
/// with periodic samples, so it can be unit-tested without touching real windows.
public struct StashPolicy: Sendable {
    public enum Reason: Equatable, Sendable {
        /// Slid out because the pointer touched the edge; slides back when the pointer leaves.
        case hover
        /// Slid out because the user activated the app (Dock, Cmd-Tab, …); slides back when it loses focus.
        case activation
    }

    public enum State: Equatable, Sendable {
        case hidden
        case shown(Reason)
    }

    public enum Action: Equatable, Sendable {
        case reveal(Reason)
        case hide
    }

    public struct Sample: Sendable {
        public var now: TimeInterval
        public var pointerAtEdge: Bool
        public var pointerInWindow: Bool
        public var mouseButtonDown: Bool
        public var targetIsFrontmost: Bool

        public init(now: TimeInterval, pointerAtEdge: Bool, pointerInWindow: Bool,
                    mouseButtonDown: Bool, targetIsFrontmost: Bool) {
            self.now = now
            self.pointerAtEdge = pointerAtEdge
            self.pointerInWindow = pointerInWindow
            self.mouseButtonDown = mouseButtonDown
            self.targetIsFrontmost = targetIsFrontmost
        }
    }

    /// How long the pointer has to rest on the edge before revealing.
    public var revealDelay: TimeInterval
    /// How long the pointer has to stay outside the window before hiding.
    public var hideDelay: TimeInterval

    public private(set) var state: State = .hidden
    private var atEdgeSince: TimeInterval?
    private var outsideSince: TimeInterval?

    public init(revealDelay: TimeInterval = 0.08, hideDelay: TimeInterval = 0.35) {
        self.revealDelay = revealDelay
        self.hideDelay = hideDelay
    }

    /// Feed one sample; returns the action to perform (state is already updated).
    public mutating func update(_ s: Sample) -> Action? {
        switch state {
        case .hidden:
            guard s.pointerAtEdge else { atEdgeSince = nil; return nil }
            let since = atEdgeSince ?? s.now
            atEdgeSince = since
            guard s.now - since >= revealDelay else { return nil }
            return transition(to: .shown(.hover))

        case .shown(.hover):
            if s.pointerInWindow || s.pointerAtEdge || s.mouseButtonDown {
                outsideSince = nil
                return nil
            }
            let since = outsideSince ?? s.now
            outsideSince = since
            guard s.now - since >= hideDelay else { return nil }
            return transition(to: .hidden)

        case .shown(.activation):
            // Pointer entering the window hands control over to hover semantics.
            if s.pointerInWindow {
                state = .shown(.hover)
                outsideSince = nil
                return nil
            }
            return s.targetIsFrontmost ? nil : transition(to: .hidden)
        }
    }

    /// The user brought the target app to the front by other means (Dock, Cmd-Tab, click).
    public mutating func targetActivated() -> Action? {
        state == .hidden ? transition(to: .shown(.activation)) : nil
    }

    /// Reset to hidden without emitting an action (e.g. a freshly stashed window).
    public mutating func reset() {
        state = .hidden
        atEdgeSince = nil
        outsideSince = nil
    }

    private mutating func transition(to new: State) -> Action {
        state = new
        atEdgeSince = nil
        outsideSince = nil
        if case .shown(let r) = new { return .reveal(r) }
        return .hide
    }
}
