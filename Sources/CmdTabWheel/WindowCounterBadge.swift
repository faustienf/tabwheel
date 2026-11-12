import SwiftUI

/// "2 / 3 · window title" above the preview, for apps with several windows.
struct WindowCounterBadge: View {
    var position: (index: Int, count: Int)
    var title: String?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "macwindow.on.rectangle")
                .fixedSize()
            Text("\(position.index + 1) / \(position.count)")
                .monospacedDigit()
                .fixedSize()
            if let title {
                Text(title)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(WheelBadgeStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Window \(position.index + 1) of \(position.count)\(title.map { ": \($0)" } ?? "")")
    }
}

/// A small position indicator beneath an app icon, only when it has several windows.
struct WindowPositionIndicator: View {
    var number: Int?
    var count: Int
    var maxWidth: CGFloat
    var tint: Color
    var isSelected: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let number, count > 1 {
            let palette = WheelPalette(isDark: colorScheme == .dark)
            let current = min(max(number - 1, 0), count - 1)
            let positionLimit = max(1, min(7, Int((maxWidth - 1) / 6)))
            let isAggregate = count > positionLimit
            HStack(spacing: 3) {
                ForEach(0..<(isAggregate ? 3 : count), id: \.self) { index in
                    let isCurrent = !isAggregate && index == current
                    Capsule()
                        .fill(isAggregate ? (isSelected ? tint.opacity(0.8) : palette.ink.opacity(0.45)) :
                            (isCurrent ? (isSelected ? tint : palette.ink.opacity(0.72)) : palette.ink.opacity(0.28)))
                        .frame(width: isCurrent ? 7 : 2.5, height: 2.5)
                }
            }
            .scaleEffect(isAggregate ? min(1, maxWidth / 13.5) : 1)
            .frame(height: 3)
            .animation(.easeOut(duration: 0.1), value: isSelected)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Window \(number) of \(count)")
        }
    }
}
