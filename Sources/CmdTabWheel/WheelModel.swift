import AppKit
import Observation

/// One sector of the wheel: a running app — or one of its windows, when it has several.
struct WheelItem: Identifiable {
    struct ID: Hashable {
        let pid: pid_t
        let window: CGWindowID?
    }

    let pid: pid_t
    let name: String
    let icon: NSImage
    let app: NSRunningApplication
    /// The window this sector stands for. nil = the app as a whole (one window or none).
    var window: AppWindow?
    /// "2" on the icon of the app's second window; nil for one-window apps.
    var windowNumber: Int?

    var id: ID { ID(pid: pid, window: window?.id) }
}

/// Wheel state: which apps are on it and which one is selected.
/// `@Observable` makes SwiftUI re-render whatever reads these properties (like a store).
///
/// Mouse selection: a virtual segment goes from the wheel center to the cursor; the sector it
/// crosses is selected. Only the direction matters, so the cursor can be anywhere on screen.
/// Cursor inside the hub crosses nothing → no selection.
/// Points are relative to the wheel center, y pointing down (SwiftUI-style).
@MainActor
@Observable
final class WheelModel {
    /// How far the cursor has to move before the mouse takes over the selection.
    static let pointerActivationDistance: CGFloat = 2

    let layout: WheelLayout
    private(set) var items: [WheelItem] = []
    private(set) var selectedIndex: Int?
    /// Visual feedback only: grows beyond the rim; keyboard uses the midpoint.
    private(set) var selectionReach: CGFloat = 0.5
    /// Window screenshots, shown in the hub. Kept between openings so the next ⌘Tab
    /// shows them instantly; refreshed in the background every time the wheel opens.
    private(set) var previews: [PreviewKey: NSImage] = [:]
    /// Each app's windows on the current Space, front to back — taken when the wheel opens.
    private(set) var windows: [pid_t: [AppWindow]] = [:]
    /// The pointer is on the close action in the selected sector’s outer rail.
    private(set) var isCloseButtonHovered = false

    var selectedItem: WheelItem? { selectedIndex.map { items[$0] } }

    /// Mouse over a sector or its action rail — the cursor shows a pointing hand.
    var isPointingAtSector: Bool { isCloseButtonHovered || (isPointerActive && selectedIndex != nil) }

    /// The previously used app. A quick ⌘Tab — released without touching anything — goes there.
    private(set) var quickSwitchPID: pid_t?
    /// The user did something this time: moved the mouse past the threshold or pressed Tab.
    /// After that, releasing ⌘ with nothing selected means "cancel", not "quick switch".
    private(set) var wasTouched = false
    /// A window was closed or an app quit from the wheel, and the user hasn't picked a sector
    /// since. Releasing ⌘ then goes back to where the user was: the selection only stayed
    /// on that app so ⌘W can go on closing its windows, it isn't a choice to switch there.
    /// (Switching to an app whose windows were just closed would even reopen one.)
    @ObservationIgnored private(set) var hasClosedSomething = false

    var quickSwitchItem: WheelItem? {
        guard !wasTouched, let quickSwitchPID else { return nil }
        // An app with several windows: the sector of the window it was left on, its front one.
        let front = windows[quickSwitchPID]?.first?.id
        return items.first { $0.pid == quickSwitchPID && ($0.window == nil || $0.window?.id == front) }
    }

    // Pointer bookkeeping isn't drawn, so it's not observed (no re-render per mouse move).
    /// Where the cursor was when the wheel opened or Tab was last pressed.
    @ObservationIgnored private var pointerAnchor: CGPoint = .zero
    @ObservationIgnored private var lastPointer: CGPoint = .zero
    /// The cursor moved far enough from the anchor — the mouse drives the selection.
    @ObservationIgnored private var isPointerActive = false

    init(layout: WheelLayout) {
        self.layout = layout
    }

    /// Regular apps (the ones with a Dock icon), in launch order — stable slots for muscle memory.
    /// Sorted explicitly: Apple documents the order of `runningApplications` as unspecified.
    func reload(pointer: CGPoint, quickSwitchTo quickSwitchPID: pid_t?) {
        self.quickSwitchPID = quickSwitchPID
        wasTouched = false
        hasClosedSomething = false
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { (app: $0, started: $0.startDate) } // look the date up once, not per comparison
            .sorted { ($0.started, $0.app.processIdentifier) < ($1.started, $1.app.processIdentifier) }
            .map(\.app)
        let running = Set(apps.map(\.processIdentifier))
        windows = WindowList.windowsByApp().filter { running.contains($0.key) }
        items = sectors(for: apps.map { app in
            WheelItem(
                pid: app.processIdentifier,
                name: app.localizedName ?? app.bundleIdentifier ?? "?",
                icon: app.icon ?? NSImage(),
                app: app
            )
        })
        select(nil)
        // Drop screenshots of windows that are gone and apps that have quit.
        let windowIDs = Set(windows.values.flatMap { $0.map(\.id) })
        previews = previews.filter { key, _ in
            switch key {
            case .window(let id): windowIDs.contains(id)
            case .app(let pid): running.contains(pid)
            }
        }
        anchorPointer(at: pointer)
        updateHover(at: pointer)
    }

    /// One sector per app — or one per window of an app that has several.
    private func sectors(for apps: [WheelItem]) -> [WheelItem] {
        apps.flatMap { item in
            let appWindows = windows[item.pid] ?? []
            guard appWindows.count > 1 else { return [item] }
            // Creation order (window IDs only grow), not front to back: that changes with every
            // switch, and the sectors would swap places under the cursor.
            return appWindows.sorted { $0.id < $1.id }.enumerated().map { number, window in
                var sector = item
                sector.window = window
                sector.windowNumber = number + 1
                return sector
            }
        }
    }

    /// A window was closed from the wheel: take it off right away instead of waiting for the app.
    /// (If the app keeps it open after all, say to ask about unsaved changes, it's back next time.)
    func removeWindow(_ id: CGWindowID, of pid: pid_t) {
        windows[pid]?.removeAll { $0.id == id }
        previews[.window(id)] = nil
        touch() // releasing ⌘ now must not count as a quick ⌘Tab
        hasClosedSomething = true
        rebuildSectors()
    }

    /// ⌘Q was sent. The sectors go only once the app has quit (`removeApp`).
    func noteQuitRequested() {
        touch()
        hasClosedSomething = true
    }

    /// An app quit while the wheel is open (⌘Q here, or on its own): its sectors go.
    func removeApp(_ pid: pid_t) {
        guard items.contains(where: { $0.pid == pid }) else { return }
        let gone = Set((windows[pid] ?? []).map(\.id))
        windows[pid] = nil
        previews = previews.filter { key, _ in
            switch key {
            case .window(let id): !gone.contains(id)
            case .app(let app): app != pid
            }
        }
        rebuildSectors(dropping: pid)
    }

    /// Sectors again after a window or an app went away. Indices shift with them, so the
    /// selection is placed anew: under the pointer when the mouse drives it; else on the same
    /// app (Tab to it, then ⌘W ⌘W ⌘W closes its windows one by one); else on whatever slid
    /// into its place.
    private func rebuildSectors(dropping droppedPID: pid_t? = nil) {
        let previous = selectedIndex.map { (index: $0, pid: items[$0].pid) }
        // Re-placing the selection below is our doing, not a pick by the user.
        let closedSomething = hasClosedSomething
        defer { hasClosedSomething = closedSomething }
        var seen = Set<pid_t>()
        let apps = items.compactMap { item -> WheelItem? in
            guard item.pid != droppedPID, seen.insert(item.pid).inserted else { return nil }
            var app = item
            app.window = nil
            app.windowNumber = nil
            return app
        }
        select(nil) // before `items` changes: the old index may not exist any more
        items = sectors(for: apps)

        if isPointerActive {
            movePointer(to: lastPointer)
            return
        }
        updateHover(at: lastPointer)
        guard let previous, !items.isEmpty else { return }
        if previous.index < items.count, items[previous.index].pid == previous.pid {
            select(previous.index)
        } else if let sameApp = items.firstIndex(where: { $0.pid == previous.pid }) {
            select(sameApp)
        } else {
            select(min(previous.index, items.count - 1))
        }
    }

    /// nil removes the preview (nothing to show any more).
    func setPreview(_ image: CGImage?, for key: PreviewKey) {
        previews[key] = image.map { NSImage(cgImage: $0, size: .zero) }
    }

    /// The window switching to `item` brings up; nil when it has none on this Space.
    func chosenWindow(of item: WheelItem) -> AppWindow? {
        item.window ?? windows[item.pid]?.first
    }

    /// "Window 2 of 3" for the hub — only for apps with more than one window.
    func windowPosition(of item: WheelItem) -> (index: Int, count: Int)? {
        guard let number = item.windowNumber, let count = windows[item.pid]?.count, count > 1 else { return nil }
        return (number - 1, count)
    }

    /// Picture for the hub: the chosen window, or a stand-in for an app with none on this Space.
    func preview(for item: WheelItem) -> NSImage? {
        if let window = chosenWindow(of: item) {
            return previews[.window(window.id)]
        }
        return previews[.app(item.pid)]
    }

    func movePointer(to point: CGPoint) {
        lastPointer = point
        guard !items.isEmpty else {
            if isCloseButtonHovered { isCloseButtonHovered = false }
            return
        }
        updateHover(at: point)

        if !isPointerActive {
            let moved = hypot(point.x - pointerAnchor.x, point.y - pointerAnchor.y)
            guard moved >= Self.pointerActivationDistance else { return }
            isPointerActive = true
            touch()
        }

        // The segment center→cursor only reaches the sectors once it's longer than the hub.
        // Inside the hub nothing is crossed → nothing is selected, so releasing ⌘ there cancels.
        let distance = hypot(point.x, point.y)
        updateSelectionReach(distance: distance)
        // Keep the visible rail attached to its owner while aiming at its actions,
        // including the short path from the icon. This matters with tightly packed sectors.
        if let index = selectedIndex, chosenWindow(of: items[index]) != nil,
           layout.actionRailContains(point, index: index, count: items.count) {
            return
        }
        guard distance >= layout.innerRadius else {
            select(nil)
            updateHover(at: point)
            return
        }
        let angle = atan2(point.y, point.x)
        let index = WheelGeometry.index(at: angle, count: items.count)
        if index != selectedIndex { hasClosedSomething = false } // picked another sector
        select(index)
        updateHover(at: point)
    }

    /// The app whose sector the segment center→`point` crosses; nil inside the hub.
    /// Used for clicks — no movement threshold, the cursor may already sit on an icon.
    func item(at point: CGPoint) -> WheelItem? {
        let distance = hypot(point.x, point.y)
        guard !items.isEmpty, distance >= layout.innerRadius else { return nil }
        if let index = selectedIndex, chosenWindow(of: items[index]) != nil,
           layout.actionRailContains(point, index: index, count: items.count) {
            return items[index]
        }
        let angle = atan2(point.y, point.x)
        return items[WheelGeometry.index(at: angle, count: items.count)]
    }

    /// Only the action on the visible rail is clickable; hidden sectors have no close target.
    func closeTarget(at point: CGPoint) -> (item: WheelItem, window: AppWindow)? {
        guard let index = selectedIndex, let window = chosenWindow(of: items[index]) else { return nil }
        let center = layout.closeButtonCenter(index: index, count: items.count)
        guard hypot(point.x - center.x, point.y - center.y) <= WheelLayout.closeButtonHitRadius else { return nil }
        return (items[index], window)
    }

    // MARK: Close button hover

    private func updateHover(at point: CGPoint) {
        let onButton = closeTarget(at: point) != nil
        if onButton != isCloseButtonHovered { isCloseButtonHovered = onButton }
    }

    /// Tab / ⇧Tab: next / previous slot clockwise.
    func step(backward: Bool) {
        guard !items.isEmpty else { return }
        let count = items.count
        let current = selectedIndex ?? (backward ? 0 : -1)
        select(((current + (backward ? -1 : 1)) % count + count) % count)
        touch()
        hasClosedSomething = false
        // Keyboard wins until the mouse deliberately moves again.
        anchorPointer(at: lastPointer)
        updateHover(at: lastPointer)
    }

    func reset() {
        select(nil)
        isPointerActive = false
        hasClosedSomething = false
        selectionReach = 0.5
        if isCloseButtonHovered { isCloseButtonHovered = false }
    }

    private func anchorPointer(at point: CGPoint) {
        pointerAnchor = point
        lastPointer = point
        isPointerActive = false
        selectionReach = 0.5
    }

    private func updateSelectionReach(distance: CGFloat) {
        let travel = max(distance - layout.innerRadius, 0)
        // No hard stop at the rim: extra reach keeps adding a little contrast.
        let reach = travel / (travel + max(layout.outerRadius * 0.65, 1))
        // Small visual steps avoid invalidating the view on every subpixel mouse move.
        let rounded = (reach * 100).rounded() / 100
        if selectionReach != rounded { selectionReach = rounded }
    }

    /// Only write on change: every write to an @Observable property triggers a re-render.
    private func select(_ index: Int?) {
        if index != selectedIndex { selectedIndex = index }
    }

    private func touch() {
        if !wasTouched { wasTouched = true }
    }
}

private extension NSRunningApplication {
    /// When the app was launched. `launchDate` is nil for apps LaunchServices didn't start
    /// itself (Finder at login, browsers started by automation tools) — then ask the kernel.
    var startDate: Date {
        if let launchDate { return launchDate }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, processIdentifier]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else {
            return .distantPast
        }
        let started = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(started.tv_sec) + TimeInterval(started.tv_usec) / 1_000_000)
    }
}

/// Wheel sizes, shared by drawing (WheelView) and hit-testing (WheelModel).
struct WheelLayout {
    static let standard = WheelLayout(diameter: 560)

    let diameter: CGFloat

    var outerRadius: CGFloat { diameter / 2 - 6 }
    /// The hub: center circle with the window preview and the app name.
    var innerRadius: CGFloat { diameter * 0.34 }
    var iconRadius: CGFloat { (outerRadius + innerRadius) / 2 }
    /// Box for the preview in the hub; with the name below it still fits inside the circle.
    var previewSize: CGSize { CGSize(width: innerRadius * 1.6, height: innerRadius) }

    /// App icons shrink when there are many, so neighbours never touch.
    func iconSize(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let slotLength = 2 * .pi * iconRadius / CGFloat(count)
        return min(60, slotLength * 0.64)
    }

    // MARK: Selected sector action rail

    static let closeButtonSize: CGFloat = 16
    static let closeButtonHitRadius: CGFloat = 11
    static let actionRailHalfAngle: Double = 0.085
    static let closeButtonAngleOffset: Double = 0.045
    var actionRailRadius: CGFloat { outerRadius + 4.5 }

    /// The close action stays on the side opposite the icon’s window badge.
    func actionRailDirection(index: Int, count: Int) -> Double {
        let angle = WheelGeometry.angle(of: index, count: count)
        return sin(angle) + cos(angle) >= -0.000_001 ? 1 : -1
    }

    func actionRailAngle(index: Int, count: Int) -> Double {
        WheelGeometry.angle(of: index, count: count)
    }

    func closeButtonCenter(index: Int, count: Int) -> CGPoint {
        let angle = WheelGeometry.angle(of: index, count: count) + actionRailDirection(index: index, count: count) * Self.closeButtonAngleOffset
        return CGPoint(x: actionRailRadius * cos(angle), y: actionRailRadius * sin(angle))
    }

    /// The visible arc and a narrow approach from its icon keep the selected owner stable.
    func actionRailContains(_ point: CGPoint, index: Int, count: Int) -> Bool {
        let angle = WheelGeometry.angle(of: index, count: count)
        let railAngle = actionRailAngle(index: index, count: count)
        let offset = atan2(sin(atan2(point.y, point.x) - railAngle), cos(atan2(point.y, point.x) - railAngle))
        if abs(hypot(point.x, point.y) - actionRailRadius) <= Self.closeButtonHitRadius,
           abs(offset) <= Self.actionRailHalfAngle + 0.035 { return true }
        let start = CGPoint(x: iconRadius * cos(angle), y: iconRadius * sin(angle))
        let end = closeButtonCenter(index: index, count: count)
        let dx = end.x - start.x, dy = end.y - start.y
        let t = ((point.x - start.x) * dx + (point.y - start.y) * dy) / (dx * dx + dy * dy)
        guard t >= 0, t <= 1 else { return false }
        return hypot(point.x - start.x - t * dx, point.y - start.y - t * dy) <= Self.closeButtonHitRadius
    }

    /// What the wheel view draws on: the wheel plus room for what sticks out past the rim
    /// (the close action, shadows).
    var canvasSize: CGFloat { diameter + 80 }
}

/// Wheel geometry in SwiftUI coordinates (y down), angles in radians.
/// Slot 0 is at 12 o'clock, then clockwise.
enum WheelGeometry {
    static func sectorAngle(count: Int) -> Double {
        2 * Double.pi / Double(max(count, 1))
    }

    /// Angle of the middle of slot `index`.
    static func angle(of index: Int, count: Int) -> Double {
        -Double.pi / 2 + Double(index) * sectorAngle(count: count)
    }

    /// Which slot an angle (from atan2) points at.
    static func index(at angle: Double, count: Int) -> Int {
        let raw = Int(((angle + Double.pi / 2) / sectorAngle(count: count)).rounded())
        return (raw % count + count) % count
    }
}
