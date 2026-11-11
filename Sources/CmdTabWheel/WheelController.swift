import AppKit

/// Glue between input (⌘Tab events, mouse) and the wheel (model + window).
@MainActor
final class WheelController {
    /// The wheel closed by a mouse click while ⌘ is still held — the keyboard side must know,
    /// or releasing ⌘ later would count as a second "commit".
    var onClosedByClick: () -> Void = {}

    private let model: WheelModel
    private let window: WheelWindow
    private let previewer = WindowPreviewer()
    private let history = AppHistory()
    /// The app in front when the wheel opened — gets its focus back if nothing is chosen.
    private var frontAppAtOpen: pid_t?
    /// Mouse moves on screens the panel doesn't cover go to other apps; a global monitor sees them.
    private var otherScreensMonitor: Any?
    /// What we last set, so the cursor is only touched when it actually changes.
    private var showsPointingHand = false
    private var isOpen = false

    init() {
        let model = WheelModel(layout: .standard)
        self.model = model
        // Built up front so the first ⌘Tab shows it instantly.
        self.window = WheelWindow(size: model.layout.canvasSize, content: WheelCanvas(model: model))
        window.onMouseMoved = { [weak self] in self?.pointerMoved() }
        window.onClick = { [weak self] in self?.clicked() }
    }

    func handle(_ input: WheelInput) {
        // Everything but `open` only makes sense while the wheel is up.
        guard isOpen || input.isOpen else { return }
        switch input {
        case .open:
            open()
        case .step(let backward):
            model.step(backward: backward)
            updateCursor()
        case .commit:
            // Nothing selected and nothing touched → quick ⌘Tab → back to the previous app.
            let selected = model.selectedItem
            let target = selected ?? model.quickSwitchItem
            close()
            if target == nil {
                log.notice("closed without a selection")
            } else if selected == nil {
                log.notice("quick switch to \(target?.name ?? "", privacy: .public)")
            }
            if let target {
                activateSoon(target.pid, window: model.chosenWindow(of: target)?.id)
            } else {
                // Hand the focus back to where the user was (our panel took it).
                activateSoon(frontAppAtOpen)
            }
        case .cancel:
            close()
            activateSoon(frontAppAtOpen)
        }
    }

    private func open() {
        guard let screen = NSScreen.withMouse else { return }
        isOpen = true
        frontAppAtOpen = NSWorkspace.shared.frontmostApplication?.processIdentifier
        window.cover(screen)                  // pointer math below needs the final position
        model.reload(pointer: cursorFromWheelCenter(), quickSwitchTo: history.previous, windowMode: .saved)
        window.show()
        setCursor(pointingHand: false)        // replace whatever the app below had (e.g. I-beam)

        otherScreensMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }

        // Screenshot every app right away, before the user points anywhere. Previews from the
        // last opening are already on screen meanwhile; fresh ones replace them as they come.
        let model = self.model
        // With a sector per window an app appears several times — one entry per app is enough.
        let windows = Dictionary(
            model.items.map { item in (item.pid, (model.windows[item.pid] ?? []).map(\.id)) },
            uniquingKeysWith: { first, _ in first }
        )
        previewer.refresh(windows: windows, maxSize: model.layout.previewSize) { key, image in
            model.setPreview(image, for: key)
        }
    }

    private func close() {
        isOpen = false
        if let otherScreensMonitor {
            NSEvent.removeMonitor(otherScreensMonitor)
        }
        otherScreensMonitor = nil
        window.hide()
        model.reset()
        // Don't leave the hand behind: the app below only sets its cursor on its next mouse event.
        setCursor(pointingHand: false)
    }

    private func pointerMoved() {
        model.movePointer(to: cursorFromWheelCenter())
        updateCursor()
    }

    /// Left click: switch to the app whose sector the cursor points at. Clicks in the hub do nothing.
    private func clicked() {
        guard isOpen, let item = model.item(at: cursorFromWheelCenter()) else { return }
        log.notice("clicked \(item.name, privacy: .public)")
        let window = model.chosenWindow(of: item)?.id // before close() resets anything
        close()
        onClosedByClick()
        activateSoon(item.pid, window: window)
    }

    /// We're inside the event tap callback when this is called, and macOS holds the keyboard
    /// until it returns. Talking to WindowServer from in here can stall it — so do it right after.
    private func activateSoon(_ pid: pid_t?, window: CGWindowID? = nil) {
        guard let pid else { return }
        Task { AppActivator.activate(pid: pid, windowID: window) }
    }

    /// Pointing hand while the mouse is on a sector, arrow otherwise (hub, Tab selection).
    /// Works although we're a background app thanks to BackgroundCursor.
    private func updateCursor() {
        let hand = model.isPointingAtSector
        if hand != showsPointingHand {
            setCursor(pointingHand: hand)
        }
    }

    private func setCursor(pointingHand: Bool) {
        showsPointingHand = pointingHand
        (pointingHand ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    /// Cursor position relative to the wheel center (= middle of the panel), y pointing down.
    /// `NSEvent.mouseLocation` is in global screen coordinates with y pointing up, hence the flip.
    private func cursorFromWheelCenter() -> CGPoint {
        let mouse = NSEvent.mouseLocation
        let frame = window.frame
        return CGPoint(x: mouse.x - frame.midX, y: frame.midY - mouse.y)
    }
}

private extension WheelInput {
    var isOpen: Bool {
        if case .open = self { return true }
        return false
    }
}
