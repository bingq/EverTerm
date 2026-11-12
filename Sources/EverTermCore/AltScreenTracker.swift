/// Keeps what a full-screen app (alternate screen) has shown, so it can be
/// saved into scrollback when the app exits (step 3, #9).
/// Feed it the screen rows after each settled frame with `observe`; call
/// `screenGone` when the alternate screen is not active; `capture` returns
/// everything shown (lines that scrolled off the top, then the final screen)
/// and starts over.
public struct AltScreenTracker: Sendable {
    /// What one `observe` call did (for the optional capture debug log).
    public struct Observation: Sendable, Equatable {
        public var rows = 0
        public var pinnedTop = 0
        public var up: Int?            // content moved up by this many lines
        public var down: Int?          // content moved down (you scrolled up in the app)
        public var appended = 0        // lines added to the archive
        public var skippedRewound = 0  // lines skipped as already seen after scrolling back
        public var skippedRecent = 0   // lines skipped as a repeat within the last 3 screens
        public var rewound = 0         // rewind count after this frame
        public var archiveCount = 0
        public var firstAppended: String?
        public var lastAppended: String?
        public var sizeChanged = false // row count differs from the last frame (resize)
    }

    public static let defaultLimit = 200_000

    public let limit: Int
    public private(set) var archive: [String] = []   // lines that scrolled off the top
    private var previous: [String]?
    private var pinnedTop = 0                         // pinned rows seen at the last scroll
    private var rewound = 0                           // lines the content moved back down (you scrolled up in the app)
    private var liveFrame: [String]?                  // last frame seen at the live bottom (not scrolled back)

    public init(limit: Int = AltScreenTracker.defaultLimit) {
        self.limit = limit
    }

    public mutating func screenGone() {
        previous = nil
    }

    /// If the content moved up by N lines since the last frame, keep the N lines
    /// that left the top (like iTerm2's "save lines to scrollback in alternate screen").
    /// #9: rows pinned at the top (Claude Code pins your prompt while its answer
    /// scrolls under it) are skipped. When the content moves back down (you scrolled
    /// up inside the app), that many lines are skipped when it moves up again, so
    /// scrolling inside the app adds nothing. Repeated output (the same lines printed
    /// twice) is kept; only a repeat within the last few screens is treated as a re-scroll.
    @discardableResult
    public mutating func observe(_ rows: [String]) -> Observation {
        var o = Observation()
        o.rows = rows.count
        defer { previous = rows }
        // Fill the totals on every return path (a defer would change o after it is returned).
        func done() -> Observation {
            if rewound == 0 { liveFrame = rows }
            o.rewound = rewound
            o.archiveCount = archive.count
            return o
        }
        guard let previous else { return done() }
        guard previous.count == rows.count else { o.sizeChanged = true; return done() }
        let n = rows.count
        var top = 0
        while top < n - 4, !previous[top].isEmpty, previous[top] == rows[top] { top += 1 }
        o.pinnedTop = top
        if let up = Self.detectScroll(previous: previous, current: rows, skipTop: top) {
            o.up = up
            pinnedTop = top
            let window = 3 * n
            for index in top ..< top + up {
                if rewound > 0 { rewound -= 1; o.skippedRewound += 1; continue }
                let next = index + 1 < n ? previous[index + 1] : ""
                let afterNext = index + 2 < n ? previous[index + 2] : ""
                if recentlyArchived(previous[index], next, afterNext, window: window) { o.skippedRecent += 1; continue }
                archive.append(previous[index])
                o.appended += 1
                if o.firstAppended == nil { o.firstAppended = previous[index] }
                o.lastAppended = previous[index]
            }
            if archive.count > limit {
                archive.removeFirst(archive.count - limit)
            }
        } else if let down = Self.detectScrollDown(previous: previous, current: rows, skipTop: top) {
            o.down = down
            rewound += down
        }
        return done()
    }

    /// True if the three lines appear in this order among the last `window` archived lines
    /// (a position past the end counts as a blank line).
    private func recentlyArchived(_ line: String, _ next: String, _ afterNext: String, window: Int) -> Bool {
        let start = max(0, archive.count - window)
        var j = start
        while j < archive.count {
            if archive[j] == line,
               (j + 1 < archive.count ? archive[j + 1] : "") == next,
               (j + 2 < archive.count ? archive[j + 2] : "") == afterNext {
                return true
            }
            j += 1
        }
        return false
    }

    /// Everything the app showed: archived lines, then the final screen.
    /// #9: the final screen's pinned top rows are dropped when they are already
    /// archived, and lines it shares with the end of the archive appear once.
    /// Nil if there is nothing. Starts over afterwards.
    public mutating func capture(finalRows: [String]?) -> [String]? {
        let lines = merged(finalRows: finalRows)
        archive = []
        previous = nil
        liveFrame = nil
        pinnedTop = 0
        rewound = 0
        return lines.isEmpty ? nil : lines
    }

    /// #16: what the app has shown so far (archived lines + the last complete frame),
    /// without changing anything, so the save on exit is not affected.
    public func peek() -> [String] {
        merged(finalRows: previous)
    }

    /// While you are scrolled back inside the app, its screen shows older lines;
    /// the newest content is the last frame seen at the live bottom.
    private func merged(finalRows: [String]?) -> [String] {
        var final = (rewound > 0 ? liveFrame : finalRows) ?? []
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
        while lines.last?.isEmpty == true { lines.removeLast() }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        return lines
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

    /// Same as `detectScroll`, but for content that moved down by s lines
    /// (current[i + s] == previous[i]), as when you scroll up inside the app.
    public static func detectScrollDown(previous: [String], current: [String], skipTop: Int = 0) -> Int? {
        let n = previous.count
        guard n - skipTop > 3 else { return nil }
        var unchanged = 0
        for i in skipTop ..< n where !previous[i].isEmpty && previous[i] == current[i] { unchanged += 1 }
        var best: (shift: Int, matches: Int)?
        for shift in 1 ..< (n - skipTop) {
            var matches = 0, compared = 0
            for i in skipTop ..< (n - shift) where !previous[i].isEmpty {
                compared += 1
                if current[i + shift] == previous[i] { matches += 1 }
            }
            if compared >= 3, matches * 10 >= compared * 6, matches > (best?.matches ?? 0) {
                best = (shift, matches)
            }
        }
        guard let best, best.matches > unchanged else { return nil }
        return best.shift
    }
}
