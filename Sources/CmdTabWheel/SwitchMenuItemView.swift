import AppKit

/// Menu row with a title and an on/off switch on the right — like the Wi-Fi and Bluetooth
/// rows in Control Center menus. Regular menu items can only show a checkmark.
final class SwitchMenuItemView: NSView {
    private let toggle = NSSwitch()
    private let onChange: (Bool) -> Void

    var isOn: Bool {
        get { toggle.state == .on }
        set { toggle.state = newValue ? .on : .off }
    }

    /// `isHeading`: bold, for the switch that heads the menu; other rows look like menu items.
    init(title: String, isOn: Bool, isHeading: Bool = false, onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 32))
        autoresizingMask = [.width] // stretch with the menu

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: isHeading ? .semibold : .regular)

        toggle.controlSize = .small
        toggle.state = isOn ? .on : .off
        toggle.target = self
        toggle.action = #selector(toggled)
        toggle.setAccessibilityLabel(title)

        for view in [label, toggle] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    @objc private func toggled() {
        onChange(isOn)
    }
}
