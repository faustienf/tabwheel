import AppKit

@main
enum CmdTabWheelApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Without an .app bundle `swift run` starts as a background process:
        // no Dock icon, no menu bar, windows don't come to front.
        app.setActivationPolicy(.regular)
        // NSApplication.delegate is weak — keep the delegate alive for the whole run loop.
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
