#if os(macOS)
import XCTest
import SwiftUI
@testable import NoteKit

/// An app's colours changing while a note is open: the open editor wears the new ones at once, as the rest of the app does.
@MainActor final class ColorsTests: XCTestCase {
    nonisolated private static func color(_ light: UInt32, _ dark: UInt32) -> NSColor {
        func make(_ hex: UInt32) -> NSColor { NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1) }
        return NSColor(name: "test-\(light)-\(dark)") { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? make(dark) : make(light) }
    }
    private let custom = NoteColors(text: ColorsTests.color(0x272e25, 0xedf0e8), secondary: ColorsTests.color(0x656e61, 0xa9b2a3), accent: ColorsTests.color(0x3b5232, 0xc1d3aa), onAccent: ColorsTests.color(0xfffefa, 0x262923),
                                  codeBackground: ColorsTests.color(0xeeeee7, 0x22251f), highlight: ColorsTests.color(0xe7ecdf, 0x323d2b), rule: ColorsTests.color(0xdcded3, 0x3d4539))
    private let blue = NoteColors(text: ColorsTests.color(0x1d2733, 0xe8f0f6), secondary: ColorsTests.color(0x5d6a78, 0xa4b0bd), accent: ColorsTests.color(0x2f4a6b, 0xb5c8df), onAccent: ColorsTests.color(0xf7f9fc, 0x23292d),
                                  codeBackground: ColorsTests.color(0xe9edf2, 0x1f2529), highlight: ColorsTests.color(0xe2e9f1, 0x263240), rule: ColorsTests.color(0xd5dce4, 0x3a434e))
    final class Choice: ObservableObject { @Published var colors: NoteColors; init(_ colors: NoteColors) { self.colors = colors } }
    struct Harness: View {
        @ObservedObject var choice: Choice
        let session: NoteSession
        var body: some View { NoteTextView(session: session).noteColors(choice.colors).frame(width: 500, height: 200) }
    }

    private func hex(_ color: Any?, dark: Bool) -> UInt32? {
        guard let color = color as? NSColor else { return nil }
        var resolved: NSColor?
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) }
        guard let c = resolved else { return nil }
        return UInt32((c.redComponent * 255).rounded()) << 16 | UInt32((c.greenComponent * 255).rounded()) << 8 | UInt32((c.blueComponent * 255).rounded())
    }

    func testAnOpenEditorTakesNewColorsWithoutReopening() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try Data("Plain words and a [link](https://example.com)\n".utf8).write(to: url)
        let session = NoteSession(url: url); await session.open()
        let choice = Choice(custom)
        let host = NSHostingView(rootView: Harness(choice: choice, session: session))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; host.layoutSubtreeIfNeeded()
        defer { _ = window }
        let textView = try XCTUnwrap(TestViews.find(in: host))
        let storage = try XCTUnwrap(textView.textStorage)
        let link = (storage.string as NSString).range(of: "link").location
        XCTAssertEqual(hex(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil), dark: true), 0xedf0e8, "the given text colour to start")

        choice.colors = blue
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(hex(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil), dark: true), 0xe8f0f6, "the body text is the new text colour")
        XCTAssertEqual(hex(storage.attribute(.foregroundColor, at: link, effectiveRange: nil), dark: false), 0x2f4a6b, "a link is the new accent")
        XCTAssertEqual(hex(textView.insertionPointColor, dark: false), 0x2f4a6b, "the caret is the new accent")
        XCTAssertEqual(hex(textView.typingAttributes[.foregroundColor], dark: true), 0xe8f0f6, "what's typed next is the new text colour")
    }

    /// With nothing set, the system's colours: the text follows the system's own text colour.
    func testTheDefaultIsTheSystems() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try Data("Plain\n".utf8).write(to: url)
        let session = NoteSession(url: url); await session.open()
        let host = NSHostingView(rootView: NoteTextView(session: session).frame(width: 500, height: 200))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; host.layoutSubtreeIfNeeded()
        defer { _ = window }
        let storage = try XCTUnwrap(TestViews.find(in: host)?.textStorage)
        XCTAssertEqual(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, NSColor.textColor)
    }
}
#endif
