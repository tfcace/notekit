import Foundation

/// What a stretch of a note's Markdown source is, for styling it in place. The source itself is never changed: the
/// editor shows the same characters the file holds, with markers dimmed and the text they mark styled.
public enum NoteMark: Hashable, Sendable {
    /// Syntax characters: `#`, `**`, `[[`, `]]`, `>`, list bullets, fences, each named for what it marks.
    case marker(NoteMarker)
    case heading(Int)
    case strong, emphasis, strikethrough, highlight
    case code, codeBlock
    /// A link's visible text: a wikilink's target or alias, a Markdown link's text, a bare address.
    case link
    /// Where a link goes when that isn't what it shows: a Markdown link's address, an aliased wikilink's target.
    case linkDestination
    case frontmatter
    case quote, calloutTitle
    /// An embed or an image, `![[…]]` or `![…](…)`, the whole of it: shown as written, markers and all, until embeds
    /// are rendered.
    case embed
    /// A finished task's text.
    case done
    /// A Templater command, `<% … %>`.
    case template
    case tag
}

/// What a run of syntax characters marks. The scanner is the one place that knows; everything that treats markers
/// differently by kind (paints them, hides them) asks the span, never the characters.
public enum NoteMarker: Hashable, Sendable {
    /// `#` to `######` and the space after.
    case heading
    /// One `>` and the space after it; a nested quote has one per level.
    case quote
    /// A thematic break: `---`, `***`, `___`, the whole line.
    case rule
    /// A fence's backticks or tildes and its info string.
    case fence
    /// `-`, `*` or `+` with the indent before it and the space after. Level 1 is the outermost list.
    case bullet(level: Int)
    /// `1.` or `1)` with its indent and the space after.
    case number(level: Int)
    /// A task's box, `[ ]`, `[x]` or `[X]`, after a bullet or number: always three characters, the middle one the
    /// box's state.
    case task(done: Bool)
    case strong, emphasis, strikethrough, highlight
    /// An inline code span's backticks.
    case code
    /// A link's brackets, parentheses and an alias's pipe.
    case link
    /// A callout's `[!type]`, its fold sign and the space after, when a title follows.
    case callout
}

public struct NoteSpan: Equatable, Sendable {
    /// UTF-16 range in the note, as NSString and the text views count.
    public let range: NSRange
    public let mark: NoteMark
    public init(_ range: NSRange, _ mark: NoteMark) { self.range = range; self.mark = mark }
}

/// Finds the Markdown and Obsidian syntax in a note, line by line. It recognises what the editor styles and nothing
/// more; anything it doesn't recognise is plain text, so an unfamiliar construct is shown as written, never altered.
public enum MarkdownStyleScanner {
    public static func spans(in text: String) -> [NoteSpan] {
        let string = text as NSString
        var lines: [NSRange] = []
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            lines.append(range)
        }
        var spans: [NoteSpan] = []
        var first = 0
        if let close = frontmatterEnd(lines, in: string) {
            spans.append(NoteSpan(NSRange(location: 0, length: NSMaxRange(lines[close])), .frontmatter))
            first = close + 1
        }
        var fence: (character: unichar, count: Int)?
        var lists = ListNesting()
        for line in lines.dropFirst(first) {
            if let open = fence {
                if let run = fenceRun(line, in: string), run.character == open.character, run.count >= open.count, run.info.length == 0 {
                    spans.append(NoteSpan(run.trimmed, .marker(.fence))); fence = nil
                } else if line.length > 0 {
                    spans.append(NoteSpan(line, .codeBlock))
                }
                continue
            }
            if let run = fenceRun(line, in: string) {
                spans.append(NoteSpan(run.trimmed, .marker(.fence))); fence = (run.character, run.count)
                continue
            }
            block(line, in: string, lists: &lists, into: &spans)
        }
        return spans.enumerated().sorted { ($0.element.range.location, $0.offset) < ($1.element.range.location, $1.offset) }.map(\.element)
    }

    // MARK: Blocks

    private static func frontmatterEnd(_ lines: [NSRange], in string: NSString) -> Int? {
        guard let opening = lines.first, trimmed(string.substring(with: opening)) == "---" else { return nil }
        return lines.indices.dropFirst().first { ["---", "..."].contains(trimmed(string.substring(with: lines[$0]))) }
    }

    private static func trimmed(_ line: String) -> String {
        String(line.reversed().drop { $0 == " " || $0 == "\t" }.reversed())
    }

    private static let fencePattern = regex(#"^ {0,3}(`{3,}|~{3,})(.*?)\s*$"#)
    private static func fenceRun(_ line: NSRange, in string: NSString) -> (character: unichar, count: Int, info: NSRange, trimmed: NSRange)? {
        guard let match = fencePattern.firstMatch(in: string as String, range: line) else { return nil }
        let run = match.range(at: 1), info = match.range(at: 2)
        // A backtick fence's info string can't contain backticks, or it's inline code.
        if string.character(at: run.location) == 0x60, string.substring(with: info).contains("`") { return nil }
        return (string.character(at: run.location), run.length, info, NSRange(location: run.location, length: NSMaxRange(info) - run.location))
    }

    private static let quotePrefix = regex(#"^ {0,3}(?:> ?)+"#)
    private static let quoteLevel = regex(#">[ ]?"#)
    private static let calloutTitle = regex(#"^(\[![\w-]+\][+-]? *)(.*)$"#)
    private static let headingPrefix = regex(#"^ {0,3}(#{1,6})(?: +|$)"#)
    private static let rule = regex(#"^ {0,3}([-*_])(?: *\1){2,} *$"#)
    private static let listPrefix = regex(#"^([ \t]*)(?:([-*+])|\d{1,9}[.)])[ \t]+"#)
    private static let taskBox = regex(#"^\[([ xX])\](?= |$)"#)

    private static func block(_ line: NSRange, in string: NSString, lists: inout ListNesting, into spans: inout [NoteSpan]) {
        let text = string as String
        var rest = line
        if let quote = quotePrefix.firstMatch(in: text, range: rest)?.range {
            for level in quoteLevel.matches(in: text, range: quote) { spans.append(NoteSpan(level.range, .marker(.quote))) }
            rest = after(quote, in: rest)
            if let callout = calloutTitle.firstMatch(in: text, range: rest) {
                // With no title of its own, `[!note]` is the title, as written.
                if callout.range(at: 2).length > 0 {
                    spans += [NoteSpan(callout.range(at: 1), .marker(.callout)), NoteSpan(callout.range(at: 2), .calloutTitle)]
                } else {
                    spans.append(NoteSpan(callout.range, .calloutTitle))
                }
                return
            }
            if rest.length > 0 { spans.append(NoteSpan(rest, .quote)) }
        }
        let isRule = rule.firstMatch(in: text, range: rest) != nil
        let list = isRule ? nil : listPrefix.firstMatch(in: text, range: rest)
        lists.line(rest, in: string, indent: list?.range(at: 1))
        if let heading = headingPrefix.firstMatch(in: text, range: rest) {
            spans.append(NoteSpan(heading.range, .marker(.heading)))
            rest = after(heading.range, in: rest)
            if rest.length > 0 { spans.append(NoteSpan(rest, .heading(heading.range(at: 1).length))) }
        } else if isRule {
            spans.append(NoteSpan(NSRange(location: rest.location, length: trimmed(string.substring(with: rest)).utf16.count), .marker(.rule)))
            return
        } else if let list {
            let bullet = list.range, level = lists.level
            spans.append(NoteSpan(bullet, .marker(list.range(at: 2).location != NSNotFound ? .bullet(level: level) : .number(level: level))))
            rest = after(bullet, in: rest)
            if let box = taskBox.firstMatch(in: text, range: rest) {
                let done = string.substring(with: box.range(at: 1)) != " "
                spans.append(NoteSpan(box.range, .marker(.task(done: done))))
                rest = after(box.range, in: rest)
                let content = after(NSRange(location: rest.location, length: min(1, rest.length)), in: rest)
                if done, content.length > 0 { spans.append(NoteSpan(content, .done)) }
            }
        }
        inline(rest, in: string, into: &spans)
    }

    /// How deep each list line is: deeper than the item above it when indented further, back out to whichever
    /// open item it lines up with when indented less. A tab counts as four columns, so two-space and tab lists
    /// both nest. A line of prose at the margin ends the list; a blank line or an indented continuation doesn't.
    private struct ListNesting {
        private var open: [Int] = []
        private(set) var level = 0
        mutating func line(_ line: NSRange, in string: NSString, indent: NSRange?) {
            guard let indent else {
                if line.length > 0, !CharacterSet.whitespaces.contains(Unicode.Scalar(string.character(at: line.location)) ?? " ") { open = [] }
                return
            }
            let columns = string.substring(with: indent).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            while let last = open.last, last > columns { open.removeLast() }
            if open.last != columns { open.append(columns) }
            level = open.count
        }
    }

    private static func after(_ prefix: NSRange, in line: NSRange) -> NSRange {
        NSRange(location: NSMaxRange(prefix), length: NSMaxRange(line) - NSMaxRange(prefix))
    }

    // MARK: Inline

    private static let inlineCode = regex(#"(`+)(?!`)(.+?)(?<!`)\1(?!`)"#)
    private static let templater = regex(#"<%.*?%>"#)
    private static let wikilink = regex(#"(!?\[\[)([^\[\]\n]+?)(\]\])"#)
    private static let markdownLink = regex(#"(!?\[)([^\]\n]*)(\]\()([^)\s]*)(\))"#)
    private static let bareAddress = regex(#"\bhttps?://[^\s<>()\[\]]+"#)
    private static let tagPattern = regex(#"(?<![^\s(])#[\p{L}\p{N}_/-]*[\p{L}_][\p{L}\p{N}_/-]*"#)
    private static let emphasis: [(NSRegularExpression, [NoteMark], NoteMarker)] = [
        // Exactly three stars: `****` between two bold runs (`**a****b**`, from a web paste) closes one and opens the next.
        (regex(#"(?<!\*)(\*\*\*)(?=[^\s*])(.+?)(?<=[^\s*])(\*\*\*)(?!\*)"#), [.strong, .emphasis], .strong),
        (regex(#"(?<![\p{L}\p{N}_])(___)(?=\S)(.+?)(?<=\S)(___)(?![\p{L}\p{N}_])"#), [.strong, .emphasis], .strong),
        (regex(#"(\*\*)(?=\S)(.+?)(?<=\S)(\*\*)"#), [.strong], .strong),
        (regex(#"(?<![\p{L}\p{N}_])(__)(?=\S)(.+?)(?<=\S)(__)(?![\p{L}\p{N}_])"#), [.strong], .strong),
        (regex(#"(\*)(?=[^\s*])(.+?)(?<=[^\s*])(\*)"#), [.emphasis], .emphasis),
        (regex(#"(?<![\p{L}\p{N}_])(_)(?=[^\s_])(.+?)(?<=[^\s_])(_)(?![\p{L}\p{N}_])"#), [.emphasis], .emphasis),
        (regex(#"(~~)(?=\S)(.+?)(?<=\S)(~~)"#), [.strikethrough], .strikethrough),
        (regex(#"(==)(?=\S)(.+?)(?<=\S)(==)"#), [.highlight], .highlight),
    ]

    private static func inline(_ range: NSRange, in string: NSString, into spans: inout [NoteSpan]) {
        guard range.length > 0 else { return }
        let text = string as String
        // Code, commands and link targets are taken verbatim: nothing inside them is styled as emphasis.
        var taken: [NSRange] = []
        func free(_ range: NSRange) -> Bool { !taken.contains { NSIntersectionRange($0, range).length > 0 } }
        func each(_ pattern: NSRegularExpression, _ body: (NSTextCheckingResult) -> Void) {
            for match in pattern.matches(in: text, range: range) where free(match.range) { body(match) }
        }
        each(inlineCode) { match in
            spans += [NoteSpan(match.range(at: 1), .marker(.code)), NoteSpan(match.range(at: 2), .code),
                      NoteSpan(NSRange(location: NSMaxRange(match.range(at: 2)), length: match.range(at: 1).length), .marker(.code))]
            taken.append(match.range)
        }
        each(templater) { match in spans.append(NoteSpan(match.range, .template)); taken.append(match.range) }
        // What a link shows is never empty: with no alias or text, the target or address is what it shows.
        each(wikilink) { match in
            let inside = match.range(at: 2), content = string.substring(with: inside) as NSString
            if string.character(at: match.range.location) == 0x21 { spans.append(NoteSpan(match.range, .embed)) }
            spans += [NoteSpan(match.range(at: 1), .marker(.link)), NoteSpan(match.range(at: 3), .marker(.link))]
            let bar = content.range(of: "|")
            if bar.location != NSNotFound {
                let pipe = NSRange(location: inside.location + bar.location, length: 1)
                let target = NSRange(location: inside.location, length: bar.location), alias = after(pipe, in: inside)
                if target.length > 0 { spans.append(NoteSpan(target, alias.length > 0 ? .linkDestination : .link)) }
                spans.append(NoteSpan(pipe, .marker(.link)))
                if alias.length > 0 { spans.append(NoteSpan(alias, .link)) }
            } else {
                spans.append(NoteSpan(inside, .link))
            }
            taken.append(match.range)
        }
        each(markdownLink) { match in
            let close = NSRange(location: match.range(at: 3).location, length: match.range(at: 3).length)
            if string.character(at: match.range.location) == 0x21 { spans.append(NoteSpan(match.range, .embed)) }
            spans += [NoteSpan(match.range(at: 1), .marker(.link)), NoteSpan(close, .marker(.link)), NoteSpan(match.range(at: 5), .marker(.link))]
            let shown = match.range(at: 2), address = match.range(at: 4)
            if shown.length > 0 { spans.append(NoteSpan(shown, .link)) }
            if address.length > 0 { spans.append(NoteSpan(address, shown.length > 0 ? .linkDestination : .link)) }
            // The text between the brackets can still be bold; the brackets and the address can't.
            taken += [match.range(at: 1), NSRange(location: close.location, length: NSMaxRange(match.range) - close.location)]
        }
        each(bareAddress) { match in spans.append(NoteSpan(match.range, .link)); taken.append(match.range) }
        each(tagPattern) { match in spans.append(NoteSpan(match.range, .tag)); taken.append(match.range) }
        for (pattern, marks, marker) in emphasis {
            // A match that runs into markers already taken is tried again a character on, not skipped whole: in
            // `**a**, *b*` the single-star pattern first finds `*a*` inside the bold, then must still find `*b*`.
            var from = range.location
            // Transparent bounds, so a lookbehind at `from` still sees the character before it.
            while let match = pattern.firstMatch(in: text, options: .withTransparentBounds, range: NSRange(location: from, length: NSMaxRange(range) - from)) {
                let open = match.range(at: 1), close = match.range(at: 3)
                guard free(open), free(close) else { from = match.range.location + 1; continue }
                spans += [NoteSpan(open, .marker(marker)), NoteSpan(close, .marker(marker))] + marks.map { NoteSpan(match.range(at: 2), $0) }
                taken += [open, close]
                from = NSMaxRange(match.range)
            }
        }
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }
}
