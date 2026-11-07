import CoreGraphics

public enum StashEdge: String, CaseIterable, Sendable {
    case left, right
}

/// Geometry helpers. All rects/points are in the Accessibility ("flipped") global
/// coordinate space: origin at the top-left of the primary display, y grows downward.
public enum StashGeometry {
    /// Converts a Cocoa rect (origin bottom-left of primary display, y up) to AX space.
    public static func axRect(fromCocoa rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Converts a Cocoa point (e.g. `NSEvent.mouseLocation`) to AX space.
    public static func axPoint(fromCocoa point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// Where the window sits when slid out: flush against `edge` of `area`, vertically kept
    /// where it was but clamped into `area`.
    public static func shownOrigin(size: CGSize, y: CGFloat, area: CGRect, edge: StashEdge) -> CGPoint {
        let x = edge == .right ? area.maxX - size.width : area.minX
        return CGPoint(x: x, y: clampedY(y, height: size.height, area: area))
    }

    /// Where the window sits when stashed: past `edge` of `screen`, leaving `peek` points visible.
    public static func hiddenOrigin(size: CGSize, y: CGFloat, screen: CGRect, area: CGRect,
                                    edge: StashEdge, peek: CGFloat) -> CGPoint {
        let x = edge == .right ? screen.maxX - peek : screen.minX - size.width + peek
        return CGPoint(x: x, y: clampedY(y, height: size.height, area: area))
    }

    static func clampedY(_ y: CGFloat, height: CGFloat, area: CGRect) -> CGFloat {
        min(max(y, area.minY), max(area.minY, area.maxY - height))
    }

    /// True when `point` is within `threshold` points of `edge` of `screen` (and vertically on it).
    public static func isAtEdge(_ point: CGPoint, screen: CGRect, edge: StashEdge, threshold: CGFloat = 2) -> Bool {
        guard point.y >= screen.minY - 1, point.y <= screen.maxY + 1 else { return false }
        switch edge {
        case .right: return point.x >= screen.maxX - threshold && point.x <= screen.maxX + 1
        case .left: return point.x <= screen.minX + threshold && point.x >= screen.minX - 1
        }
    }

    /// Locate the display whose edge the pointer actually touches, independently of where
    /// the stashed window was acquired. Prefer the containing display at shared boundaries.
    public static func edgeScreenIndex(for point: CGPoint, screens: [CGRect], edge: StashEdge) -> Int? {
        let candidates = screens.indices.filter { isAtEdge(point, screen: screens[$0], edge: edge) }
        return candidates.first { screens[$0].contains(point) } ?? candidates.first
    }

    /// Index of the screen sharing the largest area with `rect`, or nil if none intersects.
    public static func bestScreenIndex(for rect: CGRect, screens: [CGRect]) -> Int? {
        var best: (index: Int, area: CGFloat)?
        for (i, s) in screens.enumerated() {
            let r = s.intersection(rect)
            guard !r.isNull else { continue }
            let a = r.width * r.height
            if a > (best?.area ?? 0) { best = (i, a) }
        }
        return best?.index
    }

    /// Distance between the window's outer side and the screen edge it is pinned to.
    /// Used to detect that the user dragged the window away (unstash).
    public static func distanceFromEdge(_ frame: CGRect, area: CGRect, edge: StashEdge) -> CGFloat {
        edge == .right ? abs(area.maxX - frame.maxX) : abs(frame.minX - area.minX)
    }
}
