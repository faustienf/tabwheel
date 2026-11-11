import SwiftUI

/// Match the other wheel captions without a separate pill or accent color.
struct WheelBadgeStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.primary.opacity(0.95))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
    }
}
