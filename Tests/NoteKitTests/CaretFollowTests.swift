#if os(macOS)
import XCTest
import SwiftUI
@testable import NoteKit

/// The view follows the caret a line at a time, never by a leap: the place being read stays where the eye left it.
@MainActor final class CaretFollowTests: XCTestCase {
    private let visible = NSRect(x: 0, y: 1000, width: 600, height: 300)
    private func line(_ top: CGFloat, height: CGFloat = 20) -> NSRect { NSRect(x: 0, y: top, width: 600, height: height) }

    func testALineAlreadyInViewDoesNotScroll() {
        XCTAssertEqual(ReadableTextView.CaretFollow.origin(forLine: line(1100), visible: visible, documentHeight: 5000, current: 1000), 1000)
    }
    func testTheCaretReachingTheBottomScrollsOneLineKeepingTheNextInView() {
        // The line that ends 20pt above the bottom edge is within the margin (30pt): the view moves so a line and a half shows below it.
        let y = ReadableTextView.CaretFollow.origin(forLine: line(1260), visible: visible, documentHeight: 5000, current: 1000)
        XCTAssertEqual(y, 1280 + 30 - 300)
        XCTAssertEqual(y - 1000, 10, "a small step, not a leap")
        // The next line down: exactly one line further.
        let next = ReadableTextView.CaretFollow.origin(forLine: line(1280), visible: visible.offsetBy(dx: 0, dy: y - 1000), documentHeight: 5000, current: y)
        XCTAssertEqual(next - y, 20)
    }
    func testTheCaretReachingTheTopScrollsUpOneLine() {
        let y = ReadableTextView.CaretFollow.origin(forLine: line(1010), visible: visible, documentHeight: 5000, current: 1000)
        XCTAssertEqual(y, 1010 - 30)
    }
    func testTheFirstAndLastLinesGoAllTheWayToTheEdge() {
        // The first line sits 28pt in (the inset); the margin rule alone would leave the view 2pt down. The top is the top.
        XCTAssertEqual(ReadableTextView.CaretFollow.origin(forLine: line(32), visible: NSRect(x: 0, y: 2, width: 600, height: 300), documentHeight: 5000, current: 2), 0)
        // And the last line: the view goes to the very end rather than stopping a few points short.
        XCTAssertEqual(ReadableTextView.CaretFollow.origin(forLine: line(4960), visible: NSRect(x: 0, y: 4680, width: 600, height: 300), documentHeight: 5000, current: 4680), 4700)
    }
    func testAFarMoveLandsTheCaretAThirdOfTheWayDown() {
        let y = ReadableTextView.CaretFollow.origin(forLine: line(4000), visible: visible, documentHeight: 5000, current: 1000)
        XCTAssertEqual(y, 4000 - 100)
        // And never past the document's ends.
        XCTAssertEqual(ReadableTextView.CaretFollow.origin(forLine: line(4990), visible: visible, documentHeight: 5000, current: 1000), 4700)
        XCTAssertEqual(ReadableTextView.CaretFollow.origin(forLine: line(0), visible: visible, documentHeight: 5000, current: 1000), 0)
    }
    func testInTheRealTextViewArrowingDownScrollsALineAtATime() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Long.md")
        try Data((1...200).map { "Line \($0)" }.joined(separator: "\n").utf8).write(to: url)
        let session = NoteSession(url: url); await session.open()
        let host = NSHostingView(rootView: NoteTextView(session: session).frame(width: 600, height: 300))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; host.layoutSubtreeIfNeeded()
        let textView = try XCTUnwrap(Self.textView(in: host)), scroll = try XCTUnwrap(textView.enclosingScrollView)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        var origins: [CGFloat] = []
        for _ in 0..<40 { textView.moveDown(nil); origins.append(scroll.contentView.bounds.origin.y) }
        let steps = zip(origins, origins.dropFirst()).map { $1 - $0 }.filter { $0 != 0 }
        XCTAssertFalse(steps.isEmpty, "the caret left the first screen")
        let lineHeight = try XCTUnwrap(steps.first)
        for step in steps { XCTAssertEqual(step, lineHeight, accuracy: 1, "every scroll is one line, never a leap") }
        XCTAssertLessThan(lineHeight, 40)
        // Back to the top in one move: the caret lands with the top in view, no further than the document allows.
        textView.moveToBeginningOfDocument(nil)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0)
    }
    private static func textView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for child in view.subviews { if let found = textView(in: child) { return found } }
        return nil
    }
}

/// A view that only shows a note: selectable, never editable, and still following the file.
@MainActor final class ReadOnlyNoteTests: XCTestCase {
    func testAReadOnlyViewTakesNoTypingButStillShowsAnOutsideChange() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Read.md")
        try Data("First\n".utf8).write(to: url)
        let session = NoteSession(url: url); await session.open()
        let host = NSHostingView(rootView: NoteEditorView(session: session, editable: false).frame(width: 400, height: 200))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; host.layoutSubtreeIfNeeded()
        let textView = try XCTUnwrap(find(in: host))
        XCTAssertFalse(textView.isEditable); XCTAssertTrue(textView.isSelectable, "copying out is still allowed")
        textView.insertText("typed", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(textView.string, "First\n", "typing changes nothing")
        XCTAssertEqual(session.status, .ready); XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "First\n")
        // The file changes elsewhere: the view follows, with no conflict possible.
        try Data("Second\n".utf8).write(to: url)
        await session.checkForOutsideChange()
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(session.text, "Second\n"); XCTAssertEqual(textView.string, "Second\n")
        XCTAssertNotEqual(session.status, .changedElsewhere)
    }
    private func find(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for child in view.subviews { if let found = find(in: child) { return found } }
        return nil
    }
}
#endif
