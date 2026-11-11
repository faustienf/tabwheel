import AppKit

/// The app appearance is inherited by the wheel, its native blur and SwiftUI content.
@MainActor
final class AppearanceSettings: NSObject {
    enum Theme: String, CaseIterable {
        case system, light, dark

        var title: String {
            switch self {
            case .system: "Follow System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }

        var appearance: NSAppearance? {
            switch self {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
    }

    private static let defaultsKey = "appearanceTheme"
    private let defaults: UserDefaults
    private(set) var theme: Theme

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        theme = defaults.string(forKey: Self.defaultsKey).flatMap(Theme.init(rawValue:)) ?? .system
        super.init()
    }

    func apply() {
        // nil restores live system appearance updates, including scheduled theme changes.
        NSApp.appearance = theme.appearance
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Appearance")
        for option in Theme.allCases {
            let item = NSMenuItem(title: option.title, action: #selector(selectTheme(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = option == theme ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func selectTheme(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let selection = Theme(rawValue: rawValue) else { return }
        theme = selection
        defaults.set(theme.rawValue, forKey: Self.defaultsKey)
        apply()
        for item in sender.menu?.items ?? [] {
            item.state = (item.representedObject as? String) == theme.rawValue ? .on : .off
        }
    }
}
