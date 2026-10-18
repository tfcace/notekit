import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Where the text sits in its view. On the Mac the text runs in a column centred in the view, `column` wide at most,
/// with at least `margin` at either side and `top` above the first line and below the last. On iOS `margin`, `top`
/// and `bottom` are the text's insets; a view that fits its height has none.
public struct NoteLayout: Equatable, Sendable {
    public var column: CGFloat
    public var margin: CGFloat
    public var top: CGFloat
    public var bottom: CGFloat

    public init(column: CGFloat, margin: CGFloat, top: CGFloat, bottom: CGFloat) {
        self.column = column; self.margin = margin; self.top = top; self.bottom = bottom
    }

    public static var standard: NoteLayout {
        #if os(macOS)
        NoteLayout(column: 860, margin: 28, top: 28, bottom: 28)
        #else
        NoteLayout(column: .greatestFiniteMagnitude, margin: 14, top: 16, bottom: 32)
        #endif
    }
}

/// What a host can add to the text view without the editor knowing what it's for: ranges of the text kept off the
/// page, room after a paragraph, drawing behind the text, its own handling of a command or the pointer, and word of
/// the text and its layout changing. Every method has a default that adds nothing.
///
/// One hooks object serves one text view; pass it to `NoteTextView(session:hooks:)` and keep it alive as long as the
/// view (a `@StateObject`, say). The editor holds the hooks strongly; the proxy it hands them holds the text view
/// weakly, so the hooks may keep the proxy without keeping the view alive.
@MainActor public protocol NoteTextHooks: AnyObject {
    /// The text view is up: `editor` reaches it for as long as it lives.
    func attach(_ editor: NoteEditorProxy)
    /// The text view is going away.
    func detach(_ editor: NoteEditorProxy)

    /// Ranges of the text kept off the page: each paragraph starting inside one takes no room and draws nothing, the
    /// caret never rests inside one, and no edit reaches one. The text keeps them byte for byte. Asked when the text
    /// loads, after every edit, and on `NoteEditorProxy.invalidateLayout()`.
    func hiddenRanges(in text: String) -> [NSRange]
    /// Extra room below a paragraph, added to the height it lays out at (`height`, its fragment's own). Asked each
    /// time the paragraph is laid out, so it should be quick; nothing changes until the layout is invalidated.
    func spaceAfter(_ paragraph: NSTextLayoutFragment, height: CGFloat, in editor: NoteEditorProxy) -> CGFloat

    /// The session's text has just been put into the view: on opening, and when the file changed elsewhere.
    func textDidLoad(_ editor: NoteEditorProxy)
    /// An edit has landed and been styled (during an input method's composition, before it is).
    func textDidChange(_ editor: NoteEditorProxy)
    /// The view was laid out again: invalidated, or resized.
    func layoutDidChange(_ editor: NoteEditorProxy)

    #if os(macOS)
    /// Draws under the text, in the text view's coordinates, into the current graphics context.
    func drawBehindText(in dirtyRect: CGRect, _ editor: NoteEditorProxy)
    /// A command the text view is about to perform (Shift-Tab's `insertBacktab:`, Esc's `cancelOperation:`, any
    /// key binding's). True when the hooks handled it and the text view should not.
    func perform(_ command: Selector, _ editor: NoteEditorProxy) -> Bool
    /// The pointer moved to `point` (the text view's coordinates), or left the view (nil). A cursor to show there
    /// instead of the text's, or nil for the text's own.
    func cursor(at point: CGPoint?, _ editor: NoteEditorProxy) -> NSCursor?
    /// Areas of the text view with a cursor of their own, as AppKit's cursor rects. Asked whenever the window resets
    /// them; call `invalidateCursorRects(for:)` on the window when they move.
    func cursorRects(_ editor: NoteEditorProxy) -> [(rect: CGRect, cursor: NSCursor)]
    #endif
}

public extension NoteTextHooks {
    func attach(_ editor: NoteEditorProxy) {}
    func detach(_ editor: NoteEditorProxy) {}
    func hiddenRanges(in text: String) -> [NSRange] { [] }
    func spaceAfter(_ paragraph: NSTextLayoutFragment, height: CGFloat, in editor: NoteEditorProxy) -> CGFloat { 0 }
    func textDidLoad(_ editor: NoteEditorProxy) {}
    func textDidChange(_ editor: NoteEditorProxy) {}
    func layoutDidChange(_ editor: NoteEditorProxy) {}
    #if os(macOS)
    func drawBehindText(in dirtyRect: CGRect, _ editor: NoteEditorProxy) {}
    func perform(_ command: Selector, _ editor: NoteEditorProxy) -> Bool { false }
    func cursor(at point: CGPoint?, _ editor: NoteEditorProxy) -> NSCursor? { nil }
    func cursorRects(_ editor: NoteEditorProxy) -> [(rect: CGRect, cursor: NSCursor)] { [] }
    #endif
}

/// The hooks' handle on one text view: the view itself, for placing things on it and reading its layout, and the few
/// things only the editor can do.
@MainActor public final class NoteEditorProxy {
    #if os(macOS)
    public typealias TextView = NSTextView
    #else
    public typealias TextView = UITextView
    #endif
    /// The text view, while it's up. Its text is the session's as edited; change it only through its own edit path.
    public private(set) weak var textView: TextView?
    weak var coordinator: NoteTextView.Coordinator?
    init(textView: TextView, coordinator: NoteTextView.Coordinator) { self.textView = textView; self.coordinator = coordinator }

    /// The session the view edits.
    public var session: NoteSession? { coordinator?.session }
    /// The hidden ranges as the hooks last gave them.
    public var hiddenRanges: [NSRange] { coordinator?.hidden ?? [] }

    /// Asks the hooks for their hidden ranges again and lays the whole note out again: the caret leaves any range now
    /// hidden, and `layoutDidChange` follows. For a change in what the hooks hide, or in the room they add.
    public func invalidateLayout() {
        guard let textView, let coordinator else { return }
        #if os(macOS)
        coordinator.updateHidden(textView.string)
        #else
        coordinator.updateHidden(textView.text)
        #endif
        NoteTextView.relayout(textView, coordinator)
    }

    #if os(macOS)
    /// Room above the first line (and below the last) in place of the layout's `top`, while set.
    public var topInset: CGFloat? {
        get { (textView as? ReadableTextView)?.topInset }
        set { (textView as? ReadableTextView)?.topInset = newValue }
    }
    #endif
}
