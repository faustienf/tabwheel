import AppKit

/// The mouse while the wheel is open, from an event tap rather than the wheel's panel.
///
/// A panel gets the mouse only when WindowServer hands it the events: Mission Control keeps
/// them for itself, and on the other screens they go to the apps there. A tap sees every
/// event before any app does, so the wheel follows the pointer wherever it is.
///
/// - Moves and drags are reported and passed on: the cursor moves as usual.
/// - Clicks and scrolling are swallowed: nothing below the wheel should react. A button that
///   went down before the wheel opened is let go as usual, or a drag in the app below would
///   never end.
///
/// On only while the wheel is open. The rest of the time the system's mouse doesn't go
/// through our code at all, so a busy main thread can't make it lag.
@MainActor
final class MouseTap {
    /// The pointer in screen coordinates (origin bottom left, like `NSEvent.mouseLocation`).
    var onMove: @MainActor (NSPoint) -> Void = { _ in }
    /// Left button released, after it went down while the wheel was open.
    var onClick: @MainActor (NSPoint) -> Void = { _ in }

    private var tap: CFMachPort?
    private var isEnabled = false
    /// Buttons that went down while the wheel was open: their release is ours too.
    private var heldButtons = Set<Int64>()

    func enable() {
        heldButtons = []
        isEnabled = true
        if tap == nil { tap = Self.makeTap(for: self) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    func disable() {
        isEnabled = false
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    }

    private static func makeTap(for mouseTap: MouseTap) -> CFMachPort? {
        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .scrollWheel,
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap, // can swallow events
            eventsOfInterest: mask,
            callback: mouseTapCallback,
            userInfo: Unmanaged.passUnretained(mouseTap).toOpaque()
        ) else {
            log.error("mouse tap: CGEvent.tapCreate failed")
            return nil
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return tap
    }

    /// Returns true to pass the event on, false to swallow it.
    fileprivate func handle(type: CGEventType, location: NSPoint, button: Int64) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS disables taps that are too slow; turn it back on if the wheel is still open.
            if isEnabled, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            onMove(location)
            return true
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            heldButtons.insert(button)
            return false
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            guard heldButtons.remove(button) != nil else { return true } // pressed before the wheel opened
            if type == .leftMouseUp { onClick(location) } // on release, like a normal button
            return false
        case .scrollWheel:
            return false
        default:
            return true
        }
    }
}

/// C callback for the tap: no captures allowed, so the MouseTap comes through `userInfo`.
private func mouseTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let mouseTap = Unmanaged<MouseTap>.fromOpaque(userInfo).takeUnretainedValue()
    // CG coordinates start at the top left of the main display; AppKit's at its bottom left.
    let location = NSPoint(x: event.location.x, y: CGDisplayBounds(CGMainDisplayID()).height - event.location.y)
    let button = event.getIntegerValueField(.mouseEventButtonNumber)
    // The run loop source is on the main run loop, so we are on the main thread.
    let pass = MainActor.assumeIsolated {
        mouseTap.handle(type: type, location: location, button: button)
    }
    return pass ? Unmanaged.passUnretained(event) : nil
}
