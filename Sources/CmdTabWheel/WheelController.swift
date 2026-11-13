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
    /// The mouse while the wheel is open, on every screen and over Mission Control too.
    private let mouseTap = MouseTap()
    private var isOpen = false
    /// Live Preview waits this long after the wheel opens. Most picks are done by then, and the
    /// screenshot taken on opening is fresh enough for them; the stream is for lingering.
    private static let livePreviewDelay = Duration.seconds(1)
    private var livePreviewStart: Task<Void, Never>?
    private var isLivePreviewDue = false
    private var terminationObserver: NSObjectProtocol?
    /// An app we told to close a window or quit is asking something first ("Save changes?").
    /// The wheel covers that question, so when the wheel closes this app comes to the front.
    private var askingApp: (pid: pid_t, window: CGWindowID?)?

    init() {
        let model = WheelModel(layout: .standard)
        self.model = model
        // Built up front so the first ⌘Tab shows it instantly.
        self.window = WheelWindow(size: model.layout.canvasSize, content: WheelView(model: model))
        mouseTap.onMove = { [weak self] mouse in self?.pointerMoved(to: mouse) }
        mouseTap.onClick = { [weak self] mouse in self?.clicked(at: mouse) }
        // An app that quits while the wheel is open (⌘Q here, or on its own) leaves the wheel.
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { self?.appTerminated(pid) }
        }
    }

    func setLivePreviewEnabled(_ enabled: Bool) {
        previewer.isLivePreviewEnabled = enabled
        if enabled { updateLivePreview() }
    }

    func handle(_ input: WheelInput) {
        // Everything but `open` only makes sense while the wheel is up.
        guard isOpen || input.isOpen else { return }
        switch input {
        case .open:
            open()
        case .step(let backward):
            model.step(backward: backward)
            updateLivePreview()
        case .commit:
            // Closed windows or quit apps and picked nothing after → done tidying up: back to
            // where the user was, not to the app the selection was merely left on.
            if model.hasClosedSomething {
                close()
                log.notice("closed after closing windows/apps: back to where we were")
                returnFocusOrShowQuestion()
                return
            }
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
                returnFocusOrShowQuestion()
            }
        case .cancel:
            close()
            returnFocusOrShowQuestion()
        case .closeWindow:
            if let item = model.selectedItem, let window = model.closableWindow(of: item) {
                closeWindow(window, of: item)
            }
        case .quitApp:
            if let item = model.selectedItem {
                quit(item)
            }
        }
    }

    /// Close button or ⌘W. The wheel stays open for the next one.
    /// The app's last window is the same as ⌘Q: closing the only window means "done with it".
    private func closeWindow(_ window: AppWindow, of item: WheelItem) {
        log.notice("closing a window of \(item.name, privacy: .public)")
        model.removeWindow(window.id, of: item.pid)
        updateLivePreview()
        let pid = item.pid
        let name = item.name
        // Finder can't quit — it just stays without windows.
        let mayQuit = item.app.bundleIdentifier != "com.apple.finder"
        let windowID = window.id
        // Accessibility and the window checks talk to other processes: off the main thread.
        Task.detached(priority: .userInitiated) { [weak self] in
            // Quit straight away, without closing the window first: that doesn't depend on the
            // app reacting to its close button (a busy one times out, Stickies ignores it).
            if mayQuit, !WindowList.hasOtherWindows(of: pid, besides: windowID) {
                log.notice("that was the last window of \(name, privacy: .public): quitting it")
                await self?.terminate(pid)
                return
            }
            let windowsBefore = WindowList.onScreenWindowIDs(of: pid)
            // A question ("Save changes?") is a new window: a sheet or an alert.
            let isAsking = { !WindowList.onScreenWindowIDs(of: pid).subtracting(windowsBefore).isEmpty }
            guard AXWindow.close(pid: pid, windowID: windowID) else { return }
            // Windows go within a frame or two.
            var closed = await AXWindow.waitUntilClosed(pid: pid, windowID: windowID, timeout: .milliseconds(500))
            if !closed, !isAsking() {
                // Still there and no question: the app ignored the pressed button (Stickies
                // does). Its own Close menu command, then.
                log.notice("\(name, privacy: .public) ignored its close button, trying its Close command")
                if AXWindow.closeViaMenu(pid: pid, windowID: windowID) {
                    closed = await AXWindow.waitUntilClosed(pid: pid, windowID: windowID, timeout: .milliseconds(500))
                }
            }
            guard !closed else { return }
            guard isAsking() else {
                log.error("couldn't close a window of \(name, privacy: .public)")
                return
            }
            // The user has to see the question: the wheel covers it.
            log.notice("\(name, privacy: .public) is asking something before closing the window")
            await self?.appIsAsking(pid: pid, window: windowID)
        }
    }

    /// See `askingApp`. If the wheel is already gone, show the question right away.
    private func appIsAsking(pid: pid_t, window: CGWindowID?) {
        if isOpen {
            askingApp = (pid, window)
        } else {
            activateSoon(pid, window: window, opensWindowIfNone: false)
        }
    }

    /// Wheel closed without a new pick: an app with a pending question comes first, else back
    /// to where the user was.
    private func returnFocusOrShowQuestion() {
        if let asking = askingApp, kill(asking.pid, 0) == 0 {
            log.notice("showing the question of pid \(asking.pid, privacy: .public)")
            activateSoon(asking.pid, window: asking.window, opensWindowIfNone: false)
        } else {
            returnFocus()
        }
        askingApp = nil
    }

    /// ⌘Q, like in the system switcher. The app may ask about unsaved documents first, so its
    /// sector goes only once it has actually quit (the termination observer in `init`).
    private func quit(_ item: WheelItem) {
        // Finder ignores quit requests (unless a hidden setting allows it); don't pretend.
        guard item.app.bundleIdentifier != "com.apple.finder" else { return }
        log.notice("quitting \(item.name, privacy: .public)")
        model.noteQuitRequested()
        let pid = item.pid
        Task { await terminate(pid) } // after the event tap callback returns
    }

    /// Asks the app to quit. Still running a second later: it's asking about unsaved documents.
    private func terminate(_ pid: pid_t) async {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.terminate()
        try? await Task.sleep(for: .seconds(1))
        if !app.isTerminated { appIsAsking(pid: pid, window: nil) }
    }

    private func appTerminated(_ pid: pid_t) {
        guard isOpen else { return }
        model.removeApp(pid)
        updateLivePreview()
    }

    private func open() {
        // ⌘Tab does nothing there, as with the system switcher. The rest of this ⌘ press
        // (Tab, releasing ⌘) is ignored too: everything but `open` needs an open wheel.
        if MissionControl.isOpen() {
            log.notice("⌘Tab in Mission Control: no wheel")
            return
        }
        guard let screen = NSScreen.withMouse else { return }
        isOpen = true
        askingApp = nil
        frontAppAtOpen = NSWorkspace.shared.frontmostApplication?.processIdentifier
        window.cover(screen)                  // pointer math below needs the final position
        model.reload(pointer: cursorFromWheelCenter(), quickSwitchTo: history.previous)
        window.show()
        NSCursor.arrow.set()                  // replace whatever the app below had (e.g. I-beam)
        mouseTap.enable()

        // Screenshot every app right away, before the user points anywhere. Previews from the
        // last opening are already on screen meanwhile; fresh ones replace them as they come.
        let model = self.model
        // An app with several windows has several sectors — one entry per app is enough.
        let windows = Dictionary(
            model.items.map { item in (item.pid, (model.windows[item.pid] ?? []).map(\.id)) },
            uniquingKeysWith: { first, _ in first }
        )
        previewer.refresh(windows: windows, maxSize: model.layout.previewSize) { key, image in
            model.setPreview(image, for: key)
        }
        scheduleLivePreview()
    }

    private func close() {
        isOpen = false
        livePreviewStart?.cancel()
        isLivePreviewDue = false
        // Only the stream: screenshots still being taken land in the cache for the next ⌘Tab.
        previewer.stopLivePreview()
        mouseTap.disable()
        window.hide()
        model.reset()
        // The app below restores its own cursor on its next mouse event.
        NSCursor.arrow.set()
    }

    private func pointerMoved(to mouse: NSPoint) {
        model.movePointer(to: cursorFromWheelCenter(mouse))
        // A plain arrow everywhere in the wheel. Set on every move: the app below may put its
        // own cursor back (an I-beam, say) while ours is a background app.
        NSCursor.arrow.set()
        updateLivePreview()
    }

    /// The selected sector’s close action keeps the wheel open. Hub clicks do nothing;
    /// clicks on sectors switch to the app the cursor points at.
    private func clicked(at mouse: NSPoint) {
        guard isOpen else { return }
        let point = cursorFromWheelCenter(mouse)
        if let (item, window) = model.closeTarget(at: point) {
            closeWindow(window, of: item)
            return
        }
        guard let item = model.item(at: point) else { return }
        log.notice("clicked \(item.name, privacy: .public)")
        let window = model.chosenWindow(of: item)?.id // before close() resets anything
        close()
        onClosedByClick()
        activateSoon(item.pid, window: window)
    }

    /// We're inside the event tap callback when this is called, and macOS holds the keyboard
    /// until it returns. Talking to WindowServer from in here can stall it — so do it right after.
    private func activateSoon(_ pid: pid_t?, window: CGWindowID? = nil, opensWindowIfNone: Bool = true) {
        guard let pid else { return }
        Task { AppActivator.activate(pid: pid, windowID: window, opensWindowIfNone: opensWindowIfNone) }
    }

    /// Hand the focus back to the app that had it when the wheel opened (our panel took it).
    /// Never opens a window: if the user just closed that app's last one, it stays closed.
    private func returnFocus() {
        activateSoon(frontAppAtOpen, opensWindowIfNone: false)
    }

    /// Streams the window in the hub (Live Preview in the menu). Call on every selection change.
    /// Not before `livePreviewDelay`: a capture stream lights the screen recording indicator
    /// in the menu bar, and a quick ⌘Tab shouldn't flash it. Until then the hub shows the
    /// screenshot taken on opening.
    private func updateLivePreview() {
        guard isOpen, isLivePreviewDue else { return }
        let model = self.model
        let item = model.selectedItem ?? model.quickSwitchItem
        let key = item.map { item in
            model.chosenWindow(of: item).map { PreviewKey.window($0.id) } ?? .app(item.pid)
        }
        previewer.showLivePreview(for: key, maxSize: model.layout.previewSize) { [weak model] key, image in
            model?.setPreview(image, for: key)
        }
    }

    private func scheduleLivePreview() {
        isLivePreviewDue = false
        livePreviewStart?.cancel()
        livePreviewStart = Task { [weak self] in
            try? await Task.sleep(for: Self.livePreviewDelay)
            guard let self, !Task.isCancelled else { return }
            self.isLivePreviewDue = true
            self.updateLivePreview()
        }
    }

    /// Cursor position relative to the wheel center (= middle of the panel), y pointing down.
    /// `mouse` is in global screen coordinates with y pointing up, hence the flip.
    private func cursorFromWheelCenter(_ mouse: NSPoint = NSEvent.mouseLocation) -> CGPoint {
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
