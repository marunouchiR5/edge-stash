/// Automatic discovery must not move the window the user is working in. Explicit window
/// selection may still pin that window, because the user chose it deliberately.
public enum StashAcquisitionPolicy {
    public static func mayAutomaticallyStash(available: Bool, appIsFrontmost: Bool,
                                              windowIsFocused: Bool?) -> Bool {
        guard available else { return false }
        // If focus cannot be read, leave the foreground app alone rather than guessing.
        return !appIsFrontmost || windowIsFocused == false
    }
}
