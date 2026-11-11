import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let wheel = WheelController()
    private let interceptor = CommandTabInterceptor()
    private let appearanceSettings = AppearanceSettings()
    private let windowModeSettings = WindowModeSettings()
    private let setup = SetupWindowController()
    private var statusItem: NSStatusItem?
    private var permissionTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []

    /// Menu bar switch: on = the wheel takes over ⌘Tab, off = the system switcher works as usual.
    /// Remembered between launches.
    private var isWheelEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "wheelEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "wheelEnabled") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        appearanceSettings.apply()
        // First of all: a copy that's about to move to /Applications and relaunch shouldn't
        // grab ⌘Tab or open setup.
        if AppMover.moveIfNeeded() { return }
        setUpStatusItem()
        terminateCleanlyOnSignals()
        BackgroundCursor.enable() // so the wheel can show a plain arrow over other apps

        interceptor.onInput = { [weak self] input in self?.wheel.handle(input) }
        wheel.onClosedByClick = { [weak self] in self?.interceptor.endSession() }
        if isWheelEnabled {
            startInterceptorWhenTrusted()
        }
        // Permissions are asked for in the setup window, not with system prompts out of nowhere.
        if !SetupWindowController.isCompleted || !Permissions.hasAccessibility {
            setup.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Give the user their system ⌘Tab back.
        interceptor.stop()
    }

    // MARK: - On / off

    private func setWheelEnabled(_ enabled: Bool) {
        isWheelEnabled = enabled
        statusItem?.button?.appearsDisabled = !enabled
        if enabled {
            startInterceptorWhenTrusted()
            if !Permissions.hasAccessibility { setup.show() }
        } else {
            permissionTimer?.invalidate()
            permissionTimer = nil
            interceptor.stop() // removes our tap and turns the system ⌘Tab back on
            log.notice("wheel turned off")
        }
    }

    // MARK: - Accessibility

    private func startInterceptorWhenTrusted() {
        guard permissionTimer == nil else { return } // already waiting
        // No prompt here: the setup window explains and asks for the permission.
        if AXIsProcessTrusted(), interceptor.start() { return }

        log.notice("waiting for Accessibility permission")
        // No callback exists for "permission granted", so poll.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AXIsProcessTrusted(), self.interceptor.start() else { return }
                self.permissionTimer?.invalidate()
                self.permissionTimer = nil
            }
        }
    }

    // MARK: - Menu bar

    /// LSUIElement apps have no Dock icon and no menu bar — this icon is the only way to quit.
    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "circle.circle", accessibilityDescription: "⌘Tab Wheel")
        item.button?.appearsDisabled = !isWheelEnabled // dimmed icon = wheel is off

        let menu = NSMenu()
        let switchItem = NSMenuItem()
        switchItem.view = SwitchMenuItemView(title: "⌘Tab Wheel", isOn: isWheelEnabled) { [weak self] isOn in
            self?.setWheelEnabled(isOn)
        }
        menu.addItem(switchItem)
        menu.addItem(.separator())
        let appearanceItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        appearanceItem.submenu = appearanceSettings.makeMenu()
        menu.addItem(appearanceItem)
        let windowsItem = NSMenuItem(title: "Windows", action: nil, keyEquivalent: "")
        windowsItem.submenu = windowModeSettings.makeMenu()
        menu.addItem(windowsItem)
        menu.addItem(.separator())
        let setupItem = NSMenuItem(title: "Setup…", action: #selector(showSetup), keyEquivalent: "")
        setupItem.target = self
        menu.addItem(setupItem)
        menu.addItem(
            withTitle: "Quit ⌘Tab Wheel",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        item.menu = menu
        statusItem = item
    }

    @objc private func showSetup() {
        setup.show()
    }

    /// Ctrl+C / `pkill` should also go through applicationWillTerminate,
    /// otherwise the system ⌘Tab would stay disabled.
    private func terminateCleanlyOnSignals() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated { NSApp.terminate(nil) }
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
