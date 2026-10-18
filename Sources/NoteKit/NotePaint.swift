import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Structure drawn in place of its markers: a list's bullet, a task's box, a rule's hairline, a quote's bar. The
/// markers stay in the text with their width, drawn clear, so the painted shape has a place to sit and nothing moves
/// when the caret comes to the line and they show as written. Set by the styler as `.notePaint`; drawn by the
/// paragraph's fragment.
final class NotePaint: NSObject {
    enum Kind: Hashable {
        /// On the bullet character, drawn at the gutter's marker column. Level 1 is a dot, 2 a ring, 3 a square,
        /// then round again.
        case bullet(level: Int)
        /// A bulleted task: on the bullet character, its box drawn where the bullet would be.
        case task(done: Bool)
        /// A numbered task's box: on the `[ ]` itself, the number left showing.
        case box(done: Bool)
        /// On the rule's characters; the hairline spans the column.
        case rule
        /// On one `>`; the bar runs the paragraph's height. The level keeps `>>`'s two bars apart.
        case quote(level: Int)
    }
    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }
    override func isEqual(_ object: Any?) -> Bool { (object as? NotePaint)?.kind == kind }
    override var hash: Int { kind.hashValue }
}

extension NSAttributedString.Key {
    static let notePaint = NSAttributedString.Key("NoteKitPaint")
}

/// Ticking a task: what the box's character becomes, and where the boxes are, read from the text itself.
enum NoteTask {
    /// `[ ]` becomes `[x]`; `[x]` and `[X]` become `[ ]`.
    static func toggled(_ character: String) -> String { character == " " ? "x" : " " }

    /// The box characters (the one between the brackets) of the tasks on the paragraphs `range` touches, and whether
    /// each is ticked. From a fresh scan of the whole text, so a fence above decides, and never from attributes that
    /// an edit or an undo may have left behind.
    static func boxes(inParagraphsOf range: NSRange, in text: String) -> [(box: Int, done: Bool)] {
        let string = text as NSString
        guard NSMaxRange(range) <= string.length else { return [] }
        let paragraphs = string.paragraphRange(for: range)
        return MarkdownStyleScanner.spans(in: text).compactMap { span in
            guard case .marker(.task(let done)) = span.mark,
                  NSLocationInRange(span.range.location, paragraphs) || span.range.location == paragraphs.location else { return nil }
            return (span.range.location + 1, done)
        }
    }
}

/// What a paragraph paints, read once from its attributes; a fragment is made again whenever they change.
struct ParagraphPaints {
    let paints: [(NotePaint.Kind, NSRange)]
    init(_ paragraph: NSAttributedString?) {
        var paints: [(NotePaint.Kind, NSRange)] = []
        paragraph?.enumerateAttribute(.notePaint, in: NSRange(location: 0, length: paragraph?.length ?? 0)) { value, range, _ in
            if let paint = value as? NotePaint { paints.append((paint.kind, range)) }
        }
        self.paints = paints
    }
}

@MainActor extension NSTextLayoutFragment {
    private var paragraph: NSAttributedString? { (textElement as? NSTextParagraph)?.attributedString }

    /// Where the characters `range` (paragraph offsets, starting on one line) are drawn, in the fragment's
    /// coordinates: their horizontal extent, the edge the line starts from (the right, for a right-to-left line) and
    /// which way it runs, the line's baseline, and the first character's font.
    private func place(_ range: NSRange) -> (minX: CGFloat, maxX: CGFloat, leading: CGFloat, forward: CGFloat, baseline: CGFloat, font: PlatformFont)? {
        guard let paragraph, range.location < paragraph.length,
              let line = textLineFragments.first(where: { NSLocationInRange(range.location, $0.characterRange) }) else { return nil }
        let start = line.locationForCharacter(at: range.location).x
        let end = line.locationForCharacter(at: min(NSMaxRange(range), NSMaxRange(line.characterRange))).x
        let font = paragraph.attribute(.font, at: range.location, effectiveRange: nil) as? PlatformFont ?? NoteFace().font
        let style = paragraph.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
        let left = line.typographicBounds.minX, minX = left + min(start, end), maxX = left + max(start, end)
        let rightToLeft = style?.baseWritingDirection == .rightToLeft
        return (minX, maxX, rightToLeft ? maxX : minX, rightToLeft ? -1 : 1, line.baseline, font)
    }

    /// Each paint's rect, in the fragment's coordinates.
    func paintRects(_ paints: ParagraphPaints) -> [(NotePaint.Kind, CGRect)] {
        paints.paints.compactMap { kind, range in
            guard let place = place(range) else { return nil }
            switch kind {
            case .bullet:
                let size = place.font.pointSize * 0.34
                let center = CGPoint(x: place.leading + place.forward * NoteStyler.markerColumn, y: place.baseline - place.font.xHeight / 2)
                return (kind, CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size))
            case .task, .box:
                let side = (place.font.capHeight + 4).rounded()
                // A bulleted task's box stands where its bullet would; a numbered task's over its own brackets.
                var x = (place.minX + place.maxX) / 2
                if case .task = kind { x = place.leading + place.forward * NoteStyler.markerColumn }
                return (kind, CGRect(x: x - side / 2, y: place.baseline - place.font.capHeight / 2 - side / 2, width: side, height: side))
            case .rule:
                let padding = textLayoutManager?.textContainer?.lineFragmentPadding ?? 0
                let width = textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
                let y = (place.baseline - place.font.xHeight / 2).rounded()
                return (kind, CGRect(x: -layoutFragmentFrame.minX + padding, y: y, width: width - padding * 2, height: 1))
            case .quote:
                let width: CGFloat = 2.5
                return (kind, CGRect(x: ((place.minX + place.maxX - width) / 2).rounded(), y: 0, width: width, height: layoutFragmentFrame.height))
            }
        }
    }

    /// The document offset of the paragraph's first character.
    var paragraphStart: Int? {
        guard let content = textLayoutManager?.textContentManager else { return nil }
        return content.offset(from: content.documentRange.location, to: rangeInElement.location)
    }

    /// Whether `point` (the fragment's coordinates) is on a task's box: the box with a few points of slack, or a
    /// square `reach` wide centred on it if that's bigger (a finger's target).
    func hitsTask(_ paints: ParagraphPaints, at point: CGPoint, reach: CGFloat = 0) -> Bool {
        paintRects(paints).contains { kind, rect in
            switch kind {
            case .task, .box:
                let slack = max(4, (reach - rect.width) / 2, (reach - rect.height) / 2)
                return rect.insetBy(dx: -slack, dy: -slack).contains(point)
            default: return false
            }
        }
    }

    /// Draws the paragraph's paints, the fragment's origin at `point`.
    func drawPaints(_ paints: ParagraphPaints, at point: CGPoint, in context: CGContext, colors: NoteColors) {
        let rects = paintRects(paints)
        guard !rects.isEmpty else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: point.x, y: point.y)
        for (kind, rect) in rects {
            switch kind {
            case .bullet(let level):
                let ink = colors.secondary.resolved
                switch (level - 1) % 3 {
                case 0: context.setFillColor(ink); context.fillEllipse(in: rect)
                case 1: context.setStrokeColor(ink); context.setLineWidth(1.1); context.strokeEllipse(in: rect.insetBy(dx: 0.55, dy: 0.55))
                default: context.setFillColor(ink); context.fill(rect.insetBy(dx: rect.width * 0.08, dy: rect.width * 0.08))
                }
            case .task(let done), .box(let done):
                let path = CGPath(roundedRect: rect.insetBy(dx: 0.6, dy: 0.6), cornerWidth: 3.5, cornerHeight: 3.5, transform: nil)
                if done {
                    context.addPath(path); context.setFillColor(colors.accent.resolved); context.fillPath()
                    let tick = CGMutablePath()
                    tick.move(to: CGPoint(x: rect.minX + rect.width * 0.27, y: rect.minY + rect.height * 0.53))
                    tick.addLine(to: CGPoint(x: rect.minX + rect.width * 0.43, y: rect.minY + rect.height * 0.69))
                    tick.addLine(to: CGPoint(x: rect.minX + rect.width * 0.74, y: rect.minY + rect.height * 0.34))
                    context.addPath(tick)
                    context.setStrokeColor(colors.onAccent.resolved); context.setLineWidth(1.6)
                    context.setLineCap(.round); context.setLineJoin(.round); context.strokePath()
                } else {
                    context.addPath(path); context.setStrokeColor(colors.secondary.fading(0.8).resolved)
                    context.setLineWidth(1.2); context.strokePath()
                }
            case .rule:
                context.setFillColor(colors.rule.resolved); context.fill(rect)
            case .quote:
                context.setFillColor(colors.secondary.fading(0.35).resolved); context.fill(rect)
            }
        }
    }
}

extension NSTextLayoutManager {
    /// The fragment under `point` (the text container's coordinates), and the point in that fragment's coordinates.
    func fragment(at point: CGPoint) -> (NSTextLayoutFragment, CGPoint)? {
        guard let fragment = textLayoutFragment(for: point) else { return nil }
        let frame = fragment.layoutFragmentFrame
        return (fragment, CGPoint(x: point.x - frame.minX, y: point.y - frame.minY))
    }
}

extension NSTextLineFragment {
    /// The baseline, down from the top of the fragment the line belongs to.
    var baseline: CGFloat { typographicBounds.minY + glyphOrigin.y }
}

extension PlatformColor {
    /// This colour for the appearance being drawn in.
    var resolved: CGColor {
        #if os(macOS)
        cgColor
        #else
        resolvedColor(with: .current).cgColor
        #endif
    }
}
