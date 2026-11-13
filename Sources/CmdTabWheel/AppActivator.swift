import AppKit
import ApplicationServices

/// Brings another app to the front.
///
/// Why not just `NSRunningApplication.activate()`: since macOS 14 activation is "cooperative" —
/// the system may ignore the request when the caller isn't the active app, and our agent never is.
/// So:
/// 1. A window to bring up (on screen, on another desktop or minimized) → focus and raise it the
///    way AltTab and yabai do: private SkyLight calls make the app frontmost and the window key,
///    which also switches to its desktop; Accessibility un-minimizes and raises it.
/// 2. No window (the app is hidden, or has none) or step 1 didn't take →
///    open the app through LaunchServices, exactly like clicking its Dock icon.
@MainActor
enum AppActivator {
    /// `windowID`: the window to bring up; nil = the app's front window.
    /// `opensWindowIfNone`: for an app with no window here, do what a Dock click does (which
    /// opens a new window if it has none at all). Off when only handing focus back: an app the
    /// user just closed the windows of must not get a fresh one.
    static func activate(pid: pid_t, windowID requestedWindowID: CGWindowID? = nil, opensWindowIfNone: Bool = true) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        let name = app.localizedName ?? "pid \(pid)"

        guard let windowID = requestedWindowID ?? WindowList.topmostWindowID(of: pid) else {
            guard opensWindowIfNone else {
                log.notice("activating \(name, privacy: .public), no window to bring up")
                app.activate()
                return
            }
            log.notice("activating \(name, privacy: .public) via LaunchServices")
            openViaLaunchServices(app)
            return
        }

        Task {
            // Accessibility calls go to the target app and block while it's busy. Keep them off
            // the main thread — it also runs our keyboard tap, and a stall there freezes typing.
            let focused = await Task.detached(priority: .userInitiated) {
                await WindowFocus.focusAndRaise(pid: pid, windowID: windowID)
            }.value

            // Check that it actually worked; if not, fall back to the Dock-click way.
            if focused { try? await Task.sleep(for: .milliseconds(250)) }
            if focused, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                log.notice("activated \(name, privacy: .public) via SkyLight + AXRaise")
            } else {
                log.notice("SkyLight didn't activate \(name, privacy: .public) → LaunchServices")
                openViaLaunchServices(app)
            }
        }
    }

    /// Same as clicking the Dock icon: switches Space, unhides, un-minimizes or
    /// opens a new window if the app has none.
    private static func openViaLaunchServices(_ app: NSRunningApplication) {
        guard let url = app.bundleURL else {
            app.activate(options: [.activateAllWindows])
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                log.error("LaunchServices open failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// Window focusing through private SkyLight (WindowServer) calls plus Accessibility,
/// looked up at runtime. Signatures and the magic event record come from yabai / AltTab.
/// Not tied to the main actor: safe to call from a background thread.
private enum WindowFocus {
    private typealias GetProcessForPID =
        @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    private typealias SetFrontProcessWithOptions =
        @convention(c) (UnsafePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError.RawValue
    private typealias PostEventRecordTo =
        @convention(c) (UnsafePointer<ProcessSerialNumber>, UnsafePointer<UInt8>) -> CGError.RawValue

    // GetProcessForPID is public but deprecated — looked up dynamically to avoid the warning.
    private static let getProcessForPID: GetProcessForPID? = symbol("GetProcessForPID")
    private static let setFrontProcessWithOptions: SetFrontProcessWithOptions? = symbol("_SLPSSetFrontProcessWithOptions")
    private static let postEventRecordTo: PostEventRecordTo? = symbol("SLPSPostEventRecordTo")

    /// kCPSUserGenerated: treat it as if the user clicked the window.
    private static let userGenerated: UInt32 = 0x200

    static func focusAndRaise(pid: pid_t, windowID: CGWindowID) async -> Bool {
        guard let getProcessForPID, let setFrontProcessWithOptions, let postEventRecordTo else {
            log.error("SkyLight symbols not found")
            return false
        }
        var psn = ProcessSerialNumber()
        guard getProcessForPID(pid, &psn) == noErr else { return false }

        // A minimized window comes out of the Dock first. One on another desktop isn't known
        // to Accessibility yet: it's raised below, once that desktop is shown.
        let window = AXWindow.find(pid: pid, windowID: windowID, expected: false)
        if let window, AXWindow.unminimize(window) {
            log.notice("un-minimized the window")
        }

        // 1. Make the app frontmost — this alone does NOT bring its window above other apps' windows.
        guard setFrontProcessWithOptions(&psn, windowID, userGenerated) == CGError.success.rawValue else {
            return false
        }

        // 2. Make the window key (focused for keyboard).
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: windowID.littleEndian) { bytes.replaceSubrange(0x3c..<0x40, with: $0) }
        for index in 0x20..<0x30 { bytes[index] = 0xff }
        bytes[0x08] = 0x01
        _ = postEventRecordTo(&psn, bytes)
        bytes[0x08] = 0x02
        _ = postEventRecordTo(&psn, bytes)

        // 3. Physically raise the window to the top.
        if let window {
            raise(window)
        } else {
            await raiseOnceShown(pid: pid, windowID: windowID)
        }
        return true
    }

    /// A window on another desktop: macOS is switching there now, and once it's done,
    /// Accessibility sees the window.
    private static func raiseOnceShown(pid: pid_t, windowID: CGWindowID) async {
        log.notice("the window is on another desktop: switching there")
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(100))
            if let window = AXWindow.find(pid: pid, windowID: windowID, expected: false) {
                raise(window)
                return
            }
        }
        log.error("AX: window \(windowID, privacy: .public) didn't show up to raise")
    }

    private static func raise(_ window: AXUIElement) {
        let result = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        if result != .success {
            log.error("AX: raise failed with \(result.rawValue, privacy: .public)")
        }
    }

    private static func symbol<T>(_ name: String) -> T? {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let pointer = dlsym(rtldDefault, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }
}
