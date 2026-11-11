import SwiftUI

/// Match the other wheel captions without a separate pill or accent color.
struct WheelBadgeStyle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(WheelPalette(isDark: colorScheme == .dark).ink.opacity(0.9))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
    }
}
