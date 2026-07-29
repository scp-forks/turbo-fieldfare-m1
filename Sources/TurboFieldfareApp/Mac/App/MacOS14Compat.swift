import SwiftUI
import TurboFieldfareMacPresentation

/// macOS 14 backport helpers for SwiftUI APIs introduced in macOS 15.
///
/// Both modifiers below wrap purely decorative behaviour. On macOS 15 and later
/// they apply the upstream treatment unchanged; on macOS 14 they are no-ops, so
/// the app looks slightly plainer but behaves identically.

/// Applies the tinted window container background on macOS 15+.
///
/// `containerBackground(for: .window)` and `Color.mix(with:by:)` both require
/// macOS 15.
struct WindowContainerBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.containerBackground(for: .window) {
                LinearGradient(
                    colors: [
                        Color(nsColor: .windowBackgroundColor),
                        Color(nsColor: .windowBackgroundColor).mix(
                            with: TurboFieldfareMacTheme.accentColor,
                            by: 0.04),
                    ],
                    startPoint: .top,
                    endPoint: .bottom)
            }
        } else {
            content
        }
    }
}

/// Attaches `WindowDragGesture` on macOS 15+, where it is available.
struct OptionalWindowDragGesture: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.gesture(WindowDragGesture())
        } else {
            content
        }
    }
}
