import SwiftUI

/// The wheel plus room around it for the window fan, on one canvas centered in the panel.
struct WheelCanvas: View {
    let model: WheelModel

    var body: some View {
        ZStack {
            WheelView(model: model)
            WindowFanView(model: model)
        }
        .frame(width: model.layout.canvasSize, height: model.layout.canvasSize)
    }
}

/// Window mode "fan": thumbnails of the selected app's windows past the rim, centered on its
/// sector. Pointing further out at one picks it (see `WheelModel.movePointer`).
struct WindowFanView: View {
    let model: WheelModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let layout = model.layout
        ZStack {
            if let index = model.selectedIndex, let fan = model.fan(of: model.items[index]) {
                let item = model.items[index]
                let center = WheelGeometry.angle(of: index, count: model.items.count)
                ForEach(Array(fan.windows.enumerated()), id: \.element.id) { slot, window in
                    let angle = layout.fanAngle(slot: slot, count: fan.windows.count, around: center)
                    FanThumbnail(
                        preview: model.previews[.window(window.id)],
                        icon: item.icon,
                        size: layout.fanThumbnailSize,
                        isChosen: slot == fan.chosen
                    )
                    .offset(x: layout.fanRadius * cos(angle), y: layout.fanRadius * sin(angle))
                    .accessibilityLabel(window.title ?? "\(item.name), window \(slot + 1)")
                }
                // A new id per app: the old fan fades out while the new one fades in.
                .id(item.id)
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .frame(width: layout.canvasSize, height: layout.canvasSize)
        .animation(reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.86), value: model.selectedIndex)
        .animation(reduceMotion ? nil : .spring(response: 0.16, dampingFraction: 0.9), value: model.windowIndex)
    }
}

private struct FanThumbnail: View {
    let preview: NSImage?
    let icon: NSImage
    let size: CGSize
    let isChosen: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isDark = colorScheme == .dark
        // Same accent as the wheel's selection.
        let accent = isDark ? Color(red: 0.57, green: 0.76, blue: 1) : Color(red: 0.16, green: 0.43, blue: 0.85)
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        ZStack {
            if let preview {
                Image(nsImage: preview)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(6)
            } else {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 40, height: 40)
            }
        }
        .frame(width: size.width, height: size.height)
        .background(isDark ? Color(white: 0.12).opacity(0.86) : Color.white.opacity(0.88), in: shape)
        .overlay(shape.strokeBorder(isChosen ? accent : (isDark ? Color.white : .black).opacity(0.12),
                                    lineWidth: isChosen ? 2 : 0.75))
        .shadow(color: .black.opacity(isChosen ? 0.28 : 0.14), radius: isChosen ? 9 : 4, y: 2)
        .scaleEffect(isChosen ? 1.06 : 1)
        .opacity(isChosen ? 1 : 0.82)
    }
}
