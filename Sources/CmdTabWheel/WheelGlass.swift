import AppKit
import SwiftUI

/// Native desktop blur behind the circular glass surface.
struct WheelGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> WheelGlassMaterialView {
        let view = WheelGlassMaterialView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: WheelGlassMaterialView, context: Context) {
        view.needsLayout = true
    }
}

final class WheelGlassMaterialView: NSVisualEffectView {
    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { return }
        maskImage = NSImage(size: bounds.size, flipped: false) { rect in
            NSColor.black.setFill()
            // Keep the blur mask opaque: fading it mixes sharp desktop text back in.
            // Transparency and the radial tint belong in the foreground glass treatment.
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
    }
}
