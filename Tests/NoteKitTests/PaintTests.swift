#if os(macOS)
import XCTest
import SwiftUI
@testable import NoteKit

/// Painted structure: bullets and task boxes drawn over markers that keep their place in the text, in a gutter of the
/// same width whatever the file's indent, wrapped lines hanging under the text, markers shown as written when the
/// selection touches them, and a box that ticks through the editor's own edit path.
@MainActor final class PaintTests: XCTestCase {
    private let long = "a line long enough to wrap onto a second line in a column this narrow, and then some"
    private let longHebrew = "שורה ארוכה מספיק כדי לגלוש לשורה שנייה בעמודה צרה כמו זו, ועוד קצת מילים בסוף"
    private var url: URL!
    private lazy var note = """
    - [ ] milk
    - [x] eggs
    - \(long)
    - [ ] \(long)
    - \(longHebrew)
    > \(long)
    plain
    - one
      - two spaces
    \t- a tab
    1. [ ] numbered task
    > > nested
    - [ ]
    """

    private func make(_ text: String? = nil, editable: Bool = true) async throws -> (NoteSession, ReadableTextView, NSWindow) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent("Paint.md")
        try Data((text ?? note).utf8).write(to: url)
        let session = NoteSession(url: url); await session.open()
        let host = NSHostingView(rootView: NoteTextView(session: session, editable: editable).frame(width: 420, height: 700))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; host.layoutSubtreeIfNeeded()
        let textView = try XCTUnwrap(TestViews.find(in: host) as? ReadableTextView)
        window.makeFirstResponder(textView)
        // The caret starts on a line of prose, touching no markers.
        let prose = (textView.string as NSString).range(of: "plain").location
        textView.setSelectedRange(NSRange(location: prose == NSNotFound ? textView.string.utf16.count : prose, length: 0))
        layout(textView)
        return (session, textView, window)
    }
    private func layout(_ textView: NSTextView) { textView.textLayoutManager?.ensureLayout(for: textView.textLayoutManager!.documentRange) }
    private func offset(of text: String, in textView: NSTextView) -> Int { (textView.string as NSString).range(of: text).location }
    private func fragment(at offset: Int, in textView: NSTextView) -> NoteFragment {
        let manager = textView.textLayoutManager!, content = manager.textContentManager!
        return manager.textLayoutFragment(for: content.location(content.documentRange.location, offsetBy: offset)!) as! NoteFragment
    }
    /// What the paragraph at `offset` paints, each with its rect in the view.
    private func paints(at offset: Int, in textView: NSTextView) -> [(NotePaint.Kind, CGRect)] {
        let fragment = fragment(at: offset, in: textView)
        let origin = textView.textContainerOrigin, frame = fragment.layoutFragmentFrame
        return fragment.paintRects(fragment.paints).map { ($0.0, $0.1.offsetBy(dx: frame.minX + origin.x, dy: frame.minY + origin.y)) }
    }
    /// Where each line of the paragraph at `offset` starts its text (the caret's x before its first character, after
    /// `skip` characters of markers on the first line), in the view.
    private func lineStarts(at offset: Int, skip: Int, in textView: NSTextView) -> [CGFloat] {
        let fragment = fragment(at: offset, in: textView)
        return fragment.textLineFragments.enumerated().map { index, line in
            fragment.layoutFragmentFrame.minX + textView.textContainerOrigin.x + line.typographicBounds.minX
                + line.locationForCharacter(at: line.characterRange.location + (index == 0 ? skip : 0)).x
        }
    }
    private func box(at offset: Int, in textView: NSTextView) throws -> CGRect {
        try XCTUnwrap(paints(at: offset, in: textView).first { if case .task = $0.0 { true } else if case .box = $0.0 { true } else { false } }?.1)
    }
    /// A click through the text view's own handling; the mouse-up is queued first, for the text view's tracking.
    private func click(_ textView: NSTextView, at point: NSPoint, count: Int = 1) {
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: textView.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: textView.window!.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1)!
        }
        textView.window!.postEvent(event(.leftMouseUp), atStart: false)
        textView.mouseDown(with: event(.leftMouseDown))
        layout(textView)
    }
    private func commandReturn(_ textView: NSTextView) -> Bool {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: textView.window!.windowNumber,
                                     context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        return textView.performKeyEquivalent(with: event)
    }
    private func line(_ number: Int, of textView: NSTextView) -> String { textView.string.components(separatedBy: "\n")[number] }
    /// Lets the main run loop turn, as it does between two events, so the undo group the last event opened closes.
    private func settle() async throws { try await Task.sleep(for: .milliseconds(30)) }

    func testListsSitInAGutterOfTheSameWidthWhateverTheIndent() async throws {
        let (_, textView, window) = try await make()
        defer { _ = window }
        let step = NoteStyler.step
        let one = lineStarts(at: offset(of: "- one", in: textView), skip: 2, in: textView)[0]
        let two = lineStarts(at: offset(of: "  - two", in: textView), skip: 4, in: textView)[0]
        let tab = lineStarts(at: offset(of: "\t- a tab", in: textView), skip: 3, in: textView)[0]
        XCTAssertEqual(two - one, step, accuracy: 0.5, "two spaces step in one level")
        XCTAssertEqual(tab - one, step, accuracy: 0.5, "and so does a tab")
        // A task's box stands in its bullet's column.
        let dot = try XCTUnwrap(paints(at: offset(of: "- one", in: textView), in: textView).first?.1)
        XCTAssertEqual(try box(at: offset(of: "- [ ] milk", in: textView), in: textView).midX, dot.midX, accuracy: 0.5)
    }

    func testWrappedListLinesHangUnderTheirText() async throws {
        let (_, textView, window) = try await make()
        defer { _ = window }
        for (text, skip) in [("- \(long)", 2), ("- [ ] \(long)", 6), ("> \(long)", 2)] {
            let starts = lineStarts(at: offset(of: text, in: textView), skip: skip, in: textView)
            XCTAssertGreaterThan(starts.count, 1, "\(text.prefix(8)) wraps")
            for start in starts.dropFirst() { XCTAssertEqual(start, starts[0], accuracy: 1, "\(text.prefix(8)): a wrapped line starts under the text, not under the marker") }
        }
        // Right to left: the text starts left of the bullet, and the wrapped line's right edge lines up with it.
        let hebrew = offset(of: "- \(longHebrew)", in: textView)
        let starts = lineStarts(at: hebrew, skip: 2, in: textView)
        XCTAssertGreaterThan(starts.count, 1)
        let dot = try XCTUnwrap(paints(at: hebrew, in: textView).first?.1)
        XCTAssertGreaterThan(dot.minX, starts[0], "the bullet is on the right")
        XCTAssertEqual(starts[1], starts[0], accuracy: 1, "the wrapped line starts under the text, on the right")
    }

    func testTheCaretAtAMarkerShowsItAsWrittenAndMovesNothing() async throws {
        let (_, textView, window) = try await make()
        defer { _ = window }
        let milk = offset(of: "- [ ] milk", in: textView)
        let painted = lineStarts(at: milk, skip: 6, in: textView)[0]
        XCTAssertFalse(paints(at: milk, in: textView).isEmpty)
        XCTAssertEqual(textView.textStorage?.attribute(.foregroundColor, at: milk, effectiveRange: nil) as? NSColor, .clear)
        // The caret at the start of the text, where ⌫ would delete a marker: the markers show.
        textView.setSelectedRange(NSRange(location: milk + 6, length: 0)); layout(textView)
        XCTAssertTrue(paints(at: milk, in: textView).isEmpty, "shown as written, not painted")
        XCTAssertNotEqual(textView.textStorage?.attribute(.foregroundColor, at: milk, effectiveRange: nil) as? NSColor, .clear)
        XCTAssertEqual(lineStarts(at: milk, skip: 6, in: textView)[0], painted, accuracy: 0.01, "the text stays where it was")
        // Into the text: painted again.
        textView.setSelectedRange(NSRange(location: milk + 8, length: 0)); layout(textView)
        XCTAssertFalse(paints(at: milk, in: textView).isEmpty)
        // A view that only shows the note paints everything, wherever its selection is.
        let (_, reader, readerWindow) = try await make(editable: false)
        defer { _ = readerWindow }
        reader.setSelectedRange(NSRange(location: milk + 6, length: 0)); layout(reader)
        XCTAssertFalse(paints(at: milk, in: reader).isEmpty)
    }

    func testEachQuoteLevelGetsItsBarAndANumberedTaskItsBox() async throws {
        let (_, textView, window) = try await make()
        defer { _ = window }
        let bars = paints(at: offset(of: "> > nested", in: textView), in: textView).filter { if case .quote = $0.0 { true } else { false } }
        XCTAssertEqual(bars.count, 2, "one bar for each `>`")
        XCTAssertGreaterThan(bars[1].1.minX - bars[0].1.minX, 4)
        let numbered = offset(of: "1. [ ] numbered", in: textView)
        XCTAssertEqual(paints(at: numbered, in: textView).map(\.0), [.box(done: false)])
        let target = try box(at: numbered, in: textView)
        click(textView, at: NSPoint(x: target.midX, y: target.midY))
        XCTAssertEqual(line(10, of: textView), "1. [x] numbered task")
    }

    func testNestingFollowsAnEditToTheItemsAboveIt() async throws {
        let (_, textView, window) = try await make("- a\n  - b\n    - c\nprose")
        defer { _ = window }
        let c = offset(of: "    - c", in: textView)
        XCTAssertEqual(paints(at: c, in: textView).first?.0, .bullet(level: 3))
        // Out-dent b: c is now b's child, one level in.
        let b = NSRange(location: offset(of: "  - b", in: textView), length: 2)
        XCTAssertTrue(textView.shouldChangeText(in: b, replacementString: ""))
        textView.textStorage?.replaceCharacters(in: b, with: ""); textView.didChangeText(); layout(textView)
        XCTAssertEqual(paints(at: offset(of: "    - c", in: textView), in: textView).first?.0, .bullet(level: 2))
    }

    func testNestingFollowsAnEditPastAnItemThatKeepsItsLevel() async throws {
        let (_, textView, window) = try await make("- a\n  - b\n      - c\n    - d\nprose")
        defer { _ = window }
        XCTAssertEqual(paints(at: offset(of: "    - d", in: textView), in: textView).first?.0, .bullet(level: 3))
        // Indent b to d's column: c stays a level under b, and d below it becomes b's sibling.
        XCTAssertTrue(textView.shouldChangeText(in: NSRange(location: offset(of: "  - b", in: textView), length: 0), replacementString: "  "))
        textView.textStorage?.replaceCharacters(in: NSRange(location: offset(of: "  - b", in: textView), length: 0), with: "  ")
        textView.didChangeText(); layout(textView)
        XCTAssertEqual(paints(at: offset(of: "      - c", in: textView), in: textView).first?.0, .bullet(level: 3))
        XCTAssertEqual(paints(at: offset(of: "    - d", in: textView), in: textView).first?.0, .bullet(level: 2))
    }

    func testTheCaretRevealsMarkersAfterAnEditAboveMovedThem() async throws {
        let (_, textView, window) = try await make("intro\n- eggs\nplain")
        defer { _ = window }
        XCTAssertTrue(textView.shouldChangeText(in: NSRange(location: 0, length: 0), replacementString: "an "))
        textView.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: "an ")
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: offset(of: "- eggs", in: textView) + 2, length: 0)); layout(textView)
        XCTAssertTrue(paints(at: offset(of: "- eggs", in: textView), in: textView).isEmpty, "shown as written")
        // A selection across paragraphs is for copying or deleting: it reveals nothing.
        textView.selectAll(nil); layout(textView)
        XCTAssertFalse(paints(at: offset(of: "- eggs", in: textView), in: textView).isEmpty)
    }

    func testClickingABoxTicksItAsOneUndoStepAndMovesNothing() async throws {
        let (session, textView, window) = try await make()
        defer { _ = window }
        let caret = textView.selectedRange()
        let milk = offset(of: "- [ ] milk", in: textView)
        let before = lineStarts(at: milk, skip: 6, in: textView)[0]
        var target = try box(at: milk, in: textView)
        try await settle()
        click(textView, at: NSPoint(x: target.midX, y: target.midY))
        try await settle()
        XCTAssertEqual(line(0, of: textView), "- [x] milk")
        XCTAssertEqual(session.text, textView.string, "the session has the edit, to save like any other")
        XCTAssertEqual(textView.selectedRange(), caret, "the caret stays where it was")
        XCTAssertEqual(lineStarts(at: milk, skip: 6, in: textView)[0], before, accuracy: 0.01, "ticked, the text doesn't move")
        // A quick second click unticks it again.
        target = try box(at: milk, in: textView)
        click(textView, at: NSPoint(x: target.midX, y: target.midY), count: 2)
        try await settle()
        XCTAssertEqual(line(0, of: textView), "- [ ] milk")
        textView.undoManager?.undo(); layout(textView)
        XCTAssertEqual(line(0, of: textView), "- [x] milk", "each click is its own undo step")
        // A task at the very end, with nothing after its box.
        let last = (textView.string as NSString).range(of: "\n- [ ]", options: .backwards).location + 1
        target = try box(at: last, in: textView)
        click(textView, at: NSPoint(x: target.midX, y: target.midY))
        XCTAssertTrue(textView.string.hasSuffix("\n- [x]"), String(textView.string.suffix(12)))
        // A click on the task's text, not its box, is an ordinary click.
        target = try box(at: milk, in: textView)
        click(textView, at: NSPoint(x: target.midX + 80, y: target.midY))
        XCTAssertEqual(line(0, of: textView), "- [x] milk")
    }

    func testCommandReturnTicksTheTasksTheSelectionTouchesAndSurvivesAnUndo() async throws {
        let (_, textView, window) = try await make()
        defer { _ = window }
        // From "milk" into "eggs": one open, one ticked; the open one is ticked, the ticked one stays.
        textView.setSelectedRange(NSRange(location: offset(of: "milk", in: textView), length: 8))
        try await settle()
        XCTAssertTrue(commandReturn(textView))
        try await settle()
        XCTAssertEqual([line(0, of: textView), line(1, of: textView)], ["- [x] milk", "- [x] eggs"])
        // All ticked: they all untick, in one undo step.
        XCTAssertTrue(commandReturn(textView))
        try await settle()
        XCTAssertEqual([line(0, of: textView), line(1, of: textView)], ["- [ ] milk", "- [ ] eggs"])
        textView.undoManager?.undo()
        XCTAssertEqual([line(0, of: textView), line(1, of: textView)], ["- [x] milk", "- [x] eggs"])
        // Straight after the undo: the boxes are found in the text, not in attributes the undo put back, so only the
        // boxes change. (The undo selected what it restored; both lines are selected again.)
        textView.setSelectedRange(NSRange(location: offset(of: "milk", in: textView), length: 8))
        XCTAssertTrue(commandReturn(textView))
        XCTAssertEqual([line(0, of: textView), line(1, of: textView)], ["- [ ] milk", "- [ ] eggs"])
        // On a line with no task, ⌘⏎ isn't taken.
        textView.setSelectedRange(NSRange(location: offset(of: "plain", in: textView), length: 0))
        let unchanged = textView.string
        XCTAssertFalse(commandReturn(textView))
        XCTAssertEqual(textView.string, unchanged)
    }

    func testAReadOnlyNoteNeverTicks() async throws {
        let (session, textView, window) = try await make(editable: false)
        defer { _ = window }
        let target = try box(at: offset(of: "- [ ] milk", in: textView), in: textView)
        click(textView, at: NSPoint(x: target.midX, y: target.midY))
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        _ = commandReturn(textView)
        XCTAssertEqual(textView.string, note)
        XCTAssertEqual(session.text, note)
    }
}
#endif
