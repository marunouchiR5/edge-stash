import CoreGraphics

/// Width applied to the stashed window, relative to the usable width of its screen.
public enum WidthPreset: String, CaseIterable, Sendable {
    case current, minimum, quarter, third, half, threeQuarters, full

    public var title: String {
        switch self {
        case .current: "Keep Current"
        case .minimum: "Minimum"
        case .quarter: "25%"
        case .third: "33%"
        case .half: "50%"
        case .threeQuarters: "75%"
        case .full: "100%"
        }
    }

    /// Target width for a screen area `areaWidth` points wide; nil means leave the window as is.
    /// `minimum` asks for 1pt and lets the app clamp to its own minimum window width.
    public func width(forAreaWidth areaWidth: CGFloat) -> CGFloat? {
        let fraction: CGFloat
        switch self {
        case .current: return nil
        case .minimum: return 1
        case .quarter: fraction = 0.25
        case .third: fraction = 1.0 / 3.0
        case .half: fraction = 0.5
        case .threeQuarters: fraction = 0.75
        case .full: fraction = 1
        }
        return (areaWidth * fraction).rounded()
    }
}
