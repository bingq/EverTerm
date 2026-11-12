/// #16: text of the history panel. The shell history from before the app, then,
/// while a full-screen app runs, a divider and what the app has shown so far,
/// so you can select and copy across screens.
public enum HistoryPanelContent {
    public static let lineLimit = 200_000

    public static func divider(appName: String) -> String {
        "── \(appName) (live, captured so far) ──"
    }

    /// Newest lines kept when over `limit`. Empty when there is nothing to show.
    public static func lines(shell: [String], app: [String], appName: String,
                             limit: Int = lineLimit) -> [String] {
        var out = shell
        if !app.isEmpty {
            if !out.isEmpty { out.append("") }
            out.append(divider(appName: appName))
            out.append(contentsOf: app)
        }
        if out.count > limit { out.removeFirst(out.count - limit) }
        return out
    }

    public static func header(hasApp: Bool) -> String {
        (hasApp ? "Shell history, then this program's output so far" : "Shell history before this program")
            + " · read-only · select and ⌘C to copy · Esc, scroll down past the end, or type to go back"
    }
}
