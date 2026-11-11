import SwiftUI

/// Visual layers only; selection geometry and input stay in WheelModel.
struct WheelView: View {
    let model: WheelModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var outerRadius: CGFloat { model.layout.outerRadius }
    private var innerRadius: CGFloat { model.layout.innerRadius }
    private var iconRadius: CGFloat { model.layout.iconRadius }
    private var palette: WheelPalette { WheelPalette(isDark: colorScheme == .dark) }
    private var accent: Color { palette.accent }
    private var isQuickSwitchPreview: Bool { model.selectedItem == nil && model.quickSwitchItem != nil }
    private var hubIdentity: HubIdentity {
        let item = model.selectedItem ?? model.quickSwitchItem
        return HubIdentity(item: item?.id,
                           window: item.flatMap { model.chosenWindow(of: $0)?.id },
                           isQuickSwitch: isQuickSwitchPreview)
    }

    private var selectionAnimation: Animation? {
        if reduceMotion { return .easeOut(duration: 0.09) }
        return .spring(response: 0.18, dampingFraction: 0.88)
    }

    var body: some View {
        wheelContent
            .background(.ultraThinMaterial, in: Circle())
    }

    private var wheelContent: some View {
        ZStack {
            surface
            sectors
                .animation(selectionAnimation, value: model.selectedIndex)
                .animation(.easeOut(duration: 0.07), value: model.selectionReach)
            hub
            icons.animation(selectionAnimation, value: model.selectedIndex)
        }
        .frame(width: model.layout.diameter, height: model.layout.diameter)
    }

    // MARK: - Glass surface

    private var surface: some View {
        Circle()
            .fill(palette.surfaceTint)
            .overlay(Circle().strokeBorder(palette.border, lineWidth: 0.75))
    }

    /// A quiet neutral selection field; coral stays on the rim.
    /// The field fades in from the hub and is blurred well past its straight sides — with hard
    /// edges a ring slice reads as a tilted box, and a glow between hub and icon as a stray shadow.
    private var sectors: some View {
        let count = model.items.count
        let strength = 0.45 + 0.55 * Double(model.selectionReach)
        let rimWidth = 1.25 + 3.25 * model.selectionReach
        return ZStack {
            ForEach(0..<count, id: \.self) { index in
                let isSelected = index == model.selectedIndex
                SectorShape(index: index, count: count,
                            innerRadius: innerRadius + 5, outerRadius: outerRadius - 4)
                    .fill(RadialGradient(
                        colors: [palette.selectionFill.opacity(0), palette.selectionFill],
                        center: .center, startRadius: innerRadius, endRadius: outerRadius
                    ))
                    .blur(radius: 10)
                    .clipShape(Circle().inset(by: 6))
                    .opacity(isSelected ? strength : 0)

                SelectionRim(index: index, count: count, radius: outerRadius - 1)
                    .stroke(accent.opacity(0.98), style: StrokeStyle(lineWidth: rimWidth, lineCap: .round))
                    .opacity(isSelected ? 1 : 0)
            }
        }
    }

    // MARK: - Window preview

    private var hub: some View {
        ZStack {
            hubContent
                .id(hubIdentity)
                .transition(.opacity)
        }
        .frame(width: innerRadius * 2, height: innerRadius * 2)
        // Animate target changes, not asynchronous screenshot refreshes.
        .animation(.easeOut(duration: reduceMotion ? 0.1 : 0.14), value: hubIdentity)
    }

    @ViewBuilder
    private var hubContent: some View {
        if let item = model.selectedItem ?? model.quickSwitchItem {
            CenteredWheelPreview {
                hubPicture(for: item)
            } header: {
                if isQuickSwitchPreview {
                    QuickSwitchBadge()
                } else if let position = model.windowPosition(of: item) {
                    WindowCounterBadge(position: position, title: model.chosenWindow(of: item)?.title)
                        .frame(width: model.layout.previewSize.width)
                }
            } footer: {
                VStack(spacing: 5) {
                    Text(item.name)
                        .font(.system(size: 16, weight: .semibold))
                        .tracking(-0.15)
                        .foregroundStyle(palette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: innerRadius * 1.55)
                    VStack(spacing: 8) {
                        Rectangle()
                            .fill(palette.separator)
                            .frame(width: model.layout.previewSize.width * 0.55, height: 0.5)
                        releaseHint
                    }
                }
            }
        } else {
            VStack(spacing: 10) {
                CommandKeycap(size: CGSize(width: 48, height: 48), symbolSize: 25)
                VStack(spacing: 5) {
                    Text("Choose an app")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(palette.ink.opacity(0.9))
                    Text("Move the pointer or press Tab")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.secondaryInk)
                }
            }
        }
    }

    private var releaseHint: some View {
        HStack(spacing: 5) {
            Text("Release")
            CommandKeycap(size: CGSize(width: 24, height: 20), symbolSize: 11.5)
            Text("to switch")
        }
        .font(.system(size: 12, weight: .regular))
        .foregroundStyle(palette.secondaryInk)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Release Command to switch")
    }

    /// Fixed dimensions keep the title still while a screenshot is loading.
    private func hubPicture(for item: WheelItem) -> some View {
        let box = model.layout.previewSize
        return ZStack {
            if let preview = model.preview(for: item) {
                Image(nsImage: preview)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(palette.border, lineWidth: 0.75)
                    }
                    .shadow(color: .black.opacity(palette.previewShadow), radius: 6, y: 3)
                    .padding(2)
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(RadialGradient(colors: [accent.opacity(0.1), .clear],
                                         center: .center, startRadius: 4, endRadius: box.width / 2))
                Image(nsImage: item.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 60, height: 60)
                    .shadow(color: .black.opacity(palette.previewShadow), radius: 6, y: 3)
            }
        }
        .frame(width: box.width, height: box.height)
        .accessibilityLabel("Window preview for \(item.name)")
    }

    // MARK: - App ring

    private var icons: some View {
        let count = model.items.count
        let size = iconSize(count: count)
        return ZStack {
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                let isSelected = index == model.selectedIndex
                let angle = WheelGeometry.angle(of: index, count: count)
                Image(nsImage: item.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
                    .overlay(alignment: .topTrailing) { WindowNumberBadge(number: item.windowNumber, tint: accent) }
                    .shadow(color: .black.opacity(isSelected ? palette.previewShadow : palette.previewShadow / 2), radius: isSelected ? 4 : 2, y: 2)
                    .scaleEffect(isSelected && !reduceMotion ? 1.045 : 1)
                    .offset(x: iconRadius * cos(angle), y: iconRadius * sin(angle))
                    .accessibilityLabel(item.name)
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
    }

    private func iconSize(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let slotLength = 2 * .pi * iconRadius / CGFloat(count)
        return min(60, slotLength * 0.64)
    }
}

/// A fresh presentation for quick-switch, app selection, and windows of the same app.
private struct HubIdentity: Hashable {
    let item: WheelItem.ID?
    let window: CGWindowID?
    let isQuickSwitch: Bool
}

/// A quiet key outline keeps the shortcut in the same visual weight as its caption.
private struct CommandKeycap: View {
    let size: CGSize
    let symbolSize: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isDark = colorScheme == .dark
        let shape = RoundedRectangle(cornerRadius: size.height * 0.24, style: .continuous)
        let palette = WheelPalette(isDark: isDark)
        let ink = palette.ink
        return Image(systemName: "command")
            .font(.system(size: symbolSize, weight: .medium))
            .foregroundStyle(palette.secondaryInk)
            .frame(width: size.width, height: size.height)
            .background(shape.fill(ink.opacity(isDark ? 0.06 : 0.035)))
            .overlay(shape.strokeBorder(palette.border, lineWidth: 0.65))
    }
}

/// Inset ring slice; this changes the highlight only, never the hit area.
private struct SectorShape: Shape {
    let index: Int
    let count: Int
    let innerRadius: CGFloat
    let outerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let mid = WheelGeometry.angle(of: index, count: count)
        let gap = count > 1 ? min(0.025, WheelGeometry.sectorAngle(count: count) * 0.08) : 0
        let half = WheelGeometry.sectorAngle(count: count) / 2 - gap
        let start = Angle(radians: mid - half)
        let end = Angle(radians: mid + half)

        var path = Path()
        path.addArc(center: center, radius: outerRadius, startAngle: start, endAngle: end, clockwise: false)
        path.addArc(center: center, radius: innerRadius, startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()
        return path
    }
}

private struct SelectionRim: Shape {
    let index: Int
    let count: Int
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let mid = WheelGeometry.angle(of: index, count: count)
        let half = min(WheelGeometry.sectorAngle(count: count) * 0.28, 0.24)
        var path = Path()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: radius,
                    startAngle: .radians(mid - half), endAngle: .radians(mid + half), clockwise: false)
        return path
    }
}

struct WheelView_Previews: PreviewProvider {
    static var previews: some View {
        let model = WheelModel(layout: .standard)
        model.reload(pointer: .zero, quickSwitchTo: nil)
        model.step(backward: false)
        return ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
            WheelView(model: model)
                .padding(24)
                .background(scheme == .dark ? Color(white: 0.18) : Color(white: 0.85))
                .environment(\.colorScheme, scheme)
                .previewDisplayName(scheme == .dark ? "Dark" : "Light")
        }
    }
}
