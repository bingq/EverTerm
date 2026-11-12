import AppKit
import EverTermCore
import SwiftTerm

/// #14: read-only view of the normal screen's history, shown over the terminal
/// while a full-screen app (Claude Code, vim, less) owns the alternate screen.
/// The history does not change while the app runs, so a snapshot is enough.
/// Closes on Esc, on scrolling down past the bottom, or when you type (the key
/// goes to the app).
@MainActor
final class ShellHistoryPanel: NSView {
    /// Lines shown; older ones stay in the session's output.txt.
    static let lineLimit = 200_000

    var onClose: (() -> Void)?
    private let scrollView = HistoryScrollView()
    private let textView = HistoryTextView()
    private weak var terminal: TerminalView?

    /// The normal screen's rows as plain text, or nil when it has nothing to show.
    static func lines(of terminal: TerminalView) -> [String]? {
        guard let snapshot = terminal.terminalContentSnapshot(region: .all, buffer: .normal) else { return nil }
        var lines = snapshot.rows.map { row -> String in
            var text = row.text.replacingOccurrences(of: "\u{0}", with: " ")
            while text.last?.isWhitespace == true { text.removeLast() }
            return text
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        if lines.count > lineLimit { lines.removeFirst(lines.count - lineLimit) }
        return lines.isEmpty ? nil : lines
    }

    init(lines: [String], terminal: TerminalView, frame: NSRect) {
        self.terminal = terminal
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        let background = terminal.nativeBackgroundColor
        let foreground = terminal.nativeForegroundColor
        layer?.backgroundColor = background.cgColor

        // Header: what this is and how to leave.
        let headerHeight: CGFloat = 26
        let header = NSTextField(labelWithString:
            "Shell history before this program · read-only · Esc, scroll down past the end, or type to go back")
        header.font = NSFont.systemFont(ofSize: 11)
        header.textColor = .secondaryLabelColor
        header.lineBreakMode = .byTruncatingTail
        header.frame = NSRect(x: 10, y: bounds.height - headerHeight + 5, width: bounds.width - 20, height: 16)
        header.autoresizingMask = [.width, .minYMargin]
        let bar = NSView(frame: NSRect(x: 0, y: bounds.height - headerHeight, width: bounds.width, height: headerHeight))
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        bar.autoresizingMask = [.width, .minYMargin]
        addSubview(bar)
        addSubview(header)

        // Body: plain text, no wrapping, same font and colours as the terminal.
        scrollView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - headerHeight)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .legacy
        scrollView.drawsBackground = true
        scrollView.backgroundColor = background

        textView.frame = scrollView.contentView.bounds
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = true
        textView.backgroundColor = background
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.string = lines.joined(separator: "\n")
        textView.font = terminal.font          // after the text, so it applies to all of it
        textView.textColor = foreground
        scrollView.documentView = textView
        addSubview(scrollView)

        textView.onEscape = { [weak self] in self?.close() }
        textView.onTyping = { [weak self] event in self?.close(forwarding: event) }
        scrollView.onScrolledPastEnd = { [weak self] in self?.close() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Call after the panel is in a window: jump to the newest line and take the keyboard.
    func present() {
        textView.scrollRangeToVisible(NSRange(location: (textView.string as NSString).length, length: 0))
        window?.makeFirstResponder(textView)
    }

    func close(forwarding event: NSEvent? = nil) {
        guard superview != nil else { return }
        let terminal = self.terminal
        removeFromSuperview()
        if let terminal {
            terminal.window?.makeFirstResponder(terminal)
            if let event { terminal.keyDown(with: event) }
        }
        onClose?()
    }
}

/// Esc closes; Cmd shortcuts (copy, select all) and paging keys stay in the panel;
/// any other key closes it and goes to the full-screen app.
private final class HistoryTextView: NSTextView {
    var onEscape: (() -> Void)?
    var onTyping: ((NSEvent) -> Void)?

    private static let navigationKeys: [NSEvent.SpecialKey] =
        [.pageUp, .pageDown, .home, .end, .upArrow, .downArrow, .leftArrow, .rightArrow]

    override func keyDown(with event: NSEvent) {
        let key: HistoryPanelRules.Key
        if event.keyCode == 53 { key = .escape }
        else if event.modifierFlags.contains(.command) { key = .command }
        else if let special = event.specialKey, Self.navigationKeys.contains(special) { key = .navigation }
        else { key = .other }
        switch HistoryPanelRules.action(for: key) {
        case .close: onEscape?()
        case .keepInPanel: super.keyDown(with: event)
        case .closeAndForward: onTyping?(event)
        }
    }
}

/// Reports a downward scroll that starts when the view is already at the end,
/// i.e. "scroll back down into the app". Momentum from an earlier flick does not count.
private final class HistoryScrollView: NSScrollView {
    var onScrolledPastEnd: (() -> Void)?

    private var isAtEnd: Bool {
        guard let document = documentView else { return true }
        return contentView.documentVisibleRect.maxY >= document.frame.height - 2
    }

    override func scrollWheel(with event: NSEvent) {
        let wasAtEnd = isAtEnd
        super.scrollWheel(with: event)
        if HistoryPanelRules.closesOnScroll(wasAtEnd: wasAtEnd, deltaY: Double(event.scrollingDeltaY),
                                            momentum: !event.momentumPhase.isEmpty) {
            onScrolledPastEnd?()
        }
    }
}
