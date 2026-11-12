/// One line of capture-debug.log (turned on with EVERTERM_DEBUG_CAPTURE=1).
/// The log holds screen text, so it stays in the local session folder.
public enum CaptureDebug {
    public static func line(ms: Int, rawOffset: Int, reason: String, inSync: Bool,
                            _ o: AltScreenTracker.Observation) -> String {
        func cut(_ s: String?) -> String {
            guard let s else { return "-" }
            let t = s.count > 40 ? String(s.prefix(40)) + "…" : s
            return "\"" + String(t.map { $0 == "\"" ? "'" : $0 }) + "\""
        }
        var parts = ["t=\(ms)ms", "raw=\(rawOffset)", "why=\(reason)", "sync=\(inSync ? 1 : 0)",
                     "rows=\(o.rows)", "pin=\(o.pinnedTop)",
                     "up=\(o.up.map(String.init) ?? "-")", "down=\(o.down.map(String.init) ?? "-")",
                     "add=\(o.appended)", "skipRewind=\(o.skippedRewound)", "skipRecent=\(o.skippedRecent)",
                     "rewind=\(o.rewound)", "archive=\(o.archiveCount)"]
        if o.sizeChanged { parts.append("resized") }
        if o.appended > 0 { parts.append("first=\(cut(o.firstAppended)) last=\(cut(o.lastAppended))") }
        return parts.joined(separator: " ")
    }
}
