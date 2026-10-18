import Foundation

/// A note's text as the editor sees it, tied to the exact bytes it came from. Nothing is written back unless the
/// text actually changed, and a write keeps the file's own conventions: a byte order mark, Windows line endings.
public struct NoteText: Sendable {
    public private(set) var text: String
    private var original: Data
    private let byteOrderMark: Bool
    /// Every line ends in CRLF. The editor works in plain newlines and the file gets CRLF back on writing; a file
    /// that mixes both is edited as it is, so no line's ending changes unless that line is edited.
    private let windowsLines: Bool

    /// Nil when the file isn't UTF-8, which the editor won't risk rewriting.
    public init?(data: Data) {
        let mark: [UInt8] = [0xEF, 0xBB, 0xBF]
        byteOrderMark = data.starts(with: mark)
        let body = byteOrderMark ? data.dropFirst(mark.count) : data[...]
        guard let decoded = String(data: body, encoding: .utf8) else { return nil }
        var newlines = 0, windows = 0, previous: UInt8 = 0
        for byte in body {
            if byte == 0x0A { newlines += 1; if previous == 0x0D { windows += 1 } }
            previous = byte
        }
        windowsLines = newlines > 0 && windows == newlines
        text = windowsLines ? decoded.replacingOccurrences(of: "\r\n", with: "\n") : decoded
        original = data
    }

    /// The bytes to write for `edited`, or nil when it's the note as loaded (or last saved), so nothing is written.
    public func data(for edited: String) -> Data? {
        guard edited != text else { return nil }
        let body = windowsLines ? edited.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n") : edited
        return (byteOrderMark ? Data([0xEF, 0xBB, 0xBF]) : Data()) + Data(body.utf8)
    }

    /// After a write succeeds, what was written is the new baseline.
    public mutating func saved(_ written: Data) {
        if let note = NoteText(data: written) { self = note }
    }

    /// Whether the file still holds what was loaded or last saved; anything else came from another app.
    public func matches(_ data: Data) -> Bool { data == original }
}

/// Which way a paragraph of a note reads. Each line chooses for itself, so a Hebrew line in an English note lays
/// out right to left, and a line with no words (a number, an empty line) keeps the direction of the line above.
public enum ParagraphDirection: Equatable, Sendable {
    case leftToRight, rightToLeft

    /// Right to left when a third or more of the words are in a right-to-left script: Latin names and terms inside
    /// Hebrew shouldn't flip the line. Addresses don't count. Nil when the line has no words.
    public static func of<Line: StringProtocol>(_ line: Line) -> ParagraphDirection? {
        let words = String(line).replacingOccurrences(of: #"(https?://|www\.)\S+"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).filter { $0.unicodeScalars.contains { $0.properties.isAlphabetic } }
        guard !words.isEmpty else { return nil }
        let rightToLeft = words.count { $0.unicodeScalars.contains(where: isRightToLeft) }
        return rightToLeft * 3 >= words.count && rightToLeft > 0 ? .rightToLeft : .leftToRight
    }

    /// One direction per line of `text`, including an empty last line after a final newline.
    public static func lines(in text: String) -> [ParagraphDirection] {
        var current = ParagraphDirection.leftToRight
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            if let direction = of(line) { current = direction }
            return current
        }
    }

    private static func isRightToLeft(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0590...0x05FF, 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF: true
        default: false
        }
    }
}
