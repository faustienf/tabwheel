import AppKit
import ApplicationServices

/// Brings another app to the front.
///
/// Why not just `NSRunningApplication.activate()`: since macOS 14 activation is "cooperative" —
/// the system may ignore the request when the caller isn't the active app, and our agent never is.
/// So:
/// 1. App has a window on the current Space → focus and raise it the way AltTab and yabai do:
///    private SkyLight calls make the app frontmost and the window key, Accessibility raises it.
/// 2. No visible window (hidden, minimized, on another Space) or step 1 didn't take →
///    open the app through LaunchServices, exactly like clicking its Dock icon.
@MainActor
enum AppActivator {
    /// `windowID`: the window to bring up; nil = the app's front window.
    static func activate(pid: pid_t, windowID requestedWindowID: CGWindowID? = nil) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        let name = app.localizedName ?? "pid \(pid)"

        guard let windowID = requestedWindowID ?? WindowList.topmostWindowID(of: pid) else {
            log.notice("activating \(name, privacy: .public) via LaunchServices")
            openViaLaunchServices(app)
            return
        }

        Task {
            // Accessibility calls go to the target app and block while it's busy. Keep them off
            // the main thread — it also runs our keyboard tap, and a stall there freezes typing.
            let focused = await Task.detached(priority: .userInitiated) {
                WindowFocus.focusAndRaise(pid: pid, windowID: windowID)
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
    private typealias AXUIElementGetWindow =
        @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    // GetProcessForPID is public but deprecated — looked up dynamically to avoid the warning.
    private static let getProcessForPID: GetProcessForPID? = symbol("GetProcessForPID")
    private static let setFrontProcessWithOptions: SetFrontProcessWithOptions? = symbol("_SLPSSetFrontProcessWithOptions")
    private static let postEventRecordTo: PostEventRecordTo? = symbol("SLPSPostEventRecordTo")
    /// Maps an Accessibility window element to its WindowServer window ID.
    private static let axUIElementGetWindow: AXUIElementGetWindow? = symbol("_AXUIElementGetWindow")

    /// kCPSUserGenerated: treat it as if the user clicked the window.
    private static let userGenerated: UInt32 = 0x200

    static func focusAndRaise(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard let getProcessForPID, let setFrontProcessWithOptions, let postEventRecordTo else {
            log.error("SkyLight symbols not found")
            return false
        }
        var psn = ProcessSerialNumber()
        guard getProcessForPID(pid, &psn) == noErr else { return false }

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
        raise(pid: pid, windowID: windowID)
        return true
    }

    private static func raise(pid: pid_t, windowID: CGWindowID) {
        guard let axUIElementGetWindow else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5) // a hung app must not hang us for the default 6 s

        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
            let windows = value as? [AXUIElement]
        else {
            log.error("AX: can't list windows of pid \(pid, privacy: .public)")
            return
        }
        for window in windows {
            var id: CGWindowID = 0
            guard axUIElementGetWindow(window, &id) == .success, id == windowID else { continue }
            let result = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            if result != .success {
                log.error("AX: raise failed with \(result.rawValue, privacy: .public)")
            }
            return
        }
        log.error("AX: window \(windowID, privacy: .public) not found in pid \(pid, privacy: .public)")
    }

    private static func symbol<T>(_ name: String) -> T? {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let pointer = dlsym(rtldDefault, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }
}
