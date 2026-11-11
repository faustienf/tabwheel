import AppKit

/// How an app's windows show up on the wheel. Picked in the menu bar; applies from the next ⌘Tab.
enum WindowMode: String, CaseIterable {
    /// Every window gets its own sector; an app's windows sit next to each other.
    case sectorPerWindow
    /// One sector per app; its windows fan out past the rim as thumbnails —
    /// keep moving the pointer outwards to pick one (a pie menu inside a pie menu).
    case fan

    static let `default`: WindowMode = .sectorPerWindow
    static let defaultsKey = "windowMode"

    static var saved: WindowMode {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(WindowMode.init(rawValue:)) ?? .default
    }

    var title: String {
        switch self {
        case .sectorPerWindow: "One sector per window"
        case .fan: "Windows fan out past the rim"
        }
    }
}

/// "Windows" submenu in the menu bar.
@MainActor
final class WindowModeSettings: NSObject {
    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Windows")
        for mode in WindowMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = mode == WindowMode.saved ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String else { return }
        UserDefaults.standard.set(rawValue, forKey: WindowMode.defaultsKey)
        for item in sender.menu?.items ?? [] {
            item.state = (item.representedObject as? String) == rawValue ? .on : .off
        }
    }
}
