import AppKit

/// Lets our app set the mouse cursor although it's never the active app — normally macOS
/// ignores cursor changes from background apps. Private WindowServer connection property,
/// the same one AltTab uses.
enum BackgroundCursor {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SetConnectionProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

    static func enable() {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard
            let mainSymbol = dlsym(rtldDefault, "CGSMainConnectionID"),
            let setSymbol = dlsym(rtldDefault, "CGSSetConnectionProperty")
        else {
            log.error("cursor: CGS symbols not found")
            return
        }
        let mainConnectionID = unsafeBitCast(mainSymbol, to: MainConnectionID.self)
        let setConnectionProperty = unsafeBitCast(setSymbol, to: SetConnectionProperty.self)
        let connection = mainConnectionID()
        let result = setConnectionProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        if result != 0 {
            log.error("cursor: SetsCursorInBackground failed with \(result, privacy: .public)")
        }
    }
}
