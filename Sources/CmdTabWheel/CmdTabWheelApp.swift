import AppKit

@main
enum CmdTabWheelApp {
    @MainActor
    static func main() {
        // Recovery: `CmdTabWheel --restore-native-switcher` turns the system ⌘Tab back on after
        // the app died without cleaning up (crash, kill -9, Xcode's Stop button).
        if CommandLine.arguments.contains("--restore-native-switcher") {
            NativeSwitcher.setEnabled(true)
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Agent app: no Dock icon, no menu bar, not in the ⌘Tab list.
        // Same as LSUIElement in Info.plist, but also applies to `swift run`.
        app.setActivationPolicy(.accessory)
        // NSApplication.delegate is weak — keep the delegate alive for the whole run loop.
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
