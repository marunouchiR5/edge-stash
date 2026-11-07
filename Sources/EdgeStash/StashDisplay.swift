import AppKit
import EdgeStashCore

struct StashDisplay {
    var id: UInt32
    var uuid: String
    var isBuiltIn: Bool
    var frame: CGRect
    var area: CGRect
    var name: String

    var selection: StashScreenSelection { isBuiltIn ? .builtIn : .display(uuid: uuid) }

    @MainActor static func connected() -> [StashDisplay] {
        let screens = NSScreen.screens
        let height = screens.first?.frame.height ?? 0
        var externalIndex = 0
        return screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
            let builtIn = CGDisplayIsBuiltin(number.uint32Value) != 0
            if !builtIn { externalIndex += 1 }
            let label = builtIn ? "Built-in Display" : "External Display \(externalIndex)"
            return StashDisplay(id: number.uint32Value,
                                uuid: CFUUIDCreateString(nil, uuid) as String,
                                isBuiltIn: builtIn,
                                frame: StashGeometry.axRect(fromCocoa: screen.frame, primaryHeight: height),
                                area: StashGeometry.axRect(fromCocoa: screen.visibleFrame, primaryHeight: height),
                                name: "\(label) · \(Int(screen.frame.width)) × \(Int(screen.frame.height))")
        }
    }
}
