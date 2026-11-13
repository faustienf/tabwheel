import ApplicationServices

/// Another app's window, found through Accessibility by its WindowServer ID.
///
/// Not tied to the main actor, and meant to be called off it: Accessibility calls go to the
/// target app and block while it's busy. The main thread also runs our keyboard tap, and a
/// stall there freezes typing.
enum AXWindow {
    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    /// Private: maps an Accessibility window element to its WindowServer window ID.
    private static let getWindow: GetWindow? = {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let pointer = dlsym(rtldDefault, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(pointer, to: GetWindow.self)
    }()

    /// Only windows on a shown desktop (and minimized ones): Accessibility doesn't list the
    /// others. `expected: false` when not finding it is no error.
    static func find(pid: pid_t, windowID: CGWindowID, expected: Bool = true) -> AXUIElement? {
        guard let windows = windows(of: pid) else { return nil }
        let window = windows.first { id(of: $0) == windowID }
        if window == nil, expected {
            log.error("AX: window \(windowID, privacy: .public) not found in pid \(pid, privacy: .public)")
        }
        return window
    }

    /// Takes the window out of the Dock if it's minimized. True when it was.
    static func unminimize(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value) == .success,
              value as? Bool == true
        else { return false }
        let result = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        if result != .success {
            log.error("AX: un-minimizing failed with \(result.rawValue, privacy: .public)")
        }
        return true
    }

    /// The app still has this window — open, minimized or behind a question — as opposed to
    /// having closed it. Can't tell → true.
    static func exists(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard getWindow != nil, let windows = windows(of: pid) else { return true }
        return windows.contains { id(of: $0) == windowID }
    }

    /// Waits until the app has closed the window: off screen and gone from its window list
    /// (a minimized window is off screen too, but still there). False on timeout.
    static func waitUntilClosed(pid: pid_t, windowID: CGWindowID, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if kill(pid, 0) != 0 { return true } // the app is gone altogether
            if !WindowList.isOnScreen(windowID), !exists(pid: pid, windowID: windowID) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// A minimized window of the app other than `windowID`. Can't tell → true.
    static func hasMinimizedWindow(pid: pid_t, besides windowID: CGWindowID) -> Bool {
        guard getWindow != nil, let windows = windows(of: pid) else { return true }
        return windows.contains { window in
            guard id(of: window) != windowID else { return false }
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value) == .success
                && (value as? Bool) == true
        }
    }

    private static func windows(of pid: pid_t) -> [AXUIElement]? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5) // a hung app must not hang us for the default 6 s
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
            let windows = value as? [AXUIElement]
        else {
            log.error("AX: can't list windows of pid \(pid, privacy: .public)")
            return nil
        }
        return windows
    }

    private static func id(of window: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        guard let getWindow, getWindow(window, &id) == .success else { return nil }
        return id
    }

    /// Clicks the window's close button. It's the app that closes it, so an unsaved document
    /// still gets its "Save changes?" sheet.
    @discardableResult
    static func close(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard let window = find(pid: pid, windowID: windowID) else { return false }
        log.notice("AX: closing \(describe(window, withTitle: false), privacy: .public)")
        guard let button = element(window, kAXCloseButtonAttribute) else {
            log.error("AX: window \(windowID, privacy: .public) has no close button")
            return false
        }
        log.notice("AX: its close button: \(describe(button), privacy: .public)")
        let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
        if result != .success {
            log.error("AX: close failed with \(result.rawValue, privacy: .public)")
        }
        return result == .success
    }

    /// For apps that ignore a pressed close button (no click seen, nothing happens): make the
    /// window the app's main one and choose the app's own Close command — the ⌘W item of its
    /// menus, as if picked in the menu bar.
    static func closeViaMenu(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard let window = find(pid: pid, windowID: windowID) else { return false }
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        guard let item = closeMenuItem(of: pid) else {
            log.error("AX: no ⌘W menu item in pid \(pid, privacy: .public)")
            return false
        }
        log.notice("AX: choosing \(describe(item), privacy: .public)")
        let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
        if result != .success {
            log.error("AX: menu close failed with \(result.rawValue, privacy: .public)")
        }
        return result == .success
    }

    /// The enabled menu item with the plain ⌘W shortcut (not ⌥⌘W "Close All" and the like).
    private static func closeMenuItem(of pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let bar = element(app, kAXMenuBarAttribute) else { return nil }
        for menuBarItem in children(of: bar) {
            for menu in children(of: menuBarItem) {
                for item in children(of: menu) {
                    var char: CFTypeRef?, modifiers: CFTypeRef?, enabled: CFTypeRef?
                    AXUIElementCopyAttributeValue(item, kAXMenuItemCmdCharAttribute as CFString, &char)
                    AXUIElementCopyAttributeValue(item, kAXMenuItemCmdModifiersAttribute as CFString, &modifiers)
                    AXUIElementCopyAttributeValue(item, kAXEnabledAttribute as CFString, &enabled)
                    // Modifiers 0 = ⌘ alone.
                    if (char as? String)?.uppercased() == "W", (modifiers as? Int) == 0, (enabled as? Bool) != false {
                        return item
                    }
                }
            }
        }
        return nil
    }

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        return value as? [AXUIElement] ?? []
    }

    /// Role, subrole, title, enabled — for the log, when an app doesn't react as expected.
    /// `withTitle: false` for windows: their titles are the user's business (mail subjects,
    /// document names), and users get asked to send their logs.
    private static func describe(_ element: AXUIElement, withTitle: Bool = true) -> String {
        func string(_ attribute: String) -> String {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            return value.map { "\($0)" } ?? "-"
        }
        let title = withTitle ? " \"\(string(kAXTitleAttribute))\"" : ""
        return "\(string(kAXRoleAttribute))/\(string(kAXSubroleAttribute))\(title) enabled=\(string(kAXEnabledAttribute))"
    }
}
