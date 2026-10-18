#if os(iOS)
import XCTest
import SwiftUI
import UIKit
@testable import NoteKit

/// The phone's text view: a task's box ticks from a tap on it, in the editor and in a view that only shows the note,
/// and a view that fits its height grows to the note inside a page's scroll view.
@MainActor final class PhoneTests: XCTestCase {
    private let note = "- [ ] milk\n- [x] eggs\n" + (1...40).map { "line \($0) of a note long enough to scroll" }.joined(separator: "\n")
    private var url: URL!

    private func make(editable: Bool, ticks: Bool? = nil, fitsHeight: Bool = false) async throws -> (NoteSession, UITextView, UIWindow) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent("Phone.md")
        try Data(note.utf8).write(to: url)
        let session = NoteSession(url: url); await session.open()
        let view = NoteTextView(session: session, editable: editable, ticks: ticks, fitsHeight: fitsHeight)
        let root: AnyView = fitsHeight ? AnyView(ScrollView { VStack { Text("Title"); view } }) : AnyView(view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        let textView = try XCTUnwrap(Self.find(in: window))
        // The caret off the tasks, so an editor that took focus shows their boxes painted, not as written.
        textView.selectedRange = NSRange(location: textView.text.utf16.count, length: 0)
        textView.textLayoutManager?.ensureLayout(for: textView.textLayoutManager!.documentRange)
        return (session, textView, window)
    }
    static func find(in view: UIView) -> UITextView? {
        if let textView = view as? UITextView { return textView }
        for subview in view.subviews { if let found = find(in: subview) { return found } }
        return nil
    }
    /// The centre of the box on the paragraph at `offset`, in the text view.
    private func box(at offset: Int, in textView: UITextView) throws -> CGPoint {
        let manager = textView.textLayoutManager!, content = manager.textContentManager!
        // Laid out again first: a tick makes the line anew.
        manager.ensureLayout(for: manager.documentRange)
        let fragment = try XCTUnwrap(manager.textLayoutFragment(for: content.location(content.documentRange.location, offsetBy: offset)!) as? NoteFragment)
        let rect = try XCTUnwrap(fragment.paintRects(fragment.paints).first { if case .task = $0.0 { true } else { false } }?.1)
        let frame = fragment.layoutFragmentFrame, inset = textView.textContainerInset
        return CGPoint(x: rect.midX + frame.minX + inset.left, y: rect.midY + frame.minY + inset.top)
    }
    /// A tap at `point`, as the box's recognizer handles one: it hits a box, and ticks the paragraph it hit.
    private func tap(_ textView: UITextView, at point: CGPoint) -> Bool {
        let coordinator = textView.delegate as! NoteTextView.Coordinator
        guard let paragraph = coordinator.task(at: point, in: textView) else { return false }
        coordinator.tick(paragraph: paragraph, in: textView)
        return true
    }

    func testATapOnABoxTicksItInTheEditor() async throws {
        let (session, textView, window) = try await make(editable: true)
        defer { _ = window }
        XCTAssertTrue(tap(textView, at: try box(at: 0, in: textView)))
        XCTAssertTrue(textView.text.hasPrefix("- [x] milk\n- [x] eggs"))
        XCTAssertEqual(session.text, textView.text, "the session has the edit, to save")
        // 44 points across, centred on the box: a little off it still ticks; the text beside it doesn't.
        let centre = try box(at: 0, in: textView)
        XCTAssertTrue(tap(textView, at: CGPoint(x: centre.x + 12, y: centre.y)))
        XCTAssertTrue(textView.text.hasPrefix("- [ ] milk"))
        XCTAssertFalse(tap(textView, at: CGPoint(x: centre.x + 60, y: centre.y)))
    }

    func testAViewThatOnlyShowsTheNoteTicksWhenAskedAndSavesTheFile() async throws {
        let (_, inert, inertWindow) = try await make(editable: false)
        defer { _ = inertWindow }
        XCTAssertFalse(tap(inert, at: try box(at: 0, in: inert)), "by default, a view that only shows the note never ticks")
        let (session, textView, window) = try await make(editable: false, ticks: true)
        defer { _ = window }
        XCTAssertTrue(tap(textView, at: try box(at: 0, in: textView)))
        XCTAssertTrue(textView.text.hasPrefix("- [x] milk"))
        XCTAssertFalse(textView.isEditable)
        // Written straight away, with no pause to wait out: nothing on the page would show one.
        for _ in 0..<20 where session.status != .saved { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertEqual(session.status, .saved)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).hasPrefix("- [x] milk\n- [x] eggs\nline 1"), "written to the file")
    }

    func testAViewThatFitsItsHeightGrowsToTheNote() async throws {
        let (session, textView, window) = try await make(editable: false, fitsHeight: true)
        defer { _ = window }
        XCTAssertFalse(textView.isScrollEnabled)
        let laidOut = textView.sizeThatFits(CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)).height
        XCTAssertGreaterThan(textView.bounds.height, 600, "taller than the window: the page scrolls, not the text")
        XCTAssertEqual(textView.bounds.height, laidOut, accuracy: 1)
        // Another app shortens the note: the view shrinks to it.
        try await Task.sleep(for: .milliseconds(20))
        try Data("- [ ] milk\nshort now".utf8).write(to: url)
        await session.checkForOutsideChange()
        for _ in 0..<20 where textView.bounds.height > 200 { try await Task.sleep(for: .milliseconds(25)); window.layoutIfNeeded() }
        XCTAssertEqual(textView.text, "- [ ] milk\nshort now")
        XCTAssertLessThan(textView.bounds.height, 200)
    }
}
#endif
