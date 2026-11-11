import AppKit

/// Apps in the order they were last active, most recent first — so a quick ⌘Tab can go
/// back to the previous app, like the system switcher does.
@MainActor
final class AppHistory {
    private var pids: [pid_t]
    private var observers: [NSObjectProtocol] = []

    init() {
        pids = Self.seedFromWindowOrder()

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let pid = Self.pid(from: note) else { return }
            MainActor.assumeIsolated { self?.moveToFront(pid) }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let pid = Self.pid(from: note) else { return }
            MainActor.assumeIsolated { self?.pids.removeAll { $0 == pid } }
        })
    }

    /// The app used right before the current front one.
    var previous: pid_t? {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return pids.first { pid in
            pid != front && NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular
        }
    }

    private func moveToFront(_ pid: pid_t) {
        pids.removeAll { $0 == pid }
        pids.insert(pid, at: 0)
    }

    private nonisolated static func pid(from note: Notification) -> pid_t? {
        (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
    }

    /// There's no API for "recently used" order, but at launch the window stacking order is a
    /// good guess: apps you used last have their windows on top.
    private static func seedFromWindowOrder() -> [pid_t] {
        var result: [pid_t] = []
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            result.append(front)
        }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        for info in windows where info[kCGWindowLayer as String] as? Int == 0 {
            if let pid = info[kCGWindowOwnerPID as String] as? pid_t, !result.contains(pid) {
                result.append(pid)
            }
        }
        return result
    }
}
