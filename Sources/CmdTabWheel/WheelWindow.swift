import AppKit
import SwiftUI
import QuartzCore

/// Full-screen transparent panel with the wheel in the middle, above everything.
///
/// Why full-screen and key: the wheel picks by direction anywhere on screen, so the cursor is
/// usually over another app — and the app whose window is key gets every mouse move: its own
/// cursor (text I-beam), hover effects, ⌘-hover highlights in editors. A non-activating panel
/// can become key without activating our app (like Spotlight: the menu bar stays as it is),
/// and covering the screen keeps the mouse over us. The app below sees nothing, while the
/// cursor moves on its own as usual.
///
/// Created once at launch; shown/hidden with orderFront/orderOut — that's instant.
final class WheelWindow: NSPanel {
    private var wheelView: NSView?

    /// `size`: the square the wheel view draws on — the wheel plus room around it.
    convenience init(size: CGFloat, content: some View) {
        self.init(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel], // no frame; key without activating us
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true                  // shadow follows the drawn (circular) shape
        animationBehavior = .none         // use our brief fade instead of an additional system animation
        appearance = nil                  // inherit the app theme, or macOS when set to System
        isReleasedWhenClosed = false
        ignoresMouseEvents = false        // explicit: take the mouse even over transparent pixels
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false         // panels hide when their app deactivates; ours never activates
        level = .popUpMenu                // above regular windows, the Dock and the menu bar
        collectionBehavior = [
            .canJoinAllSpaces,            // visible on every desktop (Space)
            .fullScreenAuxiliary,         // and over full-screen apps
            .stationary,
            .ignoresCycle,
        ]

        let backdrop = BackdropView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        let wheel = Self.makeWheelView(size: size, content: content)
        backdrop.addSubview(wheel)
        contentView = backdrop
        wheelView = wheel
    }

    override var canBecomeKey: Bool { true }  // borderless windows refuse by default
    override var canBecomeMain: Bool { false }

    /// Cover the whole screen, wheel in its middle.
    func cover(_ screen: NSScreen) {
        setFrame(screen.frame, display: false)
        if let wheelView, let bounds = contentView?.bounds {
            wheelView.setFrameOrigin(NSPoint(
                x: (bounds.width - wheelView.frame.width) / 2,
                y: (bounds.height - wheelView.frame.height) / 2
            ))
        }
    }

    /// Show and take keyboard/mouse focus — without activating our app.
    func show() {
        contentView?.layoutSubtreeIfNeeded() // apply fresh SwiftUI state before the first frame
        // A brief opacity fade adds no spatial motion, including with Reduce Motion enabled.
        alphaValue = 0
        orderFrontRegardless()
        makeKey()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    func hide() {
        orderOut(nil)
        alphaValue = 1
    }

    /// The wheel reads the mouse from MouseTap, which works even where this panel gets no
    /// events (Mission Control, other screens). Whatever does land here is swallowed:
    /// nothing below should react while the wheel is open.
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
             .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp, .scrollWheel:
            break
        default:
            super.sendEvent(event)
        }
    }

    /// Hosts the circular glass surface and wheel content inside the transparent panel.
    private static func makeWheelView(size: CGFloat, content: some View) -> NSView {
        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = []
        hosting.frame = NSRect(x: 0, y: 0, width: size, height: size)
        hosting.autoresizingMask = [] // stay compact inside the full-screen panel
        return hosting
    }
}

/// Invisible full-screen layer under the wheel. It must not be fully transparent — fully
/// transparent pixels let clicks and hover through to the window below.
private final class BackdropView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0, alpha: 1.0 / 255).cgColor // invisible to the eye
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }
}

extension NSScreen {
    /// The screen the mouse cursor is on.
    static var withMouse: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return screens.first { $0.frame.contains(mouse) } ?? main
    }
}
