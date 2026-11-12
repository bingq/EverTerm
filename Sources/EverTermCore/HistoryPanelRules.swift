/// #14: when the shell history panel opens and closes. AppKit code maps
/// NSEvents to these inputs, so the rules can be tested without a window.
public enum HistoryPanelRules {
    public enum Key: Sendable {
        case escape
        case command      // any key with ⌘ held (copy, select all, ...)
        case navigation   // page up/down, home/end, arrows
        case other        // anything you would type into the app
    }

    public enum KeyAction: Equatable, Sendable {
        case close            // close the panel, drop the key
        case keepInPanel      // the panel handles it
        case closeAndForward  // close the panel, the key goes to the app
    }

    /// Esc closes; ⌘ shortcuts and paging keys stay in the panel; any other key
    /// closes it and goes to the full-screen app.
    public static func action(for key: Key) -> KeyAction {
        switch key {
        case .escape: return .close
        case .command, .navigation: return .keepInPanel
        case .other: return .closeAndForward
        }
    }

    /// Shift + scroll up over a full-screen app opens the panel.
    /// A mouse wheel with Shift held reports a horizontal scroll; a trackpad keeps it vertical.
    /// Momentum from an earlier flick does not count.
    public static func opensOnScroll(panelOpen: Bool, shift: Bool, alternateScreen: Bool,
                                     overTerminal: Bool, deltaY: Double, deltaX: Double,
                                     precise: Bool, momentum: Bool) -> Bool {
        guard !panelOpen, shift, alternateScreen, overTerminal else { return false }
        let delta = deltaY != 0 || precise ? deltaY : deltaX
        return delta > 0 && !momentum
    }

    /// Scrolling down when the panel is already at its end closes it
    /// ("scroll back down into the app"). Momentum does not count.
    public static func closesOnScroll(wasAtEnd: Bool, deltaY: Double, momentum: Bool) -> Bool {
        wasAtEnd && deltaY < 0 && !momentum
    }
}
