import CoreGraphics
import Foundation

/// One normal window of an app.
struct AppWindow: Equatable {
    let id: CGWindowID
    /// Needs Screen Recording permission; nil without it (and for untitled windows).
    let title: String?
}

/// Reads the WindowServer window list. Window IDs, owners, layers and bounds are readable
/// without Screen Recording permission (titles are not). Safe off the main thread.
enum WindowList {
    /// Normal windows of every app on the current Space(s), each app's list front to back.
    /// Hidden and minimized windows and windows on other Spaces aren't on screen, so they're
    /// not here. One call to WindowServer — a few milliseconds.
    static func windowsByApp() -> [pid_t: [AppWindow]] {
        var result: [pid_t: [AppWindow]] = [:]
        // The list is ordered front to back, so each app's windows come out in z-order too.
        for info in list([.optionOnScreenOnly, .excludeDesktopElements]) {
            guard let window = NormalWindow(info) else { continue }
            result[window.pid, default: []].append(AppWindow(id: window.id, title: window.title))
        }
        return result
    }

    static func topmostWindowID(of pid: pid_t) -> CGWindowID? {
        windowsByApp()[pid]?.first?.id
    }

    /// Every window of the app on screen, of any kind: alerts and sheets too.
    static func onScreenWindowIDs(of pid: pid_t) -> Set<CGWindowID> {
        Set(list([.optionOnScreenOnly]).compactMap { info in
            info[kCGWindowOwnerPID as String] as? pid_t == pid ? info[kCGWindowNumber as String] as? CGWindowID : nil
        })
    }

    static func isOnScreen(_ id: CGWindowID) -> Bool {
        list(.optionIncludingWindow, relativeTo: id).first?[kCGWindowIsOnscreen as String] as? Bool ?? false
    }

    /// Whether the app has a window besides `windowID` anywhere: on screen, on another Space
    /// (full screen too), or minimized. It decides whether closing `windowID` may quit the
    /// whole app, so whenever something can't be checked the answer is yes.
    static func hasOtherWindows(of pid: pid_t, besides windowID: CGWindowID) -> Bool {
        guard let currentSpaces = Spaces.current() else { return true }
        for info in list([.optionAll, .excludeDesktopElements]) {
            guard let window = NormalWindow(info), window.pid == pid, window.id != windowID else { continue }
            if info[kCGWindowIsOnscreen as String] as? Bool == true { return true }
            // Off screen. On another Space it's a real window. Apps also keep hidden helper
            // windows around, off screen on no Space or on the current one — not windows the
            // user knows of. (Minimized ones are checked below.)
            guard let spaces = Spaces.of(window.id) else { return true }
            if spaces.contains(where: { !currentSpaces.contains($0) }) { return true }
        }
        return AXWindow.hasMinimizedWindow(pid: pid, besides: windowID)
    }

    private static func list(_ options: CGWindowListOption, relativeTo id: CGWindowID = kCGNullWindowID) -> [[String: Any]] {
        CGWindowListCopyWindowInfo(options, id) as? [[String: Any]] ?? []
    }
}

/// A window in WindowServer's list that looks like a normal app window.
private struct NormalWindow {
    let pid: pid_t
    let id: CGWindowID
    let title: String?

    init?(_ info: [String: Any]) {
        guard
            let pid = info[kCGWindowOwnerPID as String] as? pid_t,
            info[kCGWindowLayer as String] as? Int == 0, // normal windows, not menus/panels
            (info[kCGWindowAlpha as String] as? Double ?? 0) > 0,
            let id = info[kCGWindowNumber as String] as? CGWindowID,
            let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
            let bounds = CGRect(dictionaryRepresentation: boundsDict),
            bounds.width > 40, bounds.height > 40 // skip invisible helper windows
        else { return nil }
        self.pid = pid
        self.id = id
        title = (info[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Spaces (desktops) through private SkyLight calls, looked up at runtime. nil = can't tell.
private enum Spaces {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    private static let mainConnectionID: MainConnectionID? = symbol("SLSMainConnectionID")
    private static let copyManagedDisplaySpaces: CopyManagedDisplaySpaces? = symbol("SLSCopyManagedDisplaySpaces")
    private static let copySpacesForWindows: CopySpacesForWindows? = symbol("SLSCopySpacesForWindows")
    /// Spaces of every kind: user desktops, full-screen apps, system ones.
    private static let allSpaces: Int32 = 0x7

    /// The Space each display shows right now.
    static func current() -> Set<Int>? {
        guard let mainConnectionID, let copyManagedDisplaySpaces,
              let displays = copyManagedDisplaySpaces(mainConnectionID())?.takeRetainedValue() as? [[String: Any]]
        else { return nil }
        let ids = displays.compactMap { ($0["Current Space"] as? [String: Any])?["id64"] as? Int }
        return ids.isEmpty ? nil : Set(ids)
    }

    static func of(_ window: CGWindowID) -> [Int]? {
        guard let mainConnectionID, let copySpacesForWindows,
              let spaces = copySpacesForWindows(mainConnectionID(), allSpaces, [NSNumber(value: window)] as CFArray)?
                  .takeRetainedValue() as? [NSNumber]
        else { return nil }
        return spaces.map(\.intValue)
    }

    private static func symbol<T>(_ name: String) -> T? {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let pointer = dlsym(rtldDefault, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }
}
