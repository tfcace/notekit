import Foundation

/// The YAML block at the top of a note, as Obsidian writes it: `---`, `key: value` lines (a list as `- item` lines
/// beneath the key, or `[a, b]` inline), `---`. Read for showing, never rewritten: the block stays in the text byte for
/// byte.
public enum Frontmatter {
    public struct Field: Equatable, Sendable {
        public let key: String
        public let values: [String]
        /// A list in the file (`- a` lines or `[a, b]`), even with one item: tags, categories, aliases, authors.
        public let isList: Bool
        public var value: String { values.joined(separator: ", ") }
    }

    /// The block's range in UTF-16, including its closing line's newline (so the body starts right after it), or nil
    /// when the note doesn't start with one.
    public static func range(in text: String) -> NSRange? {
        guard let span = MarkdownStyleScanner.spans(in: text).first(where: { $0.mark == .frontmatter && $0.range.location == 0 }) else { return nil }
        let string = text as NSString
        var end = NSMaxRange(span.range)
        if end < string.length, string.character(at: end) == 0x0A { end += 1 }
        return NSRange(location: 0, length: end)
    }

    /// The block's fields in order. A key with `- item` lines beneath it, or `[a, b]`, is a list; anything else is
    /// one value, quotes removed. Lines that aren't `key: value` or `- item` are skipped.
    public static func fields(in text: String) -> [Field] {
        guard let range = range(in: text) else { return [] }
        let block = (text as NSString).substring(with: range).split(separator: "\n", omittingEmptySubsequences: false).dropFirst().dropLast(2)
        var fields: [Field] = []
        var current: (key: String, items: [String])?
        func close() { if let open = current { fields.append(Field(key: open.key, values: open.items, isList: true)); current = nil } }
        for raw in block {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- "), current != nil { current?.items.append(unquoted(String(line.dropFirst(2)))); continue }
            close()
            guard let colon = line.firstIndex(of: ":"), colon > line.startIndex else { continue }
            let key = String(line[..<colon]), rest = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { continue }
            if rest.isEmpty { current = (key, []) }
            else if rest.hasPrefix("["), rest.hasSuffix("]") {
                fields.append(Field(key: key, values: rest.dropFirst().dropLast().split(separator: ",").map { unquoted($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }, isList: true))
            } else { fields.append(Field(key: key, values: [unquoted(rest)], isList: false)) }
        }
        close()
        return fields
    }

    /// The block's own lines between the fences, as the file has them (for a glimpse of it).
    public static func lines(in text: String) -> [String] {
        guard let range = range(in: text) else { return [] }
        return (text as NSString).substring(with: range).split(separator: "\n", omittingEmptySubsequences: false).dropFirst().dropLast(2).map(String.init)
    }

    private static func unquoted(_ value: String) -> String {
        if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first { return String(value.dropFirst().dropLast()) }
        return value
    }
}
