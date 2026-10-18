import XCTest
@testable import NoteKit

final class FrontmatterTests: XCTestCase {
    private let note = "---\ntags:\n  - home\n  - measures\ncategories:\n  - google-keep\ncreated: 2026-08-16\ntitle: \"Lazy scripts\"\naliases: [a, \"b c\"]\nempty:\nweird line\n---\n# Body\nKitchen\n"

    func testTheRangeCoversTheBlockAndItsClosingNewline() {
        let range = try! XCTUnwrap(Frontmatter.range(in: note))
        XCTAssertEqual((note as NSString).substring(with: range).hasSuffix("---\n"), true)
        XCTAssertEqual((note as NSString).substring(from: NSMaxRange(range)), "# Body\nKitchen\n")
        XCTAssertNil(Frontmatter.range(in: "# No block\n---\nnot at the top\n---\n"))
        XCTAssertNil(Frontmatter.range(in: "---\nopen: forever\n"))
    }
    func testFieldsListsAndScalars() {
        let fields = Frontmatter.fields(in: note)
        XCTAssertEqual(fields.map(\.key), ["tags", "categories", "created", "title", "aliases", "empty"])
        XCTAssertEqual(fields[0], Frontmatter.Field(key: "tags", values: ["home", "measures"], isList: true))
        XCTAssertEqual(fields[1].values, ["google-keep"]); XCTAssertTrue(fields[1].isList)
        XCTAssertEqual(fields[2], Frontmatter.Field(key: "created", values: ["2026-08-16"], isList: false))
        XCTAssertEqual(fields[3].value, "Lazy scripts", "quotes come off")
        XCTAssertEqual(fields[4], Frontmatter.Field(key: "aliases", values: ["a", "b c"], isList: true), "an inline list")
        XCTAssertEqual(fields[5], Frontmatter.Field(key: "empty", values: [], isList: true), "a key with nothing under it is an empty list")
        XCTAssertTrue(Frontmatter.fields(in: "no block").isEmpty)
    }
}
