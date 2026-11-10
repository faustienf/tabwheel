import SwiftUI

struct HelloView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "circle.circle")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Hello, ⌘Tab Wheel")
                .font(.title)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
