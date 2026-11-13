import AppKit

/// The live stream of the window in the hub. On unless turned off in the menu; cached
/// screenshots are there either way.
@MainActor
final class LivePreviewSettings {
    private static let defaultsKey = "livePreviewEnabled"
    private let defaults: UserDefaults
    private(set) var isEnabled: Bool
    var onChange: (Bool) -> Void = { _ in }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Self.defaultsKey) as? Bool ?? true
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.defaultsKey)
        onChange(enabled)
    }

    func makeMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.view = SwitchMenuItemView(title: "Live Preview", isOn: isEnabled) { [weak self] enabled in
            self?.setEnabled(enabled)
        }
        item.toolTip = "Continuously update the selected window preview while the wheel is open."
        return item
    }
}
