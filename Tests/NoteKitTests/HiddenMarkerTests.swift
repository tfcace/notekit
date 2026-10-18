#if os(macOS)
import XCTest
import SwiftUI
@testable import NoteKit

/// Hidden markers: inline markers, a heading's `#`s, a link's brackets and address and a callout's `[!type]` take no
/// room off the paragraph holding the caret, open when it comes to them, and a click sequence works on the layout it
/// started on.
@MainActor final class HiddenMarkerTests: XCTestCase {
    private let note = """
    caret here
    a **bold** word
    ## Heading
    see [text](https://example.com) and [[target|alias]]
    ![[photo.png]]
    > [!tip]
    """

    private func make(_ text: String? = nil, editable: Bool = true, focused: Bool = true) async throws -> (ReadableTextView, NSWindow) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Hidden.md")
        try Data((text ?? note).utf8).write(to: url)
        let session = NoteSession(url: url); await session.open()
        let host = NSHostingView(rootView: NoteTextView(session: session, editable: editable).frame(width: 600, height: 400))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; host.layoutSubtreeIfNeeded()
        let textView = try XCTUnwrap(TestViews.find(in: host) as? ReadableTextView)
        if focused { window.makeFirstResponder(textView) }
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        layout(textView)
        return (textView, window)
    }
    private func layout(_ textView: NSTextView) { textView.textLayoutManager?.ensureLayout(for: textView.textLayoutManager!.documentRange) }
    private func offset(of text: String, in textView: NSTextView) -> Int { (textView.string as NSString).range(of: text).location }
    /// The caret's x before character `index`, in the view.
    private func x(_ index: Int, in textView: NSTextView) -> CGFloat { rect(index, in: textView).minX }
    private func rect(_ index: Int, in textView: NSTextView) -> CGRect {
        let manager = textView.textLayoutManager!, content = manager.textContentManager!
        let location = content.location(content.documentRange.location, offsetBy: index)!
        var rect = CGRect.null
        manager.enumerateTextSegments(in: NSTextRange(location: location, end: content.location(location, offsetBy: 1))!, type: .standard, options: []) { _, segment, _, _ in
            rect = segment; return false
        }
        return rect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
    }
    /// A point `fraction` of the way across character `index`.
    private func point(_ index: Int, at fraction: CGFloat, in textView: NSTextView) -> NSPoint {
        let rect = rect(index, in: textView)
        return NSPoint(x: rect.minX + rect.width * fraction, y: rect.midY)
    }
    /// A click sequence through the text view's own handling, one click after another; each mouse-up is queued first,
    /// for the text view's tracking.
    private func click(_ textView: NSTextView, at point: NSPoint, count: Int = 1) {
        for number in 1...count {
            func event(_ type: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: textView.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: textView.window!.windowNumber, context: nil, eventNumber: 0, clickCount: number, pressure: 1)!
            }
            textView.window!.postEvent(event(.leftMouseUp), atStart: false)
            textView.mouseDown(with: event(.leftMouseDown))
            layout(textView)
        }
    }

    func testMarkersTakeNoRoomOffTheCaretsParagraphAndShowOnIt() async throws {
        let (textView, window) = try await make()
        defer { _ = window }
        let bold = offset(of: "a **bold**", in: textView)
        XCTAssertEqual(x(bold + 4, in: textView), x(bold + 2, in: textView), accuracy: 0.5, "`**` takes no room")
        XCTAssertEqual(x(offset(of: "Heading", in: textView), in: textView), x(0, in: textView), accuracy: 0.5, "the heading starts at the margin")
        let link = offset(of: "see [text]", in: textView)
        XCTAssertEqual(x(link + 5, in: textView), x(link + 4, in: textView), accuracy: 0.5, "the bracket takes no room")
        let and = offset(of: " and [[", in: textView)
        XCTAssertEqual(x(and, in: textView), x(link + 9, in: textView), accuracy: 0.5, "nor does the address after the text")
        let alias = offset(of: "alias]]", in: textView)
        XCTAssertEqual(x(alias, in: textView), x(and + 5, in: textView), accuracy: 0.5, "an aliased link shows its alias alone")
        // An embed, and a callout with no title of its own, stay as written.
        let embed = offset(of: "![[photo", in: textView)
        XCTAssertGreaterThan(x(embed + 3, in: textView) - x(embed, in: textView), 10)
        XCTAssertNotEqual(textView.textStorage?.attribute(.foregroundColor, at: offset(of: "[!tip]", in: textView), effectiveRange: nil) as? NSColor, .clear)
        // The caret comes to the line: its markers take their room; it leaves, and they close up again.
        textView.setSelectedRange(NSRange(location: bold + 12, length: 0)); layout(textView)
        XCTAssertGreaterThan(x(bold + 4, in: textView) - x(bold + 2, in: textView), 5)
        XCTAssertEqual(x(link + 5, in: textView), x(link + 4, in: textView), accuracy: 0.5, "the other lines stay closed")
        textView.setSelectedRange(NSRange(location: 0, length: 0)); layout(textView)
        XCTAssertEqual(x(bold + 4, in: textView), x(bold + 2, in: textView), accuracy: 0.5)
        XCTAssertEqual(textView.string, note)
        // A view that only shows the note hides them wherever its selection is.
        let (reader, readerWindow) = try await make(editable: false)
        defer { _ = readerWindow }
        reader.setSelectedRange(NSRange(location: bold + 5, length: 0)); layout(reader)
        XCTAssertEqual(x(bold + 4, in: reader), x(bold + 2, in: reader), accuracy: 0.5)
    }

    func testALineOfNothingButMarkersKeepsThem() async throws {
        let (textView, window) = try await make("alpha\n## \n[]()\nbeta")
        defer { _ = window }
        textView.setSelectedRange(NSRange(location: offset(of: "beta", in: textView), length: 0)); layout(textView)
        let line = rect(0, in: textView).height
        XCTAssertEqual(rect(offset(of: "## ", in: textView), in: textView).height, line, accuracy: 1, "a heading with no title yet")
        XCTAssertEqual(rect(offset(of: "[]()", in: textView), in: textView).height, line, accuracy: 1, "a link with nothing in it")
        XCTAssertGreaterThan(x(offset(of: "[]()", in: textView) + 2, in: textView) - x(offset(of: "[]()", in: textView), in: textView), 5)
    }

    func testTheCaretsLineOpensOnlyWhileTheNoteHasFocus() async throws {
        let (textView, window) = try await make("# Title\nbody", focused: false)
        defer { _ = window }
        let margin = x(offset(of: "body", in: textView), in: textView), title = offset(of: "Title", in: textView)
        XCTAssertEqual(x(title, in: textView), margin, accuracy: 0.5, "opened, the caret on the title, but not being edited")
        window.makeFirstResponder(textView); layout(textView)
        XCTAssertGreaterThan(x(title, in: textView) - margin, 5, "focus opens the caret's line")
        window.makeFirstResponder(nil); layout(textView)
        XCTAssertEqual(x(title, in: textView), margin, accuracy: 0.5, "and losing it closes the line again")
    }

    func testAClickWorksOnTheLayoutItLandedOnAndOpensTheLineAfter() async throws {
        let (textView, window) = try await make()
        defer { _ = window }
        let bold = offset(of: "a **bold**", in: textView), closed = x(bold + 4, in: textView)
        // A click on the `o` lands before it, and the line stays as it was until the click sequence is over.
        click(textView, at: point(bold + 5, at: 0.3, in: textView))
        XCTAssertEqual(textView.selectedRange(), NSRange(location: bold + 5, length: 0))
        XCTAssertEqual(x(bold + 4, in: textView), closed, accuracy: 0.5)
        try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.2)); layout(textView)
        XCTAssertGreaterThan(x(bold + 4, in: textView) - closed, 5, "open once it's over")
        // A double-click near a closed word's start selects the word, not the marker that opening would put there.
        textView.setSelectedRange(NSRange(location: 0, length: 0)); layout(textView)
        click(textView, at: point(bold + 4, at: 0.2, in: textView), count: 2)
        XCTAssertEqual((textView.string as NSString).substring(with: textView.selectedRange()), "bold")
    }

    func testAKeyAfterAClickOpensTheLineBeforeItLands() async throws {
        let (textView, window) = try await make()
        defer { _ = window }
        let bold = offset(of: "a **bold**", in: textView)
        click(textView, at: point(bold + 5, at: 0.3, in: textView))
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                   context: nil, characters: "Z", charactersIgnoringModifiers: "Z", isARepeat: false, keyCode: 6)!
        textView.keyDown(with: key); layout(textView)
        XCTAssertEqual((textView.string as NSString).substring(with: NSRange(location: bold, length: 11)), "a **bZold**")
        XCTAssertGreaterThan(x(bold + 4, in: textView) - x(bold + 2, in: textView), 5, "the line is open")
        let font = try XCTUnwrap(textView.textStorage?.attribute(.font, at: bold + 5, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.pointSize, NoteStyler.bodySize, accuracy: 0.01, "the typed letter in the bold's face, not a hidden one")
    }
}
#endif
