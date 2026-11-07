import Foundation

/// Display UUIDs survive reordering and reconnection. They are stored only in local preferences.
public enum StashScreenSelection: RawRepresentable, Equatable, Sendable {
    case followPointer
    case builtIn
    case display(uuid: String)

    public init?(rawValue: String) {
        switch rawValue {
        case "followPointer": self = .followPointer
        case "builtIn": self = .builtIn
        default:
            guard rawValue.hasPrefix("display:"),
                  let uuid = UUID(uuidString: String(rawValue.dropFirst("display:".count))) else { return nil }
            self = .display(uuid: uuid.uuidString)
        }
    }

    public var rawValue: String {
        switch self {
        case .followPointer: return "followPointer"
        case .builtIn: return "builtIn"
        case .display(let uuid): return "display:\(uuid)"
        }
    }

    public func matches(uuid: String, isBuiltIn: Bool) -> Bool {
        switch self {
        case .followPointer: return true
        case .builtIn: return isBuiltIn
        case .display(let selected): return selected.caseInsensitiveCompare(uuid) == .orderedSame
        }
    }
}
