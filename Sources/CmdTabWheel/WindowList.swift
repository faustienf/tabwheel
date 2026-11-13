import CoreGraphics
import Foundation

/// One normal window of an app.
struct AppWindow: Equatable {
    /// Where the window is — what bringing it up involves.
    enum Place: Equatable {
        /// On screen.
        case here
        /// On a desktop that isn't shown: bringing it up switches there.
        /// "Desktop 2", "Full Screen"; nil when it can't be told which.
        case otherDesktop(String?)
        /// In the Dock: bringing it up un-minimizes it.
        case minimized

        /// For the hub; nil for a window on screen.
        var label: String? {
            switch self {
            case .here: nil
            case .otherDesktop(let name): name ?? "Another desktop"
            case .minimized: "Minimized"
            }
        }
    }

    let id: CGWindowID
    /// Needs Screen Recording permission; nil without it (and for untitled windows).
    let title: String?
    var place: Place = .here
}

/// Reads the WindowServer window list. Window IDs, owners, layers and bounds are readable
/// without Screen Recording permission (titles are not). Safe off the main thread.
enum WindowList {
    /// The windows of these apps the wheel offers. Each app's list starts with its windows on
    /// screen, front to back, then come the ones on other desktops (full-screen ones too), then
    /// minimized ones. Not here: windows of hidden apps, and the ones apps keep out of sight.
    static func windowsByApp(of apps: Set<pid_t>) -> [pid_t: [AppWindow]] {
        var result = onScreenWindowsByApp().filter { apps.contains($0.key) }
        let shown = Set(result.values.flatMap { $0.map { $0.id } })
        var places: [CGWindowID: AppWindow.Place] = [:]
        let away = Spaces.windowsAway().filter { !shown.contains($0.id) && places.updateValue($0.place, forKey: $0.id) == nil }
        for info in describe(away.map { $0.id }) {
            guard let window = NormalWindow(info), apps.contains(window.pid), let place = places[window.id] else { continue }
            result[window.pid, default: []].append(AppWindow(id: window.id, title: window.title, place: place))
        }
        return result
    }

    /// Normal windows of every app on screen, each app's list front to back.
    /// One call to WindowServer — a few milliseconds.
    static func onScreenWindowsByApp() -> [pid_t: [AppWindow]] {
        var result: [pid_t: [AppWindow]] = [:]
        // The list is ordered front to back, so each app's windows come out in z-order too.
        for info in list([.optionOnScreenOnly, .excludeDesktopElements]) {
            guard let window = NormalWindow(info) else { continue }
            result[window.pid, default: []].append(AppWindow(id: window.id, title: window.title))
        }
        return result
    }

    /// The app's front window on screen.
    static func topmostWindowID(of pid: pid_t) -> CGWindowID? {
        onScreenWindowsByApp()[pid]?.first?.id
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
        let windows = list([.optionAll, .excludeDesktopElements]).compactMap { info in
            NormalWindow(info).flatMap { $0.pid == pid ? (window: $0, isOnScreen: info[kCGWindowIsOnscreen as String] as? Bool == true) : nil }
        }
        let closing = windows.first { $0.window.id == windowID }?.window.bounds
        for (window, isOnScreen) in windows where window.id != windowID {
            if isOnScreen { return true }
            // Off screen. The other tabs of the window being closed: windows of their own, the
            // same size and place.
            if window.bounds == closing { return true }
            // On another Space it's a real window. Apps also keep hidden helper windows around,
            // off screen on no Space or on the current one — not windows the user knows of.
            // (Minimized ones are checked below.)
            guard let spaces = Spaces.of(window.id) else { return true }
            if spaces.contains(where: { !currentSpaces.contains($0) }) { return true }
        }
        return AXWindow.hasMinimizedWindow(pid: pid, besides: windowID)
    }

    private static func list(_ options: CGWindowListOption, relativeTo id: CGWindowID = kCGNullWindowID) -> [[String: Any]] {
        CGWindowListCopyWindowInfo(options, id) as? [[String: Any]] ?? []
    }

    /// The list entries of just these windows.
    private static func describe(_ ids: [CGWindowID]) -> [[String: Any]] {
        guard !ids.isEmpty else { return [] }
        // A CFArray of plain window numbers, not of objects: no retain/release callbacks.
        let values = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        let array = values.withUnsafeBufferPointer { buffer in
            CFArrayCreate(kCFAllocatorDefault, UnsafeMutablePointer(mutating: buffer.baseAddress), buffer.count, nil)
        }
        return CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]] ?? []
    }
}

/// A window in WindowServer's list that looks like a normal app window.
private struct NormalWindow {
    let pid: pid_t
    let id: CGWindowID
    let title: String?
    let bounds: CGRect

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
        self.bounds = bounds
        title = (info[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Spaces (desktops) through private SkyLight calls, looked up at runtime. nil = can't tell.
private enum Spaces {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias CopyWindowsWithOptionsAndTags = @convention(c) (
        Int32, UInt32, CFArray, UInt32, UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt64>
    ) -> Unmanaged<CFArray>?
    private typealias WindowQueryWindows = @convention(c) (Int32, CFArray, Int32) -> Unmanaged<CFTypeRef>?
    private typealias WindowQueryResultCopyWindows = @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?
    private typealias WindowIteratorAdvance = @convention(c) (CFTypeRef) -> Bool
    private typealias WindowIteratorGetTags = @convention(c) (CFTypeRef) -> UInt64
    private typealias WindowIteratorGetWindowID = @convention(c) (CFTypeRef) -> UInt32

    private static let mainConnectionID: MainConnectionID? = symbol("SLSMainConnectionID")
    private static let copyManagedDisplaySpaces: CopyManagedDisplaySpaces? = symbol("SLSCopyManagedDisplaySpaces")
    private static let copySpacesForWindows: CopySpacesForWindows? = symbol("SLSCopySpacesForWindows")
    private static let copyWindowsWithOptionsAndTags: CopyWindowsWithOptionsAndTags? = symbol("SLSCopyWindowsWithOptionsAndTags")
    private static let windowQueryWindows: WindowQueryWindows? = symbol("SLSWindowQueryWindows")
    private static let windowQueryResultCopyWindows: WindowQueryResultCopyWindows? = symbol("SLSWindowQueryResultCopyWindows")
    private static let windowIteratorAdvance: WindowIteratorAdvance? = symbol("SLSWindowIteratorAdvance")
    private static let windowIteratorGetTags: WindowIteratorGetTags? = symbol("SLSWindowIteratorGetTags")
    private static let windowIteratorGetWindowID: WindowIteratorGetWindowID? = symbol("SLSWindowIteratorGetWindowID")
    /// Spaces of every kind: user desktops, full-screen apps, system ones.
    private static let allSpaces: Int32 = 0x7
    /// Window query options: the windows a desktop shows; those plus its invisible ones.
    private static let visibleWindows: UInt32 = 0x2
    private static let invisibleWindowsToo: UInt32 = 0x7
    /// The tag WindowServer puts on minimized windows (seen on macOS 26; not documented).
    private static let minimizedTag: UInt64 = 1 << 60

    /// The Space each display shows right now.
    static func current() -> Set<Int>? {
        guard let displays = displays() else { return nil }
        let ids = displays.compactMap { ($0["Current Space"] as? [String: Any])?["id64"] as? Int }
        return ids.isEmpty ? nil : Set(ids)
    }

    /// Windows on desktops that aren't shown, and minimized windows — by WindowServer's own
    /// account of what each desktop holds, the way yabai asks it. "Off screen, on another Space"
    /// isn't enough: apps keep invisible helper windows (popups, bars) on their desktop too.
    /// Any window, not only normal app windows. Empty when it can't be told.
    static func windowsAway() -> [(id: CGWindowID, place: AppWindow.Place)] {
        guard let displays = displays() else { return [] }
        var current: Set<Int> = []
        var desktops: [(id: Int, name: String?)] = []
        for display in displays {
            if let id = (display["Current Space"] as? [String: Any])?["id64"] as? Int { current.insert(id) }
            var number = 0
            for space in display["Spaces"] as? [[String: Any]] ?? [] {
                guard let id = space["id64"] as? Int else { continue }
                // Type 0: a desktop, numbered per display like in Mission Control. 4: a full-screen app.
                switch space["type"] as? Int {
                case 0:
                    number += 1
                    desktops.append((id, "Desktop \(number)"))
                case 4:
                    desktops.append((id, "Full Screen"))
                default:
                    desktops.append((id, nil))
                }
            }
        }
        var result: [(id: CGWindowID, place: AppWindow.Place)] = []
        for desktop in desktops where !current.contains(desktop.id) {
            result += windows(on: [desktop.id], options: visibleWindows).map { ($0.id, .otherDesktop(desktop.name)) }
        }
        result += windows(on: desktops.map(\.id), options: invisibleWindowsToo)
            .filter { $0.tags & minimizedTag != 0 }
            .map { ($0.id, .minimized) }
        return result
    }

    private static func windows(on spaces: [Int], options: UInt32) -> [(id: CGWindowID, tags: UInt64)] {
        guard let mainConnectionID, let copyWindowsWithOptionsAndTags, let windowQueryWindows,
              let windowQueryResultCopyWindows, let windowIteratorAdvance, let windowIteratorGetTags,
              let windowIteratorGetWindowID, !spaces.isEmpty
        else { return [] }
        let connection = mainConnectionID()
        var setTags: UInt64 = 1
        var clearTags: UInt64 = 0
        guard let ids = copyWindowsWithOptionsAndTags(
                  connection, 0, spaces.map { NSNumber(value: $0) } as CFArray, options, &setTags, &clearTags
              )?.takeRetainedValue(),
              CFArrayGetCount(ids) > 0,
              let query = windowQueryWindows(connection, ids, Int32(CFArrayGetCount(ids)))?.takeRetainedValue(),
              let iterator = windowQueryResultCopyWindows(query)?.takeRetainedValue()
        else { return [] }
        var result: [(id: CGWindowID, tags: UInt64)] = []
        while windowIteratorAdvance(iterator) {
            result.append((windowIteratorGetWindowID(iterator), windowIteratorGetTags(iterator)))
        }
        return result
    }

    private static func displays() -> [[String: Any]]? {
        guard let mainConnectionID, let copyManagedDisplaySpaces else { return nil }
        return copyManagedDisplaySpaces(mainConnectionID())?.takeRetainedValue() as? [[String: Any]]
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
