import AppKit
import EverTermCore
import SwiftTerm

/// #14: read-only view of the normal screen's history, shown over the terminal
/// while a full-screen app (Claude Code, vim, less) owns the alternate screen.
/// #16: below a divider it also shows what the app has shown so far, so you can
/// select and copy across screens (drag, Shift-click, ⌘A, ⌘C).
/// It is a snapshot taken when it opens; reopen it for newer output.
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

    /// The normal screen's rows as plain text (empty when it has nothing to show).
    static func lines(of terminal: TerminalView) -> [String] {
        guard let snapshot = terminal.terminalContentSnapshot(region: .all, buffer: .normal) else { return [] }
        var lines = snapshot.rows.map { row -> String in
            var text = row.text.replacingOccurrences(of: "\u{0}", with: " ")
            while text.last?.isWhitespace == true { text.removeLast() }
            return text
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        if lines.count > lineLimit { lines.removeFirst(lines.count - lineLimit) }
        return lines
    }

    init(lines: [String], hasApp: Bool, terminal: TerminalView, frame: NSRect) {
        self.terminal = terminal
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        let background = terminal.nativeBackgroundColor
        let foreground = terminal.nativeForegroundColor
        layer?.backgroundColor = background.cgColor

        // Header: what this is and how to leave.
        let headerHeight: CGFloat = 26
        let header = NSTextField(labelWithString: HistoryPanelContent.header(hasApp: hasApp))
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
        // Whole-point line height, so line edges land on pixels and a shrinking
        // selection leaves no slivers of old highlight behind.
        let font = terminal.font
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [.font: font, .foregroundColor: foreground, .paragraphStyle: paragraph]
        textView.textStorage?.setAttributedString(NSAttributedString(
            string: lines.joined(separator: "\n"),
            attributes: [.font: font, .foregroundColor: foreground, .paragraphStyle: paragraph]))
        // Same selection colour as the terminal, so a selection looks the same everywhere.
        textView.selectedTextAttributes = [.backgroundColor: terminal.selectedTextBackgroundColor]
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

    /// Repaint the visible text whenever the selection changes; AppKit's partial
    /// repaint left thin lines of old highlight when a drag selection shrank.
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        setNeedsDisplay(visibleRect)
    }

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
