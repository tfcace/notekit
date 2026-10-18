import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The colours the editor draws with: only what NoteKit itself puts on the page, the text and its markers, links and
/// tags, the painted bullets, boxes, rules and quote bars, code, highlights, the selection and the caret. The default
/// is the system's own. An app with a palette of its own sets `.noteColors(_:)` on a view above the editor; dynamic
/// colours stay dynamic, resolved as the text is drawn, so light and dark follow by themselves.
public struct NoteColors: Equatable {
    #if os(macOS)
    public typealias Color = NSColor
    #else
    public typealias Color = UIColor
    #endif
    /// Body text.
    public var text: Color
    /// Markers, quotes, finished tasks, a link's address, bullets and open boxes, the save status.
    public var secondary: Color
    /// Links, tags, callout titles, the caret, a ticked box, the editor's buttons.
    public var accent: Color
    /// The tick on a box filled with the accent.
    public var onAccent: Color
    /// Inline code and code blocks sit on this.
    public var codeBackground: Color
    /// `==highlight==`, the selection on the Mac, the conflict banner.
    public var highlight: Color
    /// A thematic break's hairline.
    public var rule: Color

    public init(text: Color, secondary: Color, accent: Color, onAccent: Color, codeBackground: Color, highlight: Color, rule: Color) {
        self.text = text; self.secondary = secondary; self.accent = accent; self.onAccent = onAccent
        self.codeBackground = codeBackground; self.highlight = highlight; self.rule = rule
    }

    /// The system's colours, following light and dark mode and the system accent.
    public static var system: NoteColors {
        #if os(macOS)
        NoteColors(text: .textColor, secondary: .secondaryLabelColor, accent: .controlAccentColor, onAccent: .textBackgroundColor,
                   codeBackground: .quaternarySystemFill, highlight: .selectedTextBackgroundColor, rule: .separatorColor)
        #else
        NoteColors(text: .label, secondary: .secondaryLabel, accent: .tintColor, onAccent: .systemBackground,
                   codeBackground: .quaternarySystemFill, highlight: .tintColor.withAlphaComponent(0.2), rule: .separator)
        #endif
    }
}

private struct NoteColorsKey: EnvironmentKey {
    static var defaultValue: NoteColors { .system }
}

extension EnvironmentValues {
    /// The colours editors below draw with; see `NoteColors`.
    public var noteColors: NoteColors {
        get { self[NoteColorsKey.self] }
        set { self[NoteColorsKey.self] = newValue }
    }
}

extension View {
    /// The colours every editor below this view draws with. A change restyles open notes at once.
    public func noteColors(_ colors: NoteColors) -> some View { environment(\.noteColors, colors) }
}

extension NoteColors.Color {
    /// This colour at `alpha`, still following light and dark mode.
    func fading(_ alpha: CGFloat) -> NoteColors.Color {
        #if os(macOS)
        withAlphaComponent(alpha)
        #else
        UIColor { self.resolvedColor(with: $0).withAlphaComponent(alpha) }
        #endif
    }
}
