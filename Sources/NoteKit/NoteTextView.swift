import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The note editor: the system text view (TextKit 2), editing the Markdown source as plain text and styling it in
/// place. Substitutions that would change the Markdown as you type (smart quotes, dashes) are off.
public struct NoteTextView {
    @ObservedObject var session: NoteSession
    /// False for a view that only shows the note: the text can be selected and copied, never changed here. The
    /// session still follows the file, so an outside change still shows.
    let editable: Bool
    /// Whether a tap on a task's box ticks it. Always in a view that edits; on the phone, a view that only shows the
    /// note can tick too, saved through the session straight away. The Mac ticks only where it edits.
    let ticks: Bool
    /// On the phone: the view grows to the note's height instead of scrolling, to sit in a scroll view of its own.
    let fitsHeight: Bool
    /// Where the text sits in the view.
    let layout: NoteLayout
    /// What the host adds to the view; see `NoteTextHooks`.
    let hooks: NoteTextHooks?
    public init(session: NoteSession, editable: Bool = true, ticks: Bool? = nil, fitsHeight: Bool = false,
                layout: NoteLayout = .standard, hooks: NoteTextHooks? = nil) {
        self.session = session; self.editable = editable; self.ticks = ticks ?? editable; self.fitsHeight = fitsHeight
        self.layout = layout; self.hooks = hooks
    }

    public final class Coordinator: NSObject {
        let session: NoteSession
        var revision = -1
        /// The colours the text is styled in now.
        var colors = NoteColors.system
        /// The host's hooks, and their handle on this view.
        var hooks: NoteTextHooks?
        var proxy: NoteEditorProxy?
        /// The ranges the hooks keep off the page, in order.
        var hidden: [NSRange] = []
        /// The range an edit is about to replace, so only its paragraphs are restyled once it lands.
        var pending: NSRange?
        var needsFullStyle = false
        init(session: NoteSession) {
            self.session = session
            super.init()
        }

        /// A fence, frontmatter line or rule changes how every line after it reads, so editing one restyles the note.
        @MainActor func willChange(_ string: NSString, range: NSRange, replacement: String) {
            let paragraph = string.paragraphRange(for: range)
            let touched = string.substring(with: paragraph) + replacement
            needsFullStyle = needsFullStyle || ["```", "~~~", "---"].contains { touched.contains($0) }
            // Several ranges changed in one edit (ticking a few tasks at once) are restyled together.
            let changed = NSRange(location: range.location, length: (replacement as NSString).length)
            pending = pending.map { NSUnionRange($0, changed) } ?? changed
        }

        /// The painted markers the selection is showing as written, as their paragraphs' marker runs.
        var revealed: [NSRange] = []
        /// The paragraph whose hidden markers are showing as written.
        var opened: NSRange?
        /// Whether the selection may show markers as written: false for a view that only shows the note.
        var reveals = true
        /// Whether a tap on a box ticks it.
        var ticks = true
        /// Through a click sequence the opened paragraph stays as it was, so the second click of a double-click lands
        /// on the layout the first one saw; the selection's opens once the sequence is over, or at the first key.
        var held = false
        var unholding: DispatchWorkItem?

        @MainActor func restyle(_ storage: NSTextStorage, selection: NSRange) {
            held = false; unholding?.cancel(); unholding = nil
            let revealing = reveals && selection.location != NSNotFound ? selection : nil
            NoteStyler.style(storage, paragraphsAround: needsFullStyle ? nil : pending.map { [$0] }, revealing: revealing, opening: revealing, colors: colors)
            revealed = revealing.map { NoteStyler.markerRuns(touching: $0, in: storage) } ?? []
            opened = revealing.flatMap { NoteStyler.openParagraph(for: $0, in: storage) }
            pending = nil; needsFullStyle = false
        }

        /// The selection moved: the painted markers it now touches and the hidden ones in its paragraph show as
        /// written, and those it left are rendered again. Only the paragraphs involved are restyled, and only when
        /// that changes. True when it did, so the caller can give typing the attributes of the text as it now is.
        @MainActor @discardableResult func reveal(_ storage: NSTextStorage, selection: NSRange) -> Bool {
            guard reveals else { return false }
            let runs = NoteStyler.markerRuns(touching: selection, in: storage)
            let open = held ? opened : NoteStyler.openParagraph(for: selection, in: storage)
            guard runs != revealed || open != opened else { return false }
            let length = storage.length
            let involved = (revealed + runs + [opened, open].compactMap { $0 }).filter { NSMaxRange($0) <= length }
            revealed = runs; opened = open
            NoteStyler.style(storage, paragraphsAround: involved, revealing: selection, opening: open, throughLists: false, colors: colors)
            return true
        }

        /// Nothing is being edited any more: every marker the selection showed as written is rendered again.
        @MainActor func unreveal(_ storage: NSTextStorage) {
            held = false; unholding?.cancel(); unholding = nil
            let length = storage.length
            let involved = (revealed + [opened].compactMap { $0 }).filter { NSMaxRange($0) <= length }
            revealed = []; opened = nil
            guard !involved.isEmpty else { return }
            NoteStyler.style(storage, paragraphsAround: involved, revealing: nil, opening: nil, throughLists: false, colors: colors)
        }

        /// The hidden ranges as the hooks give them for `text` now; true when they changed, so the layout must be redone.
        @MainActor @discardableResult func updateHidden(_ text: String) -> Bool {
            let next = (hooks?.hiddenRanges(in: text) ?? []).sorted { $0.location < $1.location }
            guard next != hidden else { return false }
            hidden = next; return true
        }
        /// Whether an edit of `range` reaches a hidden range: overlapping one, or inserting inside one.
        func reachesHidden(_ range: NSRange) -> Bool {
            hidden.contains { NSIntersectionRange($0, range).length > 0 || ($0.location <= range.location && range.location < NSMaxRange($0)) }
        }
        /// The caret never rests inside a hidden range: a selection starting in one starts after it instead. Nil when
        /// the selection may stay as it is.
        func outsideHidden(_ selected: NSRange) -> NSRange? {
            guard let range = hidden.first(where: { $0.location <= selected.location && selected.location < NSMaxRange($0) }) else { return nil }
            let end = NSMaxRange(range)
            return NSRange(location: end, length: max(0, NSMaxRange(selected) - end))
        }
        /// Where `location` lands outside the hidden ranges.
        func clamped(_ location: Int, length: Int) -> Int {
            min(outsideHidden(NSRange(location: location, length: 0))?.location ?? location, length)
        }
    }

    public func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    /// The hooks given now, attached to this view: the old ones let go, the new ones asked for what they hide.
    @MainActor func attach(_ coordinator: Coordinator, to textView: NoteEditorProxy.TextView) {
        guard coordinator.hooks !== hooks else { return }
        if let proxy = coordinator.proxy { coordinator.hooks?.detach(proxy) }
        let proxy = coordinator.proxy ?? NoteEditorProxy(textView: textView, coordinator: coordinator)
        coordinator.proxy = proxy
        coordinator.hooks = hooks
        hooks?.attach(proxy)
        if coordinator.revision >= 0 { proxy.invalidateLayout() }
    }
}

#if os(macOS)
extension NoteTextView: NSViewRepresentable {
    public func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        coordinator.colors = context.environment.noteColors
        let textView = ReadableTextView(usingTextLayoutManager: true)
        textView.layout = layout
        textView.delegate = coordinator
        textView.textLayoutManager?.delegate = coordinator
        textView.isRichText = false
        textView.isEditable = editable
        textView.allowsUndo = editable
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.insertionPointColor = coordinator.colors.accent
        textView.selectedTextAttributes = [.backgroundColor: coordinator.colors.highlight]
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        attach(coordinator, to: textView)
        load(textView, context: context)
        return scroll
    }

    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? ReadableTextView else { return }
        let coordinator = context.coordinator
        textView.layout = layout
        attach(coordinator, to: textView)
        let colors = context.environment.noteColors
        if colors != coordinator.colors {
            coordinator.colors = colors
            Self.retheme(textView, coordinator)
        }
        load(textView, context: context)
    }

    public static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        MainActor.assumeIsolated {
            if let proxy = coordinator.proxy { coordinator.hooks?.detach(proxy) }
        }
    }

    private func load(_ textView: NSTextView, context: Context) {
        let coordinator = context.coordinator
        guard coordinator.revision != session.revision, let storage = textView.textStorage else { return }
        let first = coordinator.revision < 0
        coordinator.revision = session.revision
        // The first load starts at the session's caret (where another view of this note left it); a reload keeps the
        // view's own. Read before the text is replaced: replacing it moves the selection, which reports a caret.
        let selection = first ? [NSValue(range: NSRange(location: session.caret, length: 0))] : textView.selectedRanges
        storage.setAttributedString(NSAttributedString(string: session.text, attributes: NoteStyler.base(coordinator.colors)))
        coordinator.updateHidden(session.text)
        coordinator.reveals = editable
        let length = storage.length
        let caret = NSRange(location: coordinator.clamped(selection.first?.rangeValue.location ?? 0, length: length), length: 0)
        coordinator.needsFullStyle = true
        // Markers show as written at the caret only while the note is being edited, as on the phone.
        coordinator.restyle(storage, selection: textView.isFocused ? caret : NSRange(location: NSNotFound, length: 0))
        textView.typingAttributes = NoteStyler.typing(at: 0, in: storage, colors: coordinator.colors)
        textView.selectedRanges = selection.map { NSValue(range: NSRange(location: coordinator.clamped($0.rangeValue.location, length: length), length: 0)) }
        textView.undoManager?.removeAllActions()
        if let proxy = coordinator.proxy { coordinator.hooks?.textDidLoad(proxy) }
    }

    /// The text and the caret in the colours just given. Text being composed (an input method's marked text) is left
    /// alone; the next edit restyles the whole note instead.
    @MainActor static func retheme(_ textView: NSTextView, _ coordinator: Coordinator) {
        textView.insertionPointColor = coordinator.colors.accent
        textView.selectedTextAttributes = [.backgroundColor: coordinator.colors.highlight]
        guard let storage = textView.textStorage else { return }
        if textView.hasMarkedText() { coordinator.needsFullStyle = true; return }
        let selection = textView.selectedRanges
        coordinator.needsFullStyle = true
        coordinator.restyle(storage, selection: textView.isFocused ? textView.selectedRange() : NSRange(location: NSNotFound, length: 0))
        textView.typingAttributes = NoteStyler.typing(at: selection.first?.rangeValue.location ?? 0, in: storage, colors: coordinator.colors)
        textView.selectedRanges = selection
        textView.needsDisplay = true
    }

    /// Lays the whole note out again (what's hidden, or the room after a paragraph, changed): the caret leaves any
    /// hidden range, and the hooks hear of it.
    @MainActor static func relayout(_ textView: NSTextView, _ coordinator: Coordinator) {
        guard let manager = textView.textLayoutManager else { return }
        manager.invalidateLayout(for: manager.documentRange)
        manager.textViewportLayoutController.layoutViewport()
        textView.needsLayout = true; textView.needsDisplay = true
        coordinator.keepOutsideHidden(textView)
        refreshAfterRelayout(textView)
        if let proxy = coordinator.proxy { coordinator.hooks?.layoutDidChange(proxy) }
    }

    /// After a relayout, TextKit can leave the top of the page undrawn when SwiftUI resizes the view a moment later
    /// (for something the host shows or hides above it): the viewport is laid out again on that resize.
    @MainActor static func refreshAfterRelayout(_ textView: NSTextView) {
        let refresh: @MainActor @Sendable () -> Void = { [weak textView] in
            guard let textView, let manager = textView.textLayoutManager else { return }
            manager.textViewportLayoutController.layoutViewport(); textView.needsDisplay = true
        }
        DispatchQueue.main.async(execute: refresh)
        if let scrollView = textView.enclosingScrollView {
            let once = Once()
            once.token = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView, queue: .main) { _ in
                MainActor.assumeIsolated { once.end(); refresh() }
            }
        }
    }
}
#endif

extension NoteTextView.Coordinator: NSTextLayoutManagerDelegate {
    /// Every paragraph's fragment asks, each time it is laid out, whether it is hidden; the layout manager keeps
    /// fragments across a relayout, so the answer can't be baked in when one is made.
    public func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: NSTextLocation, in textElement: NSTextElement) -> NSTextLayoutFragment {
        NoteFragment(textElement: textElement, range: textElement.elementRange, owner: self)
    }
    /// Whether the paragraph starting at `location` is inside a hidden range now.
    func hides(_ location: NSTextLocation, in content: NSTextContentManager) -> Bool {
        guard !hidden.isEmpty else { return false }
        let offset = content.offset(from: content.documentRange.location, to: location)
        return hidden.contains { $0.location <= offset && offset < NSMaxRange($0) }
    }
    /// The room the hooks add below a paragraph that lays out `height` tall. Asked on the main thread only, where the
    /// text views lay out.
    func spaceAfter(_ fragment: NSTextLayoutFragment, height: CGFloat) -> CGFloat {
        guard Thread.isMainThread else { return 0 }
        return MainActor.assumeIsolated {
            guard let hooks, let proxy else { return 0 }
            return hooks.spaceAfter(fragment, height: height, in: proxy)
        }
    }
    #if os(macOS)
    @MainActor func keepOutsideHidden(_ textView: NSTextView) {
        if let range = outsideHidden(textView.selectedRange()) { textView.setSelectedRange(range) }
    }
    #else
    @MainActor func keepOutsideHidden(_ textView: UITextView) {
        if let range = outsideHidden(textView.selectedRange) { textView.selectedRange = range }
    }
    #endif
}

/// A paragraph that, while it is inside a hidden range, is present in the text and absent from the page: no height,
/// nothing drawn. Otherwise an ordinary paragraph with its painted structure (bullets, task boxes, rules, quote bars)
/// drawn over its clear markers, and whatever room the hooks add below it.
final class NoteFragment: NSTextLayoutFragment {
    /// Held, not weakly: the coordinator owns no fragment, so no cycle, and a fragment outliving its view (in a test,
    /// in a window being torn down) still answers.
    private let owner: NoteTextView.Coordinator
    init(textElement: NSTextElement, range: NSTextRange?, owner: NoteTextView.Coordinator) {
        self.owner = owner
        super.init(textElement: textElement, range: range)
    }
    required init?(coder: NSCoder) { fatalError() }
    private var hidden: Bool {
        guard let content = textLayoutManager?.textContentManager else { return false }
        return owner.hides(rangeInElement.location, in: content)
    }
    override var layoutFragmentFrame: CGRect {
        var frame = super.layoutFragmentFrame
        if hidden { frame.size.height = 0; return frame }
        frame.size.height += owner.spaceAfter(self, height: frame.height)
        return frame
    }
    /// What the paragraph paints, read from its attributes the first time it's asked for.
    lazy var paints = ParagraphPaints((textElement as? NSTextParagraph)?.attributedString)
    override var renderingSurfaceBounds: CGRect {
        if hidden { return .zero }
        // The text views lay out and draw on the main thread. Anywhere else the paints are skipped, and their markers,
        // drawn clear, leave a gap where a bullet or box would be.
        guard !paints.paints.isEmpty, Thread.isMainThread else { return super.renderingSurfaceBounds }
        return MainActor.assumeIsolated { paintRects(paints) }.reduce(super.renderingSurfaceBounds) { $0.union($1.1) }
    }
    override func draw(at point: CGPoint, in context: CGContext) {
        guard !hidden else { return }
        super.draw(at: point, in: context)
        if !paints.paints.isEmpty, Thread.isMainThread { MainActor.assumeIsolated { drawPaints(paints, at: point, in: context, colors: owner.colors) } }
    }
}

#if os(macOS)
extension NSTextView {
    /// Whether this is the view being typed into.
    var isFocused: Bool { window?.firstResponder === self }
}

extension NoteTextView.Coordinator {
    /// A click sequence starts: the opened paragraph stays as it is until it's over.
    @MainActor func hold() {
        guard reveals else { return }
        held = true; unholding?.cancel(); unholding = nil
    }
    /// The click sequence is over (or will be, `after` the double-click interval): the selection's paragraph opens.
    @MainActor func unhold(_ textView: NSTextView, after delay: TimeInterval = 0) {
        guard held else { return }
        unholding?.cancel()
        let work = DispatchWorkItem { [weak self, weak textView] in
            MainActor.assumeIsolated {
                guard let self, let textView, let storage = textView.textStorage else { return }
                self.held = false; self.unholding = nil
                if self.reveal(storage, selection: textView.selectedRange()) {
                    textView.typingAttributes = NoteStyler.typing(at: textView.selectedRange().location, in: storage, colors: self.colors)
                }
            }
        }
        if delay > 0 { unholding = work; DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }
        else { unholding = nil; work.perform() }
    }
}

extension NoteTextView.Coordinator: NSTextViewDelegate {
    /// Every edit asks here, one range or several (ticking a few tasks at once).
    public func textView(_ textView: NSTextView, shouldChangeTextInRanges ranges: [NSValue], replacementStrings: [String]?) -> Bool {
        // Nothing typed, pasted or deleted reaches a hidden range.
        if ranges.contains(where: { reachesHidden($0.rangeValue) }) { return false }
        MainActor.assumeIsolated {
            // An edit mid click sequence (a paste from the menu) opens the selection's paragraph first.
            unhold(textView)
            for (index, range) in ranges.enumerated() {
                willChange(textView.string as NSString, range: range.rangeValue, replacement: replacementStrings?[index] ?? "")
            }
        }
        return true
    }

    /// A key binding's command goes to the hooks first.
    public func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        MainActor.assumeIsolated {
            guard let hooks, let proxy else { return false }
            return hooks.perform(commandSelector, proxy)
        }
    }

    /// Spelling marks stay on prose: `tp.date.now` in a Templater tag or a wikilink's target isn't a misspelling.
    public func textView(_ textView: NSTextView, didCheckTextIn range: NSRange, types checkingTypes: NSTextCheckingTypes, options: [NSSpellChecker.OptionKey: Any], results: [NSTextCheckingResult], orthography: NSOrthography, wordCount: Int) -> [NSTextCheckingResult] {
        guard let storage = textView.textStorage else { return results }
        return results.filter { result in
            var verbatim = false
            storage.enumerateAttribute(.noteVerbatim, in: result.range) { value, _, stop in
                if value as? Bool == true { verbatim = true; stop.pointee = true }
            }
            return !verbatim
        }
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        MainActor.assumeIsolated {
            keepOutsideHidden(textView)
            session.caret = textView.selectedRange().location
            if textView.isFocused, !textView.hasMarkedText(), let storage = textView.textStorage, reveal(storage, selection: textView.selectedRange()) {
                textView.typingAttributes = NoteStyler.typing(at: textView.selectedRange().location, in: storage, colors: colors)
            }
        }
    }

    public func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView, let storage = textView.textStorage else { return }
        MainActor.assumeIsolated {
            // Mid-composition (an accent, an input method) the marked text belongs to the system; style it once it lands.
            if !textView.hasMarkedText() {
                restyle(storage, selection: textView.isFocused ? textView.selectedRange() : NSRange(location: NSNotFound, length: 0))
                textView.typingAttributes = NoteStyler.typing(at: textView.selectedRange().location, in: storage, colors: colors)
                if updateHidden(textView.string) { NoteTextView.relayout(textView, self) }
            }
            if let proxy { hooks?.textDidChange(proxy) }
            session.edited(textView.string)
        }
    }
}

/// Keeps the text in a readable column, centred, however wide the window gets, and follows the caret a line at a
/// time: the system's own caret scrolling under TextKit 2 jumps the view by a dozen lines whenever the caret
/// reaches an edge, so the place being read leaps about; here the view moves only as far as the caret needs,
/// keeping a line and a half of what comes next in view, and a far jump (⌘↓, a click, a find) lands the caret a
/// third of the way down so there is room to read on.
final class ReadableTextView: NSTextView {
    /// Kept in view beyond the caret's line, so the next line is already there when the caret reaches it.
    static let margin: CGFloat = 1.5
    /// A move that scrolls more than this many viewports lands the caret a third down instead of at the edge.
    static let farMove: CGFloat = 1

    /// Where the text sits; the insets follow it.
    var layout = NoteLayout.standard { didSet { if layout != oldValue { placeText() } } }
    /// The host's room above the first line, in place of the layout's while set.
    var topInset: CGFloat? { didSet { if topInset != oldValue { placeText() } } }

    private var coordinator: NoteTextView.Coordinator? { delegate as? NoteTextView.Coordinator }
    private var hooks: (NoteTextHooks, NoteEditorProxy)? {
        guard let coordinator, let hooks = coordinator.hooks, let proxy = coordinator.proxy else { return nil }
        return (hooks, proxy)
    }

    /// The inset as given, to the device pixel; the system's own floors it to whole points, which would move whatever
    /// a host lines up with the text off it by the fraction.
    override var textContainerOrigin: NSPoint { NSPoint(x: textContainerInset.width, y: textContainerInset.height) }

    /// The page is as wide as the clip that shows it and starts at its top-left, to the pixel: wider by a fraction
    /// (as SwiftUI's sizing can make it), it scrolls sideways a fraction, and everything drawn on it lands off by that
    /// much.
    override func setFrameOrigin(_ newOrigin: NSPoint) { super.setFrameOrigin(.zero) }
    override func setFrameSize(_ newSize: NSSize) {
        var newSize = newSize
        if let clip = enclosingScrollView?.contentView { newSize.width = clip.bounds.width }
        super.setFrameSize(newSize)
        placeText()
        if let coordinator, coordinator.revision >= 0, let (hooks, proxy) = hooks { hooks.layoutDidChange(proxy) }
    }

    /// The insets: the column centred, at least the layout's margin from either side, and the top's room.
    private func placeText() {
        let side = max(layout.margin, (frame.width - layout.column) / 2)
        let inset = NSSize(width: side, height: topInset ?? layout.top)
        if textContainerInset != inset { textContainerInset = inset }
    }

    override func draw(_ dirtyRect: NSRect) {
        if let (hooks, proxy) = hooks { hooks.drawBehindText(in: dirtyRect, proxy) }
        super.draw(dirtyRect)
    }

    // The pointer over a task's box, or wherever the hooks want a cursor of their own.
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        // The text view sets its I-beam on every move; over a task's box, which is a control, the hand wins.
        if let cursor = hooks.flatMap({ $0.0.cursor(at: point, $0.1) }) { cursor.set() }
        else if isEditable && task(at: point) != nil { NSCursor.pointingHand.set() }
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        if let (hooks, proxy) = hooks { for (rect, cursor) in hooks.cursorRects(proxy) { addCursorRect(rect, cursor: cursor) } }
    }
    override func cursorUpdate(with event: NSEvent) {
        if let cursor = hooks.flatMap({ $0.0.cursor(at: convert(event.locationInWindow, from: nil), $0.1) }) { cursor.set() }
        else { super.cursorUpdate(with: event) }
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if let (hooks, proxy) = hooks { _ = hooks.cursor(at: nil, proxy) }
    }

    // MARK: Tasks

    /// The paragraph whose task box is under `point` (this view's coordinates), as its first character's offset.
    func task(at point: NSPoint) -> Int? {
        let origin = textContainerOrigin
        guard let (fragment, inFragment) = textLayoutManager?.fragment(at: CGPoint(x: point.x - origin.x, y: point.y - origin.y)),
              let paints = (fragment as? NoteFragment)?.paints, fragment.hitsTask(paints, at: inFragment) else { return nil }
        return fragment.paragraphStart
    }

    /// A click on a task's box ticks it, or unticks it, when the button comes up still on the box; the caret stays
    /// where it was. Each click toggles, a quick second one too.
    ///
    /// Any other click is held: the paragraph it lands in opens its hidden markers once the click sequence is over.
    override func mouseDown(with event: NSEvent) {
        guard isEditable, event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty,
              let paragraph = task(at: convert(event.locationInWindow, from: nil)) else {
            let coordinator = isEditable ? coordinator : nil
            coordinator?.hold()
            super.mouseDown(with: event)
            coordinator?.unhold(self, after: NSEvent.doubleClickInterval)
            return
        }
        var up = event
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            up = next
            if next.type == .leftMouseUp { break }
        }
        defer { coordinator?.unhold(self) }
        guard task(at: convert(up.locationInWindow, from: nil)) == paragraph else { return }
        toggleTasks(NoteTask.boxes(inParagraphsOf: NSRange(location: paragraph, length: 0), in: string).map(\.box))
    }

    /// Focus comes: the markers at the caret show as written. A click that brings it is held instead, and opens its
    /// line when it's over: opening the old caret's line now would move the layout under the click.
    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        if let coordinator, let storage = textStorage {
            // Released here too, in case something else takes the click and this view's mouseDown never runs.
            if NSApp.currentEvent?.type == .leftMouseDown { coordinator.hold(); coordinator.unhold(self, after: NSEvent.doubleClickInterval) }
            else if coordinator.reveal(storage, selection: selectedRange()) { typingAttributes = NoteStyler.typing(at: selectedRange().location, in: storage, colors: coordinator.colors) }
        }
        return true
    }
    /// Focus goes: the note reads rendered again, as it does on the phone when editing ends.
    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        if let coordinator, let storage = textStorage { coordinator.unreveal(storage) }
        return true
    }

    /// A key ends a held click sequence first, so the caret is never typed or moved into a closed paragraph.
    override func keyDown(with event: NSEvent) {
        coordinator?.unhold(self)
        super.keyDown(with: event)
    }

    /// ⌘⏎ ticks the open tasks on the lines the selection touches, or unticks them all when none is open; on a line
    /// with no task the key is left to the host.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isEditable, window?.firstResponder === self, event.type == .keyDown, [36, 76].contains(event.keyCode),
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.numericPad) == .command {
            let tasks = NoteTask.boxes(inParagraphsOf: selectedRange(), in: string)
            if !tasks.isEmpty {
                let open = tasks.filter { !$0.done }
                toggleTasks((open.isEmpty ? tasks : open).map(\.box))
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Ticks or unticks the tasks whose box characters are at `boxes`, through the text view's own edit path: one
    /// change, one undo step, restyled once and saved like any edit.
    func toggleTasks(_ boxes: [Int]) {
        guard let storage = textStorage, !boxes.isEmpty else { return }
        let text = string as NSString
        let ranges = boxes.map { NSRange(location: $0, length: 1) }
        let replacements = ranges.map { NoteTask.toggled(text.substring(with: $0)) }
        let selection = selectedRanges
        breakUndoCoalescing()
        undoManager?.beginUndoGrouping()
        guard shouldChangeText(inRanges: ranges.map { NSValue(range: $0) }, replacementStrings: replacements) else {
            undoManager?.endUndoGrouping()
            return
        }
        defer { undoManager?.setActionName("Toggle Task"); undoManager?.endUndoGrouping() }
        storage.beginEditing()
        for (range, replacement) in zip(ranges, replacements) { storage.replaceCharacters(in: range, with: replacement) }
        storage.endEditing()
        didChangeText()
        selectedRanges = selection
    }

    override func scrollRangeToVisible(_ range: NSRange) {
        guard let target = CaretFollow.target(for: range, in: self) else { super.scrollRangeToVisible(range); return }
        follow(to: target)
    }

    /// The line (in this view's coordinates) the caret is on, for `range`: its start, or its end when the start is
    /// already in view and the end isn't (a selection growing downward).
    private func lineRect(at location: Int) -> NSRect? {
        guard let window else { return nil }
        let onScreen = firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: nil)
        guard onScreen.height > 0 else { return nil }
        return convert(window.convertFromScreen(onScreen), from: nil)
    }

    private func follow(to y: CGFloat) {
        guard let clip = enclosingScrollView?.contentView else { return }
        guard abs(clip.bounds.origin.y - y) >= 0.5 else { return }
        clip.scroll(to: NSPoint(x: 0, y: y))
        enclosingScrollView?.reflectScrolledClipView(clip)
    }

    /// Where the view should scroll so `range`'s caret line is in view, by the rule above; nil when the text's
    /// geometry isn't known yet (no window).
    enum CaretFollow {
        static func target(for range: NSRange, in view: ReadableTextView) -> CGFloat? {
            guard let clip = view.enclosingScrollView?.contentView, var line = view.lineRect(at: range.location) else { return nil }
            let visible = view.visibleRect
            if range.length > 0, visible.contains(line), let end = view.lineRect(at: NSMaxRange(range)), !visible.contains(end) { line = end }
            return origin(forLine: line, visible: visible, documentHeight: view.frame.height, current: clip.bounds.origin.y)
        }
        /// Pure: the scroll origin that shows `line` with the margin, or the line a third down after a far move.
        static func origin(forLine line: NSRect, visible: NSRect, documentHeight: CGFloat, current: CGFloat) -> CGFloat {
            let margin = line.height * ReadableTextView.margin
            var y = current
            if line.minY < visible.minY + margin { y = line.minY - margin }
            else if line.maxY > visible.maxY - margin { y = line.maxY + margin - visible.height }
            if abs(y - current) > visible.height * ReadableTextView.farMove { y = line.minY - visible.height / 3 }
            // The top is the top and the end is the end: within a line of either, go all the way, so the first and
            // last lines never sit a few points short of the edge.
            let end = max(0, documentHeight - visible.height)
            if y < line.height { y = 0 } else if y > end - line.height { y = end }
            // Whole points: the line's rect comes back through screen coordinates, which can carry a fraction.
            return min(end, max(0, y)).rounded()
        }
    }
}

/// An observer that removes itself the first time it hears.
@MainActor private final class Once {
    var token: NSObjectProtocol?
    func end() { if let token { NotificationCenter.default.removeObserver(token) }; token = nil }
}
#else
extension NoteTextView: UIViewRepresentable {
    public func makeUIView(context: Context) -> UITextView {
        let coordinator = context.coordinator
        coordinator.colors = context.environment.noteColors
        let textView = UITextView(usingTextLayoutManager: true)
        textView.delegate = coordinator
        textView.textLayoutManager?.delegate = coordinator
        textView.isEditable = editable
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.backgroundColor = .clear
        textView.keyboardDismissMode = .interactive
        if fitsHeight {
            // Its height is the note's; the scroll view it sits in does the scrolling, and the page around it the
            // margins: the text starts at the view's edge, in line with whatever stands above it.
            textView.isScrollEnabled = false
            textView.textContainerInset = .zero
            textView.textContainer.lineFragmentPadding = 0
        } else {
            textView.alwaysBounceVertical = true
            textView.textContainerInset = insets
        }
        textView.tintColor = coordinator.colors.accent
        // A tap on a task's box ticks it, ahead of the text view's own taps (which would move the caret there).
        let tick = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tickTask(_:)))
        tick.delegate = coordinator
        textView.addGestureRecognizer(tick)
        attach(coordinator, to: textView)
        load(textView, context: context)
        return textView
    }

    private var insets: UIEdgeInsets { UIEdgeInsets(top: layout.top, left: layout.margin, bottom: layout.bottom, right: layout.margin) }

    /// Grown to the note: as tall as the text laid out at the width offered.
    public func sizeThatFits(_ proposal: ProposedViewSize, uiView textView: UITextView, context: Context) -> CGSize? {
        guard fitsHeight, let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return CGSize(width: width, height: textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    }

    public func updateUIView(_ textView: UITextView, context: Context) {
        let coordinator = context.coordinator
        if !fitsHeight, textView.textContainerInset != insets { textView.textContainerInset = insets }
        attach(coordinator, to: textView)
        let colors = context.environment.noteColors
        if colors != coordinator.colors {
            coordinator.colors = colors
            Self.retheme(textView, coordinator)
        }
        load(textView, context: context)
    }

    public static func dismantleUIView(_ textView: UITextView, coordinator: Coordinator) {
        MainActor.assumeIsolated {
            if let proxy = coordinator.proxy { coordinator.hooks?.detach(proxy) }
        }
    }

    private func load(_ textView: UITextView, context: Context) {
        let coordinator = context.coordinator
        guard coordinator.revision != session.revision else { return }
        let first = coordinator.revision < 0
        coordinator.revision = session.revision
        // As on the Mac: the first load starts at the session's caret, read before replacing the text moves the selection.
        let location = first ? session.caret : textView.selectedRange.location
        let storage = textView.textStorage
        storage.setAttributedString(NSAttributedString(string: session.text, attributes: NoteStyler.base(coordinator.colors)))
        coordinator.updateHidden(session.text)
        coordinator.reveals = editable
        coordinator.ticks = ticks
        let caret = NSRange(location: coordinator.clamped(location, length: storage.length), length: 0)
        // A note being read on the phone shows painted; markers show as written only once it's being edited.
        coordinator.needsFullStyle = true
        coordinator.restyle(storage, selection: textView.isFirstResponder ? caret : NSRange(location: NSNotFound, length: 0))
        textView.typingAttributes = NoteStyler.typing(at: 0, in: storage, colors: coordinator.colors)
        textView.selectedRange = caret
        if let proxy = coordinator.proxy { coordinator.hooks?.textDidLoad(proxy) }
    }

    /// As on the Mac: the text and the caret in the colours just given, marked text left for the next edit.
    @MainActor static func retheme(_ textView: UITextView, _ coordinator: Coordinator) {
        textView.tintColor = coordinator.colors.accent
        if textView.markedTextRange != nil { coordinator.needsFullStyle = true; return }
        let selection = textView.selectedRange
        coordinator.needsFullStyle = true
        coordinator.restyle(textView.textStorage, selection: textView.isFirstResponder ? selection : NSRange(location: NSNotFound, length: 0))
        textView.typingAttributes = NoteStyler.typing(at: selection.location, in: textView.textStorage, colors: coordinator.colors)
        textView.selectedRange = selection
    }

    /// Lays the note out again (what's hidden, or the room after a paragraph, changed): the caret leaves any hidden
    /// range, and the hooks hear of it. A host wanting it animated wraps the call in a transition of its own.
    @MainActor static func relayout(_ textView: UITextView, _ coordinator: Coordinator) {
        guard let manager = textView.textLayoutManager else { return }
        manager.invalidateLayout(for: manager.documentRange)
        manager.textViewportLayoutController.layoutViewport()
        textView.setNeedsLayout(); textView.setNeedsDisplay()
        // A change from typing comes with no update from SwiftUI: a view that fits its height asks to be measured.
        textView.invalidateIntrinsicContentSize()
        coordinator.keepOutsideHidden(textView)
        if let proxy = coordinator.proxy { coordinator.hooks?.layoutDidChange(proxy) }
    }
}

extension NoteTextView.Coordinator: UIGestureRecognizerDelegate {
    /// The paragraph whose task box is under `point` in a view that ticks, within a finger's reach of it.
    @MainActor func task(at point: CGPoint, in textView: UITextView) -> Int? {
        guard ticks else { return nil }
        let inset = textView.textContainerInset
        guard let (fragment, inFragment) = textView.textLayoutManager?.fragment(at: CGPoint(x: point.x - inset.left, y: point.y - inset.top)),
              let paints = (fragment as? NoteFragment)?.paints, fragment.hitsTask(paints, at: inFragment, reach: 44) else { return nil }
        return fragment.paragraphStart
    }
    /// The box tap sees only touches that land on a box: anywhere else it never takes part, so nothing waits on it.
    public func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        MainActor.assumeIsolated {
            guard let textView = recognizer.view as? UITextView else { return false }
            // A touch that stops a scroll (the page's, around a view that fits its height) only stops it.
            var view: UIView? = textView
            while let current = view {
                if let scroll = current as? UIScrollView, scroll.isDragging || scroll.isDecelerating { return false }
                view = current.superview
            }
            return task(at: touch.location(in: textView), in: textView) != nil
        }
    }
    /// On a box, the text view's own taps wait for this one, so the tap ticks the box rather than placing the caret.
    public func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        other.view === recognizer.view && other is UITapGestureRecognizer
    }
    @objc func tickTask(_ recognizer: UITapGestureRecognizer) {
        MainActor.assumeIsolated {
            guard let textView = recognizer.view as? UITextView, let paragraph = task(at: recognizer.location(in: textView), in: textView) else { return }
            tick(paragraph: paragraph, in: textView)
        }
    }
    /// Ticks or unticks the task on the paragraph starting at `paragraph`; the caret, and whether the keyboard is up,
    /// stay as they were. Editing, through the text view's own edit path (an undo step); only showing the note, which
    /// the text view won't change, straight in the text, then saved as an edit is.
    @MainActor func tick(paragraph: Int, in textView: UITextView) {
        let selection = textView.selectedRange
        for task in NoteTask.boxes(inParagraphsOf: NSRange(location: paragraph, length: 0), in: textView.text) {
            let box = NSRange(location: task.box, length: 1)
            let replacement = NoteTask.toggled((textView.text as NSString).substring(with: box))
            if textView.isEditable {
                guard let start = textView.position(from: textView.beginningOfDocument, offset: box.location),
                      let end = textView.position(from: start, offset: 1), let range = textView.textRange(from: start, to: end) else { continue }
                textView.replace(range, withText: replacement)
            } else {
                willChange(textView.text as NSString, range: box, replacement: replacement)
                textView.textStorage.replaceCharacters(in: box, with: replacement)
                textViewDidChange(textView)
            }
        }
        textView.selectedRange = selection
        guard !textView.isEditable else { return }
        // Nothing here shows a save waiting or refused, so the tick goes out now; if another app changed the note
        // first, the page takes their version rather than show a tick the file doesn't have.
        Task { [session] in
            await session.save()
            if session.status == .changedElsewhere { await session.resolve(keepMine: false) }
        }
    }
}

extension NoteTextView.Coordinator: UITextViewDelegate {
    public func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        // Nothing typed, pasted or deleted reaches a hidden range.
        if reachesHidden(range) { return false }
        MainActor.assumeIsolated { willChange(textView.text as NSString, range: range, replacement: text) }
        return true
    }

    /// Editing starts: the markers the caret touches show as written.
    public func textViewDidBeginEditing(_ textView: UITextView) {
        MainActor.assumeIsolated {
            if textView.markedTextRange == nil, reveal(textView.textStorage, selection: textView.selectedRange) {
                textView.typingAttributes = NoteStyler.typing(at: textView.selectedRange.location, in: textView.textStorage, colors: colors)
            }
        }
    }
    /// Editing ends with the keyboard: the note reads painted again, as it did before.
    public func textViewDidEndEditing(_ textView: UITextView) {
        MainActor.assumeIsolated { unreveal(textView.textStorage) }
    }

    public func textViewDidChangeSelection(_ textView: UITextView) {
        MainActor.assumeIsolated {
            keepOutsideHidden(textView)
            session.caret = textView.selectedRange.location
            if textView.isFirstResponder, textView.markedTextRange == nil, reveal(textView.textStorage, selection: textView.selectedRange) {
                textView.typingAttributes = NoteStyler.typing(at: textView.selectedRange.location, in: textView.textStorage, colors: colors)
            }
        }
    }

    public func textViewDidChange(_ textView: UITextView) {
        MainActor.assumeIsolated {
            if textView.markedTextRange == nil {
                // Restyling resets typing attributes and can nudge the selection; put both back.
                let selection = textView.selectedRange
                restyle(textView.textStorage, selection: textView.isFirstResponder ? selection : NSRange(location: NSNotFound, length: 0))
                textView.typingAttributes = NoteStyler.typing(at: selection.location, in: textView.textStorage, colors: colors)
                textView.selectedRange = selection
                if updateHidden(textView.text) { NoteTextView.relayout(textView, self) }
            }
            if let proxy { hooks?.textDidChange(proxy) }
            session.edited(textView.text)
        }
    }
}
#endif
