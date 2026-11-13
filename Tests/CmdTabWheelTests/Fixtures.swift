import AppKit
@testable import CmdTabWheel

/// Wheels built from made-up apps and windows, without asking the system for its own.
@MainActor
enum Fixture {
    /// Any running app does for `WheelItem.app`; the tests never look at it.
    static func app(_ pid: pid_t, _ name: String) -> WheelItem {
        WheelItem(pid: pid, name: name, icon: NSImage(), app: .current)
    }

    static func window(_ id: CGWindowID, _ place: AppWindow.Place = .here) -> AppWindow {
        AppWindow(id: id, title: nil, place: place)
    }

    static func wheel(_ apps: [WheelItem], windows: [pid_t: [AppWindow]] = [:],
                      quickSwitchTo previous: pid_t? = nil) -> WheelModel {
        let model = WheelModel(layout: .standard)
        model.load(apps: apps, windows: windows, pointer: .zero, quickSwitchTo: previous)
        return model
    }
}

extension WheelModel {
    /// The mouse at the middle of slot `index`, `radius` points from the wheel center
    /// (250 is on the ring, between the hub and the rim).
    func point(at index: Int, radius: CGFloat = 250, nudge: Double = 0) {
        movePointer(to: point(index, radius: radius, nudge: nudge))
    }

    func point(_ index: Int, radius: CGFloat = 250, nudge: Double = 0) -> CGPoint {
        let angle = WheelGeometry.angle(of: index, count: items.count) + nudge
        return CGPoint(x: radius * cos(angle), y: radius * sin(angle))
    }

    var names: [String] { items.map(\.name) }
}
