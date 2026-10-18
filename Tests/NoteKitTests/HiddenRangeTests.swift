import XCTest
import SwiftUI
@testable import NoteKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A host's hooks hiding the note's first lines, as a host might hide its frontmatter: `hiding` decides.
@MainActor final class HideTop: NoteTextHooks {
    var hiding = true
    let lines: Int
    var editor: NoteEditorProxy?
    var loads = 0, changes = 0, layouts = 0
    init(lines: Int) { self.lines = lines }
    func attach(_ editor: NoteEditorProxy) { self.editor = editor }
    func hiddenRanges(in text: String) -> [NSRange] {
        guard hiding else { return [] }
        let string = text as NSString
        var end = 0
        for _ in 0..<lines where end < string.length { end = NSMaxRange(string.lineRange(for: NSRange(location: end, length: 0))) }
        return [NSRange(location: 0, length: end)]
    }
    func textDidLoad(_ editor: NoteEditorProxy) { loads += 1 }
    func textDidChange(_ editor: NoteEditorProxy) { changes += 1 }
    func layoutDidChange(_ editor: NoteEditorProxy) { layouts += 1 }
}

enum TestViews {
    #if os(macOS)
    static func find(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for child in view.subviews { if let found = find(in: child) { return found } }
        return nil
    }
    #else
    static func find(in view: UIView) -> UITextView? {
        if let textView = view as? UITextView { return textView }
        for child in view.subviews { if let found = find(in: child) { return found } }
        return nil
    }
    #endif
}

#if os(macOS)
/// Ranges a host hides: still in the text, gone from the page, out of the caret's reach, written back exactly.
@MainActor final class HiddenRangeTests: XCTestCase {
    private let top = "---\ntags:\n  - home\ncreated: 2026-08-16\n---\n"
    private var url: URL!
    override func setUp() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent("Hidden.md")
        try Data((top + "# Body\nKitchen nook\nשורה בעברית\n" + (1...60).map { "Line \($0)" }.joined(separator: "\n") + "\n").utf8).write(to: url)
    }
    private func make(hiding: Bool) async throws -> (NoteSession, NSTextView, HideTop, NSWindow) {
        let session = NoteSession(url: url); await session.open()
        let hooks = HideTop(lines: 5); hooks.hiding = hiding
        let host = NSHostingView(rootView: NoteTextView(session: session, hooks: hooks).frame(width: 600, height: 300))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; host.layoutSubtreeIfNeeded()
        let textView = try XCTUnwrap(TestViews.find(in: host))
        textView.textLayoutManager?.ensureLayout(for: textView.textLayoutManager!.documentRange)
        return (session, textView, hooks, window)
    }
    /// Each paragraph's frame, in document order.
    private func frames(_ textView: NSTextView) -> [CGRect] {
        var frames: [CGRect] = []
        let manager = textView.textLayoutManager!
        manager.enumerateTextLayoutFragments(from: manager.documentRange.location, options: [.ensuresLayout]) { frames.append($0.layoutFragmentFrame); return true }
        return frames
    }

    func testAHiddenRangeTakesNoRoomAndTheTextAfterItStartsAtTheTop() async throws {
        let (_, hidden, _, hiddenWindow) = try await make(hiding: true)
        let (_, shown, _, shownWindow) = try await make(hiding: false)
        defer { _ = (hiddenWindow, shownWindow) }
        let hiddenFrames = frames(hidden), shownFrames = frames(shown)
        XCTAssertEqual(hiddenFrames.prefix(5).map(\.height), [0, 0, 0, 0, 0], "the hidden range's five lines lay out with no height")
        XCTAssertEqual(hiddenFrames[5].minY, shownFrames[0].minY, accuracy: 0.5, "the next line sits where the first would")
        XCTAssertGreaterThan(shownFrames[5].minY, 80, "not hidden, the lines take their room")
        XCTAssertEqual(hidden.string, shown.string, "the text is the same either way")
    }
    func testTheCaretStaysOutOfAHiddenRange() async throws {
        let (session, textView, _, _) = try await make(hiding: true)
        let end = (top as NSString).length
        XCTAssertEqual(textView.selectedRange().location, end, "on load the caret is the first character after it")
        textView.setSelectedRange(NSRange(location: 3, length: 0)); XCTAssertEqual(textView.selectedRange().location, end)
        textView.moveToBeginningOfDocument(nil); XCTAssertEqual(textView.selectedRange().location, end)
        textView.moveUp(nil); XCTAssertEqual(textView.selectedRange().location, end, "↑ on the first line after it stays")
        textView.selectAll(nil); XCTAssertEqual(textView.selectedRange().location, end, "⌘A selects what's shown, never the hidden range")
        XCTAssertEqual(session.caret, end)
    }
    func testTypingAndSavingKeepAHiddenRangeByteForByte() async throws {
        let (session, textView, _, _) = try await make(hiding: true)
        let end = (top as NSString).length
        textView.setSelectedRange(NSRange(location: end + 2, length: 0))
        textView.insertText("XY", replacementRange: textView.selectedRange())
        // ⌫ at the first character after it can't eat its last newline.
        textView.setSelectedRange(NSRange(location: end, length: 0)); textView.deleteBackward(nil)
        let expected = top + "# XYBody"
        XCTAssertEqual(String(textView.string.prefix(expected.count)), expected)
        await session.save()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8).prefix(top.count + 8), Substring(top + "# XYBody"))
        // A revert through the text view's own change path (what undo does): the text comes back, the range stays hidden.
        let typed = NSRange(location: end + 2, length: 2)
        XCTAssertTrue(textView.shouldChangeText(in: typed, replacementString: ""))
        textView.textStorage?.replaceCharacters(in: typed, with: ""); textView.didChangeText()
        textView.textLayoutManager?.ensureLayout(for: textView.textLayoutManager!.documentRange)
        XCTAssertTrue(textView.string.hasPrefix(top + "# Body"), String(textView.string.prefix(55)))
        XCTAssertEqual(frames(textView).prefix(5).map(\.height), [0, 0, 0, 0, 0])
    }
    func testAnOutsideChangeUnderADirtyEditStillShowsAConflict() async throws {
        let (session, textView, _, _) = try await make(hiding: true)
        textView.insertText("Z", replacementRange: NSRange(location: (top as NSString).length + 2, length: 0))
        try Data("---\ntags:\n  - theirs\n---\nTheirs\n".utf8).write(to: url)
        await session.checkForOutsideChange()
        XCTAssertEqual(session.status, .changedElsewhere)
    }
    /// The hooks stop hiding and ask for a new layout: the lines come back, and go again when they hide them again.
    func testInvalidatingTheLayoutShowsAndHidesAgain() async throws {
        let (_, textView, hooks, window) = try await make(hiding: true)
        defer { _ = window }
        XCTAssertEqual(hooks.loads, 1, "the hooks heard the text load")
        XCTAssertEqual(frames(textView).prefix(5).map(\.height), [0, 0, 0, 0, 0])
        hooks.hiding = false
        let before = hooks.layouts
        hooks.editor?.invalidateLayout()
        XCTAssertGreaterThan(hooks.layouts, before, "the hooks heard of the new layout")
        XCTAssertTrue(frames(textView).prefix(5).allSatisfy { $0.height > 10 }, "the lines have their height: \(frames(textView).prefix(5).map(\.height))")
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        XCTAssertEqual(textView.selectedRange().location, 4, "and the caret can go into them")
        hooks.hiding = true
        hooks.editor?.invalidateLayout()
        XCTAssertEqual(frames(textView).prefix(5).map(\.height), [0, 0, 0, 0, 0], "hidden again")
        XCTAssertEqual(textView.selectedRange().location, (top as NSString).length, "the caret left them")
    }
}

/// The rest of what the hooks can add: room after a paragraph, a command of their own, a cursor.
@MainActor final class HookTests: XCTestCase {
    @MainActor final class Room: NoteTextHooks {
        var after = 0, room: CGFloat = 40
        var commands: [Selector] = []
        func spaceAfter(_ paragraph: NSTextLayoutFragment, height: CGFloat, in editor: NoteEditorProxy) -> CGFloat {
            guard let content = paragraph.textLayoutManager?.textContentManager else { return 0 }
            return content.offset(from: content.documentRange.location, to: paragraph.rangeInElement.location) == after ? room : 0
        }
        func perform(_ command: Selector, _ editor: NoteEditorProxy) -> Bool {
            commands.append(command)
            return command == #selector(NSResponder.insertBacktab(_:))
        }
        func cursor(at point: CGPoint?, _ editor: NoteEditorProxy) -> NSCursor? { point.map { $0.y < 50 ? .pointingHand : nil } ?? nil }
    }
    func testRoomAfterAParagraphAndCommandsGoToTheHooksFirst() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try Data("One\nTwo\nThree\n".utf8).write(to: url)
        let session = NoteSession(url: url); await session.open()
        let hooks = Room()
        let host = NSHostingView(rootView: NoteTextView(session: session, hooks: hooks).frame(width: 500, height: 300))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; host.layoutSubtreeIfNeeded()
        defer { _ = window }
        let textView = try XCTUnwrap(TestViews.find(in: host))
        let manager = textView.textLayoutManager!
        var frames: [CGRect] = []
        manager.enumerateTextLayoutFragments(from: manager.documentRange.location, options: [.ensuresLayout]) { frames.append($0.layoutFragmentFrame); return true }
        XCTAssertEqual(frames[1].minY - frames[0].maxY, 0, accuracy: 0.5, "the second line follows the first's room")
        XCTAssertEqual(frames[0].height - frames[1].height, 40, accuracy: 0.5, "the first paragraph has the 40 points asked for after it")
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        textView.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
        textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(hooks.commands, [#selector(NSResponder.insertBacktab(_:)), #selector(NSResponder.insertNewline(_:))])
        XCTAssertEqual(textView.string, "One\n\nTwo\nThree\n", "the command the hooks left (a newline) went to the text, the one they took didn't")
    }
}
#endif

#if os(iOS)
/// A hidden range on iOS: out of the page and out of reach, back when the hooks stop hiding it, the file untouched.
@MainActor final class HiddenRangeIOSTests: XCTestCase {
    func testAHiddenRangeTakesNoRoomAndIsOutOfReachThenComesBack() async throws {
        let top = "---\ntags:\n  - a\ntitle: Hidden\n---\n"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Hidden.md")
        try Data((top + "Body\nMore\n").utf8).write(to: url)
        let session = NoteSession(url: url); await session.open()
        let hooks = HideTop(lines: 5)
        let controller = UIHostingController(rootView: NoteTextView(session: session, hooks: hooks).frame(width: 390, height: 600))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        window.rootViewController = controller; window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        let textView = try XCTUnwrap(TestViews.find(in: controller.view))
        func heights() -> [CGFloat] {
            let manager = textView.textLayoutManager!
            var out: [CGFloat] = []
            manager.enumerateTextLayoutFragments(from: manager.documentRange.location, options: [.ensuresLayout]) { out.append($0.layoutFragmentFrame.height); return true }
            return out
        }
        let end = (top as NSString).length
        XCTAssertEqual(heights().prefix(5), [0, 0, 0, 0, 0], "hidden, the five lines take no room")
        XCTAssertEqual(textView.selectedRange.location, end, "the caret starts after them")
        textView.selectedRange = NSRange(location: 2, length: 0)
        XCTAssertEqual(textView.selectedRange.location, end, "and can't be put inside them")
        XCTAssertFalse(textView.delegate!.textView!(textView, shouldChangeTextIn: NSRange(location: 3, length: 1), replacementText: "x"), "nothing typed reaches them")
        hooks.hiding = false
        hooks.editor?.invalidateLayout()
        controller.view.layoutIfNeeded()
        XCTAssertTrue(heights().prefix(5).allSatisfy { $0 > 10 }, "shown, the lines are back in the page: \(heights())")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), top + "Body\nMore\n", "the file is as it was")
        _ = window
    }
}
#endif
