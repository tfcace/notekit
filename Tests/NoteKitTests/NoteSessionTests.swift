#if os(macOS)
import XCTest
import SwiftUI
@testable import NoteKit

/// The editor writes your notes, so these check the promises about the file: nothing written unless you edit, an
/// edit lands, and another app's change is never silently overwritten.
@MainActor final class NoteSessionTests: XCTestCase {
    private var url: URL!

    override func setUp() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent("Measures.md")
        try Data("Cutlery drawer\r\n49.5 cm\r\n".utf8).write(to: url)
    }

    private func contents() throws -> String { try String(contentsOf: url, encoding: .utf8) }

    func testTypingSavesTheNoteInPlace() async throws {
        let created = try FileManager.default.attributesOfItem(atPath: url.path)[.creationDate] as? Date
        let session = NoteSession(url: url)
        await session.open()
        XCTAssertEqual(session.text, "Cutlery drawer\n49.5 cm\n")
        // Type through a real text view, the way the window does.
        let host = NSHostingView(rootView: NoteTextView(session: session).frame(width: 600, height: 400))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let textView = try XCTUnwrap(Self.textView(in: host))
        XCTAssertEqual(textView.string, "Cutlery drawer\n49.5 cm\n")
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        textView.insertText("35.5 **cm**", replacementRange: textView.selectedRange())
        XCTAssertEqual(session.status, .editing, "the footer says the edit is still unsaved")
        await session.save()
        XCTAssertEqual(session.status, .saved)
        XCTAssertEqual(try contents(), "Cutlery drawer\r\n49.5 cm\r\n35.5 **cm**", "Windows line endings kept")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.creationDate] as? Date, created, "creation date kept: Obsidian sorts by it")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path), ["Measures.md"], "no draft left beside the note")
        XCTAssertNotNil(textView.textLayoutManager, "still TextKit 2")
    }

    func testTheCaretIsReportedAndASessionOpenedToContinueStartsThere() async throws {
        let session = NoteSession(url: url)
        await session.open()
        let host = NSHostingView(rootView: NoteTextView(session: session).frame(width: 600, height: 400))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let textView = try XCTUnwrap(Self.textView(in: host))
        textView.setSelectedRange(NSRange(location: 15, length: 0))
        XCTAssertEqual(session.caret, 15, "the view reports where the caret is")
        XCTAssertEqual(NoteSession.live(for: url)?.caret, 15, "and the session can be found by its file")
        // Another view of the same note, opened to continue elsewhere, starts at that caret, not at the top.
        let beside = NoteSession(url: url)
        beside.caret = session.caret
        await beside.open()
        let host2 = NSHostingView(rootView: NoteTextView(session: beside).frame(width: 600, height: 400))
        let window2 = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window2.contentView = host2
        host2.layoutSubtreeIfNeeded()
        XCTAssertEqual(try XCTUnwrap(Self.textView(in: host2)).selectedRange().location, 15)
        // A reload from the file keeps the view's own caret, as before.
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        try Data("Cutlery drawer\r\n50 cm\r\n".utf8).write(to: url)
        await session.checkForOutsideChange()
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(textView.selectedRange().location, 3)
    }

    func testQuittingWritesWhatWasJustTyped() async throws {
        let session = NoteSession(url: url)
        await session.open()
        session.edited("typed a moment before ⌘Q")
        await NoteSession.saveAll()
        XCTAssertEqual(try contents(), "typed a moment before ⌘Q")
    }

    func testASaveBegunWhileAnotherIsWritingWaitsForIt() async throws {
        // Two boxes ticked in quick succession on the phone's page, each saved at once: the second save, begun at any
        // moment while the first reads and writes, isn't taken for another app's change.
        for delay in stride(from: 0, to: 2000, by: 25) {
            try Data("none".utf8).write(to: url)
            let session = NoteSession(url: url)
            await session.open()
            session.edited("first tick")
            let first = Task { await session.save() }
            try await Task.sleep(for: .microseconds(delay))
            session.edited("first tick, second tick")
            await session.save()
            await first.value
            XCTAssertEqual(session.status, .saved, "begun \(delay) µs after the first")
            XCTAssertEqual(try contents(), "first tick, second tick", "begun \(delay) µs after the first")
        }
    }

    func testAWriteThatFailsKeepsTheEditsAndTriesAgain() async throws {
        let session = NoteSession(url: url)
        await session.open()
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        session.edited("still here")
        await session.save()
        guard case .failed = session.status else { return XCTFail("expected a failed status, got \(session.status)") }
        XCTAssertEqual(session.text, "still here", "the text isn't thrown away with the error")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path), ["Measures.md"], "a failed write leaves no draft behind")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        await session.save()
        XCTAssertEqual(session.status, .saved)
        XCTAssertEqual(try contents(), "still here")
    }

    func testOpeningAndClosingWritesNothing() async throws {
        let before = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        let session = NoteSession(url: url)
        await session.open()
        session.edited(session.text)
        await session.close()
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, before)
    }

    func testAnOutsideChangeReloadsWhenNothingIsUnsaved() async throws {
        let session = NoteSession(url: url)
        await session.open()
        let revision = session.revision
        try Data("Cutlery drawer\n50 cm\n".utf8).write(to: url)
        await session.checkForOutsideChange()
        XCTAssertEqual(session.text, "Cutlery drawer\n50 cm\n")
        XCTAssertGreaterThan(session.revision, revision)
    }

    func testAnOutsideChangeUnderUnsavedEditsIsNeverOverwritten() async throws {
        let session = NoteSession(url: url)
        await session.open()
        session.edited("mine")
        try Data("theirs".utf8).write(to: url)
        await session.save()
        XCTAssertEqual(session.status, .changedElsewhere)
        XCTAssertEqual(try contents(), "theirs")
        await session.resolve(keepMine: true)
        XCTAssertEqual(try contents(), "mine")
    }

    func testTakingTheirVersionDropsMine() async throws {
        let session = NoteSession(url: url)
        await session.open()
        session.edited("mine")
        try Data("theirs".utf8).write(to: url)
        await session.checkForOutsideChange()
        XCTAssertEqual(session.status, .changedElsewhere)
        await session.resolve(keepMine: false)
        XCTAssertEqual(session.text, "theirs")
        await session.close()
        XCTAssertEqual(try contents(), "theirs")
    }

    private static func textView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for subview in view.subviews { if let found = textView(in: subview) { return found } }
        return nil
    }
}
#endif
