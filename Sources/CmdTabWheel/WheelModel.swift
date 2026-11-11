import AppKit
import Observation

/// One sector of the wheel: a running app — or, in the sector-per-window mode, one of its windows.
struct WheelItem: Identifiable {
    struct ID: Hashable {
        let pid: pid_t
        let window: CGWindowID?
    }

    let pid: pid_t
    let name: String
    let icon: NSImage
    let app: NSRunningApplication
    /// Sector per window: the window this sector stands for. nil = the app as a whole.
    var window: AppWindow?
    /// Sector per window: "2" on the icon of the app's second window; nil for one-window apps.
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
    /// Sector per window: each window is a sector of its own.
    /// Fan: one sector per app, its windows fanned out past the rim. Re-read on every opening.
    private(set) var windowMode: WindowMode = .default
    /// Fan: which window each app points at, as an index into `windows`; missing = the front one.
    private(set) var windowIndex: [pid_t: Int] = [:]

    var selectedItem: WheelItem? { selectedIndex.map { items[$0] } }

    /// The mouse (not Tab) is on a sector right now — the cursor shows a pointing hand.
    var isPointingAtSector: Bool { isPointerActive && selectedIndex != nil }

    /// The previously used app. A quick ⌘Tab — released without touching anything — goes there.
    private(set) var quickSwitchPID: pid_t?
    /// The user did something this time: moved the mouse past the threshold or pressed Tab.
    /// After that, releasing ⌘ with nothing selected means "cancel", not "quick switch".
    private(set) var wasTouched = false

    var quickSwitchItem: WheelItem? {
        guard !wasTouched, let quickSwitchPID else { return nil }
        // With a sector per window: the window the app was left on, its front one.
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
    func reload(pointer: CGPoint, quickSwitchTo quickSwitchPID: pid_t?, windowMode: WindowMode = .default) {
        self.quickSwitchPID = quickSwitchPID
        self.windowMode = windowMode
        wasTouched = false
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { (app: $0, started: $0.startDate) } // look the date up once, not per comparison
            .sorted { ($0.started, $0.app.processIdentifier) < ($1.started, $1.app.processIdentifier) }
            .map(\.app)
        let running = Set(apps.map(\.processIdentifier))
        windows = WindowList.windowsByApp().filter { running.contains($0.key) }
        windowIndex = [:]
        items = apps.flatMap { app in
            let item = WheelItem(
                pid: app.processIdentifier,
                name: app.localizedName ?? app.bundleIdentifier ?? "?",
                icon: app.icon ?? NSImage(),
                app: app
            )
            let appWindows = windows[item.pid] ?? []
            guard windowMode == .sectorPerWindow, appWindows.count > 1 else { return [item] }
            // Creation order (window IDs only grow), not front to back: that changes with every
            // switch, and the sectors would swap places under the cursor.
            return appWindows.sorted { $0.id < $1.id }.enumerated().map { number, window in
                var sector = item
                sector.window = window
                sector.windowNumber = number + 1
                return sector
            }
        }
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
    }

    /// nil removes the preview (nothing to show any more).
    func setPreview(_ image: CGImage?, for key: PreviewKey) {
        previews[key] = image.map { NSImage(cgImage: $0, size: .zero) }
    }

    /// The window switching to `item` brings up; nil when it has none on this Space.
    func chosenWindow(of item: WheelItem) -> AppWindow? {
        if let window = item.window { return window }
        guard let list = windows[item.pid], !list.isEmpty else { return nil }
        return list[min(windowIndex[item.pid] ?? 0, list.count - 1)]
    }

    /// "Window 2 of 3" for the hub — only for apps with more than one window.
    func windowPosition(of item: WheelItem) -> (index: Int, count: Int)? {
        guard let list = windows[item.pid], list.count > 1 else { return nil }
        if let number = item.windowNumber { return (number - 1, list.count) }
        return (min(windowIndex[item.pid] ?? 0, list.count - 1), list.count)
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
        guard !items.isEmpty else { return }

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
        guard distance >= layout.innerRadius else {
            select(nil)
            return
        }
        let angle = atan2(point.y, point.x)
        // Past the rim, within the selected app's fan: the pointer picks one of its windows.
        if distance > layout.outerRadius, let (index, slot) = fanSlot(at: angle) {
            if (windowIndex[items[index].pid] ?? 0) != slot { windowIndex[items[index].pid] = slot }
            return
        }
        select(WheelGeometry.index(at: angle, count: items.count))
    }

    /// The app whose sector the segment center→`point` crosses; nil inside the hub.
    /// Used for clicks — no movement threshold, the cursor may already sit on an icon.
    func item(at point: CGPoint) -> WheelItem? {
        let distance = hypot(point.x, point.y)
        guard !items.isEmpty, distance >= layout.innerRadius else { return nil }
        let angle = atan2(point.y, point.x)
        if distance > layout.outerRadius, let (index, _) = fanSlot(at: angle) {
            return items[index] // a click on a fanned-out window: its window is already chosen
        }
        return items[WheelGeometry.index(at: angle, count: items.count)]
    }

    /// Fan mode: the selected app's windows, fanned out past the rim, and the chosen one.
    /// nil when there's no fan to show (other modes, nothing selected, a single window).
    func fan(of item: WheelItem) -> (windows: [AppWindow], chosen: Int)? {
        guard windowMode == .fan, let list = windows[item.pid], list.count > 1 else { return nil }
        return (list, min(windowIndex[item.pid] ?? 0, list.count - 1))
    }

    /// Which window of the selected app's fan the direction `angle` points at;
    /// nil when it points past the fan — then the pointer goes back to picking apps.
    private func fanSlot(at angle: Double) -> (index: Int, slot: Int)? {
        guard
            let index = selectedIndex,
            let fan = fan(of: items[index]),
            let slot = layout.fanSlot(
                at: angle,
                around: WheelGeometry.angle(of: index, count: items.count),
                count: fan.windows.count
            )
        else { return nil }
        return (index, slot)
    }

    /// Tab / ⇧Tab: next / previous slot clockwise.
    func step(backward: Bool) {
        guard !items.isEmpty else { return }
        let count = items.count
        let current = selectedIndex ?? (backward ? 0 : -1)
        select(((current + (backward ? -1 : 1)) % count + count) % count)
        touch()
        // Keyboard wins until the mouse deliberately moves again.
        anchorPointer(at: lastPointer)
    }

    func reset() {
        select(nil)
        isPointerActive = false
        selectionReach = 0.5
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

    // MARK: Window fan (window mode "fan")

    var fanThumbnailSize: CGSize { CGSize(width: 136, height: 86) }
    private var fanThumbnailHalfDiagonal: CGFloat { hypot(fanThumbnailSize.width, fanThumbnailSize.height) / 2 }
    /// Thumbnail centers sit on this circle — far enough out that no corner touches the rim.
    var fanRadius: CGFloat { outerRadius + 14 + fanThumbnailHalfDiagonal }
    /// Angle between neighbouring thumbnails: enough room for the long side plus a gap.
    var fanStep: Double { Double((max(fanThumbnailSize.width, fanThumbnailSize.height) + 14) / fanRadius) }
    /// What the wheel view draws on: the wheel plus room for the fan around it.
    var canvasSize: CGFloat { 2 * (fanRadius + fanThumbnailHalfDiagonal + 12) }

    /// Direction of thumbnail `slot` of `count`, the fan centered on the sector at `center`.
    func fanAngle(slot: Int, count: Int, around center: Double) -> Double {
        center + (Double(slot) - Double(count - 1) / 2) * fanStep
    }

    /// Which thumbnail the direction `angle` points at; nil outside the fan.
    func fanSlot(at angle: Double, around center: Double, count: Int) -> Int? {
        let offset = atan2(sin(angle - center), cos(angle - center)) // -π…π from the fan's middle
        let position = offset / fanStep + Double(count - 1) / 2
        guard position > -0.5, position < Double(count) - 0.5 else { return nil }
        return Int(position.rounded())
    }
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
