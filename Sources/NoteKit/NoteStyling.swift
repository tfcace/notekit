import Foundation
import CoreText
#if os(macOS)
import AppKit
typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
#else
import UIKit
typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
#endif

/// Styles a note's Markdown source in place: the characters stay exactly as the file has them, markers dimmed and
/// the text they mark set in its style. Attributes only; the text storage's string is never touched here.
@MainActor enum NoteStyler {
    #if os(macOS)
    static let bodySize: CGFloat = 15
    #else
    static let bodySize: CGFloat = 17
    #endif

    /// Restyles the paragraphs `range` touches, or the whole note. Spans come from the whole text, so a fence or
    /// frontmatter above the range still decides what's inside it. `revealing` is the selection: the markers it
    /// shows as written instead of rendered are the painted ones it touches and the hidden ones in its paragraph.
    /// nil renders every marker, as a view with no caret does.
    static func style(_ storage: NSTextStorage, paragraphsAround range: NSRange? = nil, revealing: NSRange? = nil, colors: NoteColors = .system) {
        style(storage, paragraphsAround: range.map { [$0] }, revealing: revealing, opening: revealing, colors: colors)
    }

    /// Restyles the paragraphs each range touches (the whole note for nil), from one scan of the note and in one pass
    /// over it. Painted markers that `revealing` touches show as written, and hidden markers in `opening`'s paragraph
    /// (the selection's, or through a click the one it started from); either only for a range within one paragraph.
    /// A list's nesting is read from the lines above, so a change to one item can move the items below it: an edit's
    /// restyle also takes every item whose level isn't the one it was last styled at. A reveal changes no nesting and
    /// doesn't need to look.
    static func style(_ storage: NSTextStorage, paragraphsAround ranges: [NSRange]?, revealing: NSRange?, opening: NSRange?, throughLists: Bool = true, colors: NoteColors = .system) {
        let string = storage.string as NSString
        let full = NSRange(location: 0, length: string.length)
        let spans = MarkdownStyleScanner.spans(in: storage.string)
        let leads = Lead.all(in: spans, of: string)
        let revealing = revealing.flatMap { reveals($0, in: string) ? $0 : nil }
        let open = opening.flatMap { reveals($0, in: string) ? string.paragraphRange(for: NSRange(location: $0.location, length: 0)) : nil }
        let targets = Targets(ranges.map { ranges in
            var targets = ranges.map { string.paragraphRange(for: clamp($0, to: full.length)) }
            if throughLists {
                for (start, lead) in leads {
                    guard let item = lead.item, storage.attribute(.noteListLevel, at: start, effectiveRange: nil) as? Int != item.level else { continue }
                    targets.append(string.paragraphRange(for: NSRange(location: start, length: 0)))
                }
            }
            return targets
        } ?? [full])
        guard let last = targets.ranges.last else { return }
        storage.beginEditing()
        defer { storage.endEditing() }
        for target in targets.ranges { storage.setAttributes(base(colors), range: target) }
        paragraphs(in: targets, through: NSMaxRange(last), of: string, storage: storage, spans: spans)
        var hidden: [NSRange] = [], embed: NSRange?
        for span in spans {
            if span.mark == .embed { embed = span.range }
            let hides = hides(span.mark) && !(embed.map { NSLocationInRange(span.range.location, $0) } ?? false)
            for target in targets.touching(span.range) {
                let range = NSIntersectionRange(span.range, target)
                guard range.length > 0 else { continue }
                if hides { hidden.append(range) }
                storage.addAttributes(attributes(for: span.mark, colors), range: range)
                if let face = face(for: span.mark) { merge(face, into: storage, range: range) }
                // The box's character in mono, so `[x]` is as wide as `[ ]` and ticking moves nothing.
                if case .marker(.task) = span.mark { merge(NoteFace(mono: true), into: storage, range: NSRange(location: range.location + 1, length: 1)) }
            }
        }
        // A line of nothing but hidden markers (`## ` before its title is typed) keeps them showing: hidden, it would
        // close up to nothing, hard to click back into and jumping open when the caret came.
        var covered: [Int: Int] = [:]
        for range in hidden { covered[string.paragraphRange(for: range).location, default: 0] += range.length }
        let bare = Set(covered.compactMap { start, count -> Int? in
            var end = 0
            string.getParagraphStart(nil, end: nil, contentsEnd: &end, for: NSRange(location: start, length: 0))
            return count >= end - start ? start : nil
        })
        // After every span's colour, so nothing drawn over a hidden marker brings its ink back.
        for range in hidden {
            storage.addAttribute(.noteHides, value: true, range: range)
            if let open, NSIntersectionRange(open, range).length > 0 { continue }
            if bare.contains(string.paragraphRange(for: range).location) { continue }
            merge(NoteFace(hidden: true), into: storage, range: range)
            storage.addAttribute(.foregroundColor, value: PlatformColor.clear, range: range)
        }
        for target in targets.ranges {
            storage.enumerateAttribute(.noteFace, in: target) { value, range, _ in
                storage.addAttribute(.font, value: (value as? NoteFace ?? NoteFace()).font, range: range)
            }
        }
        for (start, lead) in leads where !targets.touching(NSRange(location: start, length: 1)).isEmpty {
            lay(lead, at: start, in: storage, revealed: revealing.map { lead.touches($0) } ?? false)
        }
    }

    /// The ranges a restyle covers: in order, those that overlap or meet joined into one.
    private struct Targets {
        let ranges: [NSRange]
        init(_ ranges: [NSRange]) {
            self.ranges = ranges.sorted { $0.location < $1.location }.reduce(into: []) { merged, range in
                if let last = merged.last, range.location <= NSMaxRange(last) { merged[merged.count - 1] = NSUnionRange(last, range) }
                else { merged.append(range) }
            }
        }

        /// The targets `range` overlaps, or that start where it does (an empty paragraph at the note's end).
        func touching(_ range: NSRange) -> ArraySlice<NSRange> {
            // From the first target that doesn't end before the range starts, to the last that starts by its end.
            var low = 0, high = ranges.count
            while low < high {
                let middle = (low + high) / 2
                if NSMaxRange(ranges[middle]) < range.location { low = middle + 1 } else { high = middle }
            }
            var end = low
            while end < ranges.count, ranges[end].location <= NSMaxRange(range) { end += 1 }
            return ranges[low..<end].filter { NSIntersectionRange($0, range).length > 0 || $0.location == range.location }[...]
        }
    }

    /// How far each list level steps in, and the room a bullet takes before its text: the same for every bullet,
    /// however many spaces or tabs the file has, so nesting reads at a glance and a ticked box moves nothing.
    static var step: CGFloat { (bodySize * 1.5).rounded() }
    /// A task's box and its text: a little wider than a bullet's, as `- [ ] ` is.
    static var taskGutter: CGFloat { (bodySize * 2.1).rounded() }
    /// Where a bullet's dot or a task's box is centred, in from the gutter's leading edge.
    static var markerColumn: CGFloat { (bodySize * 0.6).rounded() }

    /// Paints a paragraph's leading markers (or, revealed, leaves them showing as written), and lays out its gutter:
    /// the indent and bullet run kerned to its level's width, wrapped lines hanging under the text. Kerning moves no
    /// character in the text and is the same revealed or not, so the caret coming to a line changes ink, not layout.
    private static func lay(_ lead: Lead, at start: Int, in storage: NSTextStorage, revealed: Bool) {
        let string = storage.string as NSString
        storage.addAttribute(.noteMarkerRun, value: true, range: lead.run)
        if !revealed {
            var painted: [(NotePaint.Kind, NSRange)] = lead.quotes.enumerated().map { (.quote(level: $0.offset + 1), NSRange(location: $0.element.location, length: 1)) }
            if let rule = lead.rule { painted.append((.rule, rule)) }
            if let item = lead.item {
                let bullet = NSRange(location: item.range.location + leadingSpace(item.range, in: string), length: 1)
                switch (item.bullet, lead.task) {
                case (true, let task?): painted += [(.task(done: task.done), bullet)]; clear(item.range, task.range, in: storage)
                case (true, nil): painted.append((.bullet(level: item.level), bullet)); clear(item.range, in: storage)
                case (false, let task?): painted.append((.box(done: task.done), task.range)); clear(task.range, in: storage)
                case (false, nil): break
                }
            }
            for quote in lead.quotes { clear(quote, in: storage) }
            if let rule = lead.rule { clear(rule, in: storage) }
            for (kind, range) in painted { storage.addAttribute(.notePaint, value: NotePaint(kind), range: range) }
        }
        guard let style = storage.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle,
              let hanging = style.mutableCopy() as? NSMutableParagraphStyle else { return }
        let paragraph = string.paragraphRange(for: NSRange(location: start, length: 0))
        // A tab steps one level (kerning can't change a tab's width), set before anything is measured.
        hanging.tabStops = []
        hanging.defaultTabInterval = step
        // Copies: the storage keeps the style it's given (and shares it by value), so the one stored isn't changed after.
        storage.addAttribute(.paragraphStyle, value: hanging.copy(), range: paragraph)
        let prefix = width(NSRange(location: start, length: (lead.item?.range.location ?? lead.body) - start), in: storage)
        if let item = lead.item {
            storage.addAttribute(.noteListLevel, value: item.level, range: paragraph)
            let bullet = item.range.location + leadingSpace(item.range, in: string)
            let leading = prefix + CGFloat(item.level - 1) * step
            // The indent takes up the difference between the spaces as typed and the level's step. The room goes
            // after its first character, not its last: a caret beside a kerned character stands in the middle of
            // the room, and the caret before the bullet should stand at the bullet.
            let indent = NSRange(location: item.range.location, length: bullet - item.range.location)
            if indent.length > 0 {
                let room = leading - width(NSRange(location: start, length: bullet - start), in: storage)
                storage.addAttribute(.kern, value: room, range: NSRange(location: indent.location, length: 1))
            }
            // Likewise the gutter's room goes between the markers and the space that ends them, so the caret at the
            // start of the text stands at the text. A kern's room follows its glyph on the page, which on a
            // right-to-left line is logically before it: there it goes on the space itself.
            let run = width(NSRange(location: bullet, length: lead.body - bullet), in: storage)
            let gutter = max(run, item.bullet ? (lead.task == nil ? step : taskGutter) : step)
            let last = lead.body - 1, rightToLeft = hanging.baseWritingDirection == .rightToLeft
            let room = string.character(at: last) == 0x20 && last > bullet && !rightToLeft ? last - 1 : last
            if gutter > run { storage.addAttribute(.kern, value: gutter - run, range: NSRange(location: room, length: 1)) }
            hanging.headIndent = leading + gutter
        } else {
            hanging.headIndent = prefix
        }
        storage.addAttribute(.paragraphStyle, value: hanging.copy(), range: paragraph)
    }

    private static func clear(_ ranges: NSRange..., in storage: NSTextStorage) {
        for range in ranges { storage.addAttribute(.foregroundColor, value: PlatformColor.clear, range: range) }
    }

    /// The width the characters take on a line of their own, a trailing space included (NSAttributedString.size
    /// leaves it out on a right-to-left line).
    private static func width(_ range: NSRange, in storage: NSTextStorage) -> CGFloat {
        guard range.length > 0 else { return 0 }
        return CTLineGetTypographicBounds(CTLineCreateWithAttributedString(storage.attributedSubstring(from: range)), nil, nil, nil)
    }

    private static func leadingSpace(_ range: NSRange, in string: NSString) -> Int {
        var count = 0
        while count < range.length, [0x20, 0x09].contains(string.character(at: range.location + count)) { count += 1 }
        return count
    }

    /// The painted markers a selection is touching, as its paragraph's marker run: when this changes as the caret
    /// moves, the paragraphs involved are restyled.
    static func markerRuns(touching selection: NSRange, in storage: NSTextStorage) -> [NSRange] {
        let string = storage.string as NSString
        guard reveals(selection, in: string) else { return [] }
        var runs: [NSRange] = []
        storage.enumerateAttribute(.noteMarkerRun, in: string.paragraphRange(for: NSRange(location: selection.location, length: 0))) { value, run, _ in
            if value != nil, Lead.touches(run, selection) { runs.append(run) }
        }
        return runs
    }

    /// The paragraph whose hidden markers a selection shows as written: its own, when the selection lies within it
    /// and it has any. When this changes as the caret moves, the paragraphs involved are restyled.
    static func openParagraph(for selection: NSRange, in storage: NSTextStorage) -> NSRange? {
        let string = storage.string as NSString
        guard reveals(selection, in: string) else { return nil }
        let paragraph = string.paragraphRange(for: NSRange(location: selection.location, length: 0))
        var any = false
        storage.enumerateAttribute(.noteHides, in: paragraph) { value, _, stop in
            if value != nil { any = true; stop.pointee = true }
        }
        return any ? paragraph : nil
    }

    /// Which markers take no room off the caret's paragraph: the inline ones, a heading's `#`s, a link's brackets and
    /// the address it doesn't show, a callout's `[!type]`. Painted structure (lists, quotes, rules) keeps its place,
    /// fences stay as code's frame, and tags and Templater commands are syntax of their own.
    private static func hides(_ mark: NoteMark) -> Bool {
        switch mark {
        case .marker(.strong), .marker(.emphasis), .marker(.strikethrough), .marker(.highlight), .marker(.code),
             .marker(.link), .marker(.heading), .marker(.callout), .linkDestination: true
        default: false
        }
    }

    /// Whether a selection shows the markers it touches as written: only within one paragraph. A selection across
    /// paragraphs is for copying or deleting, and ⌘A would otherwise restyle every list in the note.
    private static func reveals(_ selection: NSRange, in string: NSString) -> Bool {
        guard selection.location != NSNotFound, NSMaxRange(selection) <= string.length else { return false }
        return NSMaxRange(selection) <= NSMaxRange(string.paragraphRange(for: NSRange(location: selection.location, length: 0)))
    }

    static func base(_ colors: NoteColors) -> [NSAttributedString.Key: Any] {
        [.font: NoteFace().font, .foregroundColor: colors.text, .paragraphStyle: paragraph(.leftToRight)]
    }

    /// What newly typed text gets: plain body text in the direction of the line it's typed on. An empty line has
    /// no characters to carry a direction, so it takes the line above's, which restyling gave the newline before it.
    static func typing(at location: Int, in storage: NSTextStorage, colors: NoteColors) -> [NSAttributedString.Key: Any] {
        var typing = base(colors)
        if location > 0, location <= storage.length,
           let style = storage.attribute(.paragraphStyle, at: location - 1, effectiveRange: nil) as? NSParagraphStyle {
            typing[.paragraphStyle] = paragraph(style.baseWritingDirection == .rightToLeft ? .rightToLeft : .leftToRight)
        }
        return typing
    }

    private static func clamp(_ range: NSRange, to length: Int) -> NSRange {
        let location = min(max(0, range.location), length)
        return NSRange(location: location, length: min(range.length, length - location))
    }

    private static func paragraphs(in targets: Targets, through end: Int, of string: NSString, storage: NSTextStorage, spans: [NoteSpan]) {
        // Direction follows the nearest line above with words in it, so start from the note's beginning.
        var direction = ParagraphDirection.leftToRight
        var headings: [Int: Int] = [:]
        for span in spans { if case .heading(let level) = span.mark { headings[string.paragraphRange(for: span.range).location] = level } }
        string.enumerateSubstrings(in: NSRange(location: 0, length: end), options: [.byParagraphs]) { line, _, enclosing, _ in
            if let found = line.flatMap({ ParagraphDirection.of($0) }) { direction = found }
            guard !targets.touching(enclosing).isEmpty else { return }
            storage.addAttribute(.paragraphStyle, value: paragraph(direction, heading: headings[enclosing.location]), range: enclosing)
            if let level = headings[enclosing.location] { merge(NoteFace(scale: headingScale(level), bold: true), into: storage, range: enclosing) }
        }
    }

    static func paragraph(_ direction: ParagraphDirection, heading: Int? = nil) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.baseWritingDirection = direction == .rightToLeft ? .rightToLeft : .leftToRight
        style.alignment = .natural
        style.lineHeightMultiple = 1.18
        style.paragraphSpacing = 3
        if let heading { style.paragraphSpacingBefore = heading <= 2 ? 14 : 8 }
        return style
    }

    private static func headingScale(_ level: Int) -> CGFloat { [1.55, 1.3, 1.15, 1.05, 1, 1][min(max(level, 1), 6) - 1] }

    private static func face(for mark: NoteMark) -> NoteFace? {
        switch mark {
        case .strong: NoteFace(bold: true)
        case .emphasis: NoteFace(italic: true)
        case .calloutTitle: NoteFace(bold: true)
        case .code, .codeBlock, .template: NoteFace(mono: true)
        case .frontmatter: NoteFace(scale: 0.88, mono: true)
        default: nil
        }
    }

    private static func attributes(for mark: NoteMark, _ colors: NoteColors) -> [NSAttributedString.Key: Any] {
        switch mark {
        case .marker: [.foregroundColor: colors.secondary.fading(0.55)]
        case .heading: [:]
        case .strong, .emphasis: [:]
        case .strikethrough: [.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: colors.secondary]
        case .highlight: [.backgroundColor: colors.highlight]
        case .code, .template: [.backgroundColor: colors.codeBackground, .foregroundColor: colors.text, .noteVerbatim: true]
        case .codeBlock: [.backgroundColor: colors.codeBackground, .noteVerbatim: true]
        case .link, .tag: [.foregroundColor: colors.accent, .noteVerbatim: true]
        case .linkDestination: [.foregroundColor: colors.secondary.fading(0.75), .noteVerbatim: true]
        case .frontmatter: [.foregroundColor: colors.secondary, .noteVerbatim: true]
        case .quote: [.foregroundColor: colors.secondary]
        case .calloutTitle: [.foregroundColor: colors.accent]
        case .embed: [:]
        case .done: [.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: colors.secondary]
        }
    }

    /// Fonts combine: bold inside a heading stays heading-sized, a bold-italic run gets both.
    private static func merge(_ face: NoteFace, into storage: NSTextStorage, range: NSRange) {
        storage.enumerateAttribute(.noteFace, in: range) { value, part, _ in
            storage.addAttribute(.noteFace, value: (value as? NoteFace ?? NoteFace()).merged(face), range: part)
        }
    }
}

/// A list, quote or rule paragraph's leading markers, as the scanner found them.
private struct Lead {
    var quotes: [NSRange] = []
    var item: (range: NSRange, level: Int, bullet: Bool)?
    var task: (range: NSRange, done: Bool)?
    var rule: NSRange?
    /// Where the paragraph's text starts, after its markers (and the space after a task's box).
    var body = 0
    /// The markers, from the paragraph's start to its text: a selection touching this shows them as written.
    var run = NSRange(location: 0, length: 0)

    func touches(_ selection: NSRange) -> Bool { Self.touches(run, selection) }
    /// A selection touches a run when it overlaps it or meets either end: a caret at the start of the text counts,
    /// since ⌫ there would delete a marker.
    static func touches(_ run: NSRange, _ selection: NSRange) -> Bool {
        selection.location <= NSMaxRange(run) && NSMaxRange(selection) >= run.location
    }

    @MainActor static func all(in spans: [NoteSpan], of string: NSString) -> [Int: Lead] {
        var leads: [Int: Lead] = [:]
        for span in spans {
            guard case .marker(let marker) = span.mark else { continue }
            let start = string.paragraphRange(for: NSRange(location: span.range.location, length: 0)).location
            var lead = leads[start] ?? Lead()
            switch marker {
            case .quote: lead.quotes.append(span.range)
            case .bullet(let level): lead.item = (span.range, level, true)
            case .number(let level): lead.item = (span.range, level, false)
            case .task(let done): lead.task = (span.range, done)
            case .rule: lead.rule = span.range
            default: continue
            }
            var body = NSMaxRange(span.range)
            if case .task = marker, body < string.length, string.character(at: body) == 0x20 { body += 1 }
            lead.body = max(lead.body, body)
            lead.run = NSRange(location: start, length: lead.body - start)
            leads[start] = lead
        }
        return leads
    }
}

extension NSAttributedString.Key {
    /// A list, quote or rule paragraph's markers, from its start to its text (the value is true; the run is the
    /// attribute's extent, which moves with the text as an edit above it does): where a selection reveals them.
    static let noteMarkerRun = NSAttributedString.Key("NoteKitMarkerRun")
    /// A marker hidden off the caret's paragraph, whether or not it's hidden now: where opening a paragraph matters.
    static let noteHides = NSAttributedString.Key("NoteKitHides")
    /// A list item's level as it was last styled: an edit restyles every item whose level it changed.
    static let noteListLevel = NSAttributedString.Key("NoteKitListLevel")
    /// The font a run should have, before it's resolved to a platform font. Only ever in the editor's storage.
    static let noteFace = NSAttributedString.Key("NoteKitFace")
    /// Code, commands, links, tags and frontmatter: not prose, so the spelling checker leaves them alone.
    static let noteVerbatim = NSAttributedString.Key("NoteKitVerbatim")
}

final class NoteFace: NSObject {
    let scale: CGFloat, bold: Bool, italic: Bool, mono: Bool
    /// A hidden marker's face: next to no width, so the line closes up around it, while the characters stay put.
    let hidden: Bool
    init(scale: CGFloat = 1, bold: Bool = false, italic: Bool = false, mono: Bool = false, hidden: Bool = false) {
        self.scale = scale; self.bold = bold; self.italic = italic; self.mono = mono; self.hidden = hidden
    }
    func merged(_ other: NoteFace) -> NoteFace {
        NoteFace(scale: max(scale, other.scale), bold: bold || other.bold, italic: italic || other.italic, mono: mono || other.mono, hidden: hidden || other.hidden)
    }
    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? NoteFace else { return false }
        return scale == other.scale && bold == other.bold && italic == other.italic && mono == other.mono && hidden == other.hidden
    }
    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(scale); hasher.combine(bold); hasher.combine(italic); hasher.combine(mono); hasher.combine(hidden)
        return hasher.finalize()
    }

    @MainActor private static var cache: [NoteFace: PlatformFont] = [:]
    @MainActor var font: PlatformFont {
        if let font = Self.cache[self] { return font }
        let size = hidden ? 0.01 : NoteStyler.bodySize * scale * (mono ? 0.9 : 1)
        let weight: PlatformFont.Weight = bold ? .semibold : .regular
        var font = mono ? PlatformFont.monospacedSystemFont(ofSize: size, weight: weight) : PlatformFont.systemFont(ofSize: size, weight: weight)
        if italic {
            #if os(macOS)
            font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.italic), size: size) ?? font
            #else
            font = font.fontDescriptor.withSymbolicTraits(.traitItalic).map { UIFont(descriptor: $0, size: size) } ?? font
            #endif
        }
        Self.cache[self] = font
        return font
    }
}
