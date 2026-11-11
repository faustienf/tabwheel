import CoreGraphics
import Foundation

/// One normal window of an app.
struct AppWindow: Equatable {
    let id: CGWindowID
    /// Needs Screen Recording permission; nil without it (and for untitled windows).
    let title: String?
}

/// Reads the WindowServer window list. Window IDs, owners, layers and bounds are readable
/// without Screen Recording permission (titles are not).
enum WindowList {
    /// Normal windows of every app on the current Space(s), each app's list front to back.
    /// Hidden and minimized windows and windows on other Spaces aren't on screen, so they're
    /// not here. One call to WindowServer — a few milliseconds.
    static func windowsByApp() -> [pid_t: [AppWindow]] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }
        var result: [pid_t: [AppWindow]] = [:]
        // The list is ordered front to back, so each app's windows come out in z-order too.
        for info in windows {
            guard
                let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                info[kCGWindowLayer as String] as? Int == 0, // normal windows, not menus/panels
                (info[kCGWindowAlpha as String] as? Double ?? 0) > 0,
                let id = info[kCGWindowNumber as String] as? CGWindowID,
                let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDict),
                bounds.width > 40, bounds.height > 40 // skip invisible helper windows
            else { continue }
            let title = (info[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
            result[pid, default: []].append(AppWindow(id: id, title: title))
        }
        return result
    }

    static func topmostWindowID(of pid: pid_t) -> CGWindowID? {
        windowsByApp()[pid]?.first?.id
    }
}
