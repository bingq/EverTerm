/// Keeps what a full-screen app (alternate screen) has shown, so it can be
/// saved into scrollback when the app exits (step 3, #9).
/// Feed it the screen rows after each settled frame with `observe`; call
/// `screenGone` when the alternate screen is not active; `capture` returns
/// everything shown (lines that scrolled off the top, then the final screen)
/// and starts over.
public struct AltScreenTracker: Sendable {
    public static let defaultLimit = 200_000

    public let limit: Int
    public private(set) var archive: [String] = []   // lines that scrolled off the top
    private var archiveKeys = Set<ArchiveKey>()       // de-dup when an app scrolls back over old lines
    private var previous: [String]?
    private var pinnedTop = 0                         // pinned rows seen at the last scroll

    private struct ArchiveKey: Hashable, Sendable {
        let line: String, next: String, afterNext: String
    }

    public init(limit: Int = AltScreenTracker.defaultLimit) {
        self.limit = limit
    }

    public mutating func screenGone() {
        previous = nil
    }

    /// If the content moved up by N lines since the last frame, keep the N lines
    /// that left the top (like iTerm2's "save lines to scrollback in alternate screen").
    /// #9: rows pinned at the top (Claude Code pins your prompt while its answer
    /// scrolls under it) are skipped, so they are not saved again on every scroll.
    public mutating func observe(_ rows: [String]) {
        defer { previous = rows }
        guard let previous, previous.count == rows.count else { return }
        let n = rows.count
        var top = 0
        while top < n - 4, !previous[top].isEmpty, previous[top] == rows[top] { top += 1 }
        guard let shift = Self.detectScroll(previous: previous, current: rows, skipTop: top) else { return }
        pinnedTop = top
        for index in top ..< top + shift {
            // Key = the line and the two after it, all inside the scrolling part.
            let key = ArchiveKey(line: previous[index],
                                 next: index + 1 < n ? previous[index + 1] : "",
                                 afterNext: index + 2 < n ? previous[index + 2] : "")
            guard archiveKeys.insert(key).inserted else { continue }
            archive.append(previous[index])
        }
        if archive.count > limit {
            archive.removeFirst(archive.count - limit)
        }
    }

    /// Everything the app showed: archived lines, then the final screen.
    /// #9: the final screen's pinned top rows are dropped when they are already
    /// archived, and lines it shares with the end of the archive appear once.
    /// Nil if there is nothing. Starts over afterwards.
    public mutating func capture(finalRows: [String]?) -> [String]? {
        var final = finalRows ?? []
        if pinnedTop > 0, final.count > pinnedTop {
            let archived = Set(archive)
            if final[0 ..< pinnedTop].allSatisfy({ $0.isEmpty || archived.contains($0) }) {
                final.removeFirst(pinnedTop)
            }
        }
        while final.first?.isEmpty == true { final.removeFirst() }
        var overlap = min(archive.count, final.count)
        while overlap > 0, !archive.suffix(overlap).elementsEqual(final.prefix(overlap)) { overlap -= 1 }
        var lines = archive
        lines.append(contentsOf: final.dropFirst(overlap))
        archive = []
        archiveKeys = []
        previous = nil
        pinnedTop = 0
        while lines.last?.isEmpty == true { lines.removeLast() }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        return lines.isEmpty ? nil : lines
    }

    /// Smallest-error upward shift s such that current[i] == previous[i + s]
    /// for most non-blank rows. Fixed rows (an app's footer or input box) just
    /// count as misses. Returns nil when the screen did not scroll.
    /// Rows above `skipTop` are pinned and not compared.
    public static func detectScroll(previous: [String], current: [String], skipTop: Int = 0) -> Int? {
        let n = previous.count
        guard n - skipTop > 3 else { return nil }
        var unchanged = 0
        for i in skipTop ..< n where !previous[i].isEmpty && previous[i] == current[i] { unchanged += 1 }
        var best: (shift: Int, matches: Int)?
        for shift in 1 ..< (n - skipTop) {
            var matches = 0, compared = 0
            for i in skipTop ..< (n - shift) where !previous[i + shift].isEmpty {
                compared += 1
                if current[i] == previous[i + shift] { matches += 1 }
            }
            if compared >= 3, matches * 10 >= compared * 6, matches > (best?.matches ?? 0) {
                best = (shift, matches)
            }
        }
        guard let best, best.matches > unchanged else { return nil }
        return best.shift
    }
}
