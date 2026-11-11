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

/// Sector per window: which of the app's windows this icon stands for.
struct WindowNumberBadge: View {
    var number: Int?
    var tint: Color
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // The dark-theme accent is a light blue: white digits on it would be hard to read.
        let ink: Color = colorScheme == .dark ? .black : .white
        if let number {
            Text("\(number)")
                .font(.system(size: 10, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(ink)
                .frame(minWidth: 16, minHeight: 16)
                .background(tint, in: Circle())
                .overlay(Circle().strokeBorder(ink.opacity(0.6), lineWidth: 1))
                .offset(x: 5, y: -5)
                .accessibilityLabel("Window \(number)")
        }
    }
}
