import XCTest
@testable import NoteKit

final class MarkdownStyleScannerTests: XCTestCase {
    /// The text each span of `mark` covers, in order.
    private func marked(_ text: String, _ mark: NoteMark) -> [String] {
        let string = text as NSString
        return MarkdownStyleScanner.spans(in: text).filter { $0.mark == mark }.map { string.substring(with: $0.range) }
    }
    /// The text each marker covers, whatever it marks: `marked(text, NoteMark.marker)`.
    private func marked(_ text: String, _ marker: (NoteMarker) -> NoteMark) -> [String] {
        let string = text as NSString
        return MarkdownStyleScanner.spans(in: text).filter { if case .marker = $0.mark { true } else { false } }.map { string.substring(with: $0.range) }
    }
    /// Each marker's kind, in order.
    private func markers(_ text: String) -> [NoteMarker] {
        MarkdownStyleScanner.spans(in: text).compactMap { if case .marker(let kind) = $0.mark { kind } else { nil } }
    }

    func testHeadingsAndTags() {
        XCTAssertEqual(marked("## Cutlery drawer", .heading(2)), ["Cutlery drawer"])
        XCTAssertEqual(marked("## Cutlery drawer", NoteMark.marker), ["## "])
        XCTAssertEqual(marked("#home and #home/kitchen", .tag), ["#home", "#home/kitchen"])
        XCTAssertEqual(marked("#home and #home/kitchen", .heading(1)), [])
        XCTAssertEqual(marked("####### seven", .heading(6)), [], "only six levels")
        XCTAssertEqual(marked("issue #12", .tag), [], "a number isn't a tag")
    }

    func testInlineEmphasis() {
        let line = "a **bold** and *it* and ~~gone~~ and ==hi=="
        XCTAssertEqual(marked(line, .strong), ["bold"])
        XCTAssertEqual(marked(line, .emphasis), ["it"])
        XCTAssertEqual(marked(line, .strikethrough), ["gone"])
        XCTAssertEqual(marked(line, .highlight), ["hi"])
        XCTAssertEqual(marked(line, NoteMark.marker), ["**", "**", "*", "*", "~~", "~~", "==", "=="])
        XCTAssertEqual(marked("snake_case_word and 2 * 3 * 4", .emphasis), [], "intraword underscores and spaced stars")
        XCTAssertEqual(marked("***both***", .strong), ["both"])
        XCTAssertEqual(marked("***both***", .emphasis), ["both"])
        XCTAssertEqual(marked("**wool socks**, the *light* jacket", .emphasis), ["light"], "found past a match inside the bold")
        XCTAssertEqual(marked("**a****; b****?**", .strong), ["a", "; b", "?"], "four stars close one bold and open the next")
        XCTAssertEqual(marked("**a****; b****?**", .emphasis), [])
    }

    func testWikilinksAliasesAndEmbeds() {
        let line = "see [[clothing]] and [[numbers and measures|measures]] and ![[photo.png]]"
        XCTAssertEqual(marked(line, .link), ["clothing", "measures", "photo.png"])
        XCTAssertEqual(marked(line, .linkDestination), ["numbers and measures"])
        XCTAssertEqual(marked(line, NoteMark.marker), ["[[", "]]", "[[", "|", "]]", "![[", "]]"])
        XCTAssertEqual(marked(line, .embed), ["![[photo.png]]"])
        XCTAssertEqual(marked("[[target|]]", .link), ["target"], "an empty alias shows the target")
        XCTAssertEqual(marked("[[a **b** c]]", .strong), [], "a link's target is left alone")
    }

    func testCodeAndLinksProtectTheirContents() {
        XCTAssertEqual(marked("`**not bold**` but **bold**", .code), ["**not bold**"])
        XCTAssertEqual(marked("`**not bold**` but **bold**", .strong), ["bold"])
        let link = "[Oura](https://ouraring.com/a_b_c) sizing"
        XCTAssertEqual(marked(link, .link), ["Oura"])
        XCTAssertEqual(marked(link, .linkDestination), ["https://ouraring.com/a_b_c"])
        XCTAssertEqual(marked(link, NoteMark.marker), ["[", "](", ")"])
        XCTAssertEqual(marked(link, .emphasis), [])
        XCTAssertEqual(marked("[](https://a.b)", .link), ["https://a.b"], "with no text, the address is what shows")
        XCTAssertEqual(marked("![alt](p.png)", .embed), ["![alt](p.png)"])
        XCTAssertEqual(marked("<% tp.date.now(\"YYYY\") %> today", .template), ["<% tp.date.now(\"YYYY\") %>"])
    }

    func testFrontmatterOnlyAtTheTop() {
        let note = "---\ntags: [home]\n---\n# Measures"
        XCTAssertEqual(marked(note, .frontmatter), ["---\ntags: [home]\n---"])
        XCTAssertEqual(marked(note, .heading(1)), ["Measures"])
        XCTAssertEqual(marked("text\n---\nmore", .frontmatter), [])
        XCTAssertEqual(marked("text\n---\nmore", NoteMark.marker), ["---"], "lower down it's a rule")
    }

    func testFencedCodeIsVerbatim() {
        let note = "```swift\nlet a = **b** // [[x]]\n```\n**after**"
        XCTAssertEqual(marked(note, .codeBlock), ["let a = **b** // [[x]]"])
        XCTAssertEqual(marked(note, NoteMark.marker), ["```swift", "```", "**", "**"])
        XCTAssertEqual(marked(note, .strong), ["after"])
        XCTAssertEqual(marked(note, .link), [])
        XCTAssertEqual(marked("```\nnever closed **x**", .codeBlock), ["never closed **x**"])
    }

    func testCalloutsAndQuotes() {
        let note = "> [!note] Drawer\n> width **first**\nafter"
        XCTAssertEqual(marked(note, .calloutTitle), ["Drawer"])
        XCTAssertEqual(marked(note, .quote), ["width **first**"])
        XCTAssertEqual(marked(note, .strong), ["first"])
        XCTAssertEqual(marked(note, NoteMark.marker), ["> ", "[!note] ", "> ", "**", "**"])
        XCTAssertEqual(marked("> [!tip]-", .calloutTitle), ["[!tip]-"], "with no title, the type is the title")
        XCTAssertEqual(marked("> [!tip]-", NoteMark.marker), ["> "])
    }

    func testListsAndTasks() {
        let note = "- [ ] milk\n- [x] eggs\n1. first\n  * nested"
        XCTAssertEqual(marked(note, .marker(.task(done: false))), ["[ ]"])
        XCTAssertEqual(marked(note, .marker(.task(done: true))), ["[x]"])
        XCTAssertEqual(marked(note, .done), ["eggs"])
        XCTAssertEqual(marked(note, NoteMark.marker), ["- ", "[ ]", "- ", "[x]", "1. ", "  * "])
        XCTAssertEqual(markers(note), [.bullet(level: 1), .task(done: false), .bullet(level: 1), .task(done: true), .number(level: 1), .bullet(level: 2)])
        XCTAssertEqual(markers("1. [ ] numbered task"), [.number(level: 1), .task(done: false)])
        XCTAssertEqual(marked("- [ ]", .marker(.task(done: false))), ["[ ]"], "a box with nothing after it, at the note's end")
    }

    func testMarkersSayWhatTheyMark() {
        XCTAssertEqual(markers("## a **b** *c* ~~d~~ ==e== `f` [[g|h]] [i](j)"),
                       [.heading, .strong, .strong, .emphasis, .emphasis, .strikethrough, .strikethrough, .highlight, .highlight,
                        .code, .code, .link, .link, .link, .link, .link, .link])
        XCTAssertEqual(markers("text\n***\n```js\nx\n```"), [.rule, .fence, .fence])
        XCTAssertEqual(marked("> > nested", NoteMark.marker), ["> ", "> "], "one marker per level, each a bar")
        XCTAssertEqual(markers("> > nested"), [.quote, .quote])
    }

    func testListLevelsFollowTheIndentAboveThem() {
        // Two-space and tab indents both nest; back out to the item a line lines up with; a blank line keeps the list.
        let note = "- a\n  - b\n    - c\n  - d\n\n- e\n\t- f\n\t\t- g\n1. h\n   - i"
        XCTAssertEqual(markers(note), [1, 2, 3, 2, 1, 2, 3, 1, 2].map { NoteMarker.bullet(level: $0) }.enumerated().map { $0.offset == 7 ? .number(level: 1) : $0.element })
        // A list that starts indented starts at level 1; prose at the margin ends it.
        XCTAssertEqual(markers("  - a\n    - b\nprose\n    - c"), [.bullet(level: 1), .bullet(level: 2), .bullet(level: 1)])
        // A rule isn't a list item, even one made of stars: the list after it starts afresh.
        XCTAssertEqual(markers("- a\n* * *\n  - b"), [.bullet(level: 1), .rule, .bullet(level: 1)])
    }

    func testRangesAreUTF16AcrossHebrewAndEmoji() {
        XCTAssertEqual(marked("🥕 **מרק** שורשים", .strong), ["מרק"])
        XCTAssertEqual(marked("👩‍👩‍👧 [[בגדים|clothing]]", .link), ["clothing"])
        XCTAssertEqual(marked("👩‍👩‍👧 [[בגדים|clothing]]", .linkDestination), ["בגדים"])
    }

    func testSpansNeverLeaveTheText() {
        let samples = ["**", "[[", "]]", "`", "> ", "- [", "---", "```", "#", "*a", "[a](", "<%", "==a", "~~"]
        for text in samples {
            let length = (text as NSString).length
            for span in MarkdownStyleScanner.spans(in: text) {
                XCTAssertTrue(span.range.location >= 0 && NSMaxRange(span.range) <= length && span.range.length > 0, "\(text): \(span)")
            }
        }
    }
}
