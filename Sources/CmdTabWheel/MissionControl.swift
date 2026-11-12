import AppKit
import ApplicationServices

/// Whether Mission Control is on screen. The wheel doesn't open there — like the system
/// switcher, which doesn't work there either.
///
/// The Dock draws Mission Control, and while it's up the Dock's accessibility tree has an
/// extra group with the identifier "mc" (the one Hammerspoon's hs.spaces looks for).
/// Anything that can't be checked counts as "not open": then the wheel just opens as usual.
enum MissionControl {
    static func isOpen() -> Bool {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return false }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        // Asked from inside the key tap, which holds the keyboard until it returns: never wait long.
        AXUIElementSetMessagingTimeout(app, 0.1)
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &children) == .success,
              let children = children as? [AXUIElement]
        else { return false }
        return children.contains { child in
            var identifier: CFTypeRef?
            return AXUIElementCopyAttributeValue(child, kAXIdentifierAttribute as CFString, &identifier) == .success
                && identifier as? String == "mc"
        }
    }
}
