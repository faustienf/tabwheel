import SwiftUI

/// Only appears before the user makes a selection: the preview is the quick-switch target.
struct QuickSwitchBadge: View {
    var body: some View {
        Label("Switch to previous app", systemImage: "arrow.uturn.backward")
            .modifier(WheelBadgeStyle())
            .accessibilityLabel("Release Command to switch to the previous application")
    }
}
