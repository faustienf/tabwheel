import AppKit
import CoreGraphics
import os

let log = Logger(subsystem: "com.faustienf.CmdTabWheel", category: "app")

/// What the user does with the wheel on the keyboard.
enum WheelInput {
    case open                    // ⌘Tab pressed
    case step(backward: Bool)    // Tab / ⇧Tab again while ⌘ is still held
    case commit                  // ⌘ released
    case cancel                  // Esc
}

/// Catches ⌘Tab system-wide via a CGEventTap and turns it into `WheelInput`.
/// Creating the tap requires Accessibility permission — without it `start()` returns false.
/// Keyboard only: the mouse is handled by the wheel panel itself (see WheelWindow).
@MainActor
final class CommandTabInterceptor {
    var onInput: @MainActor (WheelInput) -> Void = { _ in }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// ⌘Tab was pressed and ⌘ is still held — the wheel is open.
    private var isActive = false

    func start() -> Bool {
        guard tap == nil else { return true }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap, // can swallow events (listenOnly can't)
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log.error("CGEvent.tapCreate failed — Accessibility not granted?")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = source

        // Our tap works — now turn off the system switcher so it doesn't fire too.
        NativeSwitcher.setEnabled(false)
        log.notice("⌘Tab interceptor started")
        return true
    }

    /// The wheel was closed some other way (a mouse click) while ⌘ is still held:
    /// releasing ⌘ now means nothing, and Tab with ⌘ still down opens the wheel again.
    func endSession() {
        isActive = false
    }

    func stop() {
        NativeSwitcher.setEnabled(true)
        isActive = false
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        self.tap = nil
        self.runLoopSource = nil
    }

    /// Returns true to pass the event on, false to swallow it.
    fileprivate func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags) -> Bool {
        let command = flags.contains(.maskCommand)

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS disables taps that are too slow; just turn it back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }

        case .keyDown where keyCode == KeyCode.tab && command:
            if isActive {
                onInput(.step(backward: flags.contains(.maskShift)))
            } else {
                isActive = true
                onInput(.open)
            }
            return false // swallow ⌘Tab and its auto-repeat

        case .keyDown where keyCode == KeyCode.escape && isActive:
            isActive = false
            onInput(.cancel)
            return false

        case .keyUp where keyCode == KeyCode.tab && command:
            return false

        case .flagsChanged where isActive && !command:
            isActive = false
            onInput(.commit)

        default:
            break
        }
        return true
    }
}

private enum KeyCode {
    static let tab: Int64 = 48    // kVK_Tab
    static let escape: Int64 = 53 // kVK_Escape
}

/// C callback for the tap: no captures allowed, so `self` comes through `userInfo`.
private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let interceptor = Unmanaged<CommandTabInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
    // Pull out plain values: CGEvent itself isn't Sendable, so it stays out of the main-actor closure.
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags
    // The tap's run loop source is on the main run loop, so we are on the main thread.
    let pass = MainActor.assumeIsolated {
        interceptor.handle(type: type, keyCode: keyCode, flags: flags)
    }
    return pass ? Unmanaged.passUnretained(event) : nil
}

/// Turns the system ⌘Tab switcher on/off through the private SkyLight call
/// `CGSSetSymbolicHotKeyEnabled` — the same trick AltTab uses.
/// NB: the setting outlives our process, so it must be re-enabled on quit.
enum NativeSwitcher {
    private typealias SetSymbolicHotKeyEnabled = @convention(c) (Int32, Bool) -> Int32

    // Symbolic hot key IDs from SkyLight.
    private static let commandTab: Int32 = 1
    private static let commandShiftTab: Int32 = 2

    private static let setSymbolicHotKeyEnabled: SetSymbolicHotKeyEnabled? = {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let symbol = dlsym(rtldDefault, "CGSSetSymbolicHotKeyEnabled") else { return nil }
        return unsafeBitCast(symbol, to: SetSymbolicHotKeyEnabled.self)
    }()

    static func setEnabled(_ enabled: Bool) {
        guard let setSymbolicHotKeyEnabled else {
            log.error("CGSSetSymbolicHotKeyEnabled not found")
            return
        }
        // The state is global for the login session and outlives our process.
        let results = [
            setSymbolicHotKeyEnabled(commandTab, enabled),
            setSymbolicHotKeyEnabled(commandShiftTab, enabled),
        ]
        let state = enabled ? "enabled" : "disabled"
        // .public: os.Logger hides interpolated values as <private> by default.
        if results.allSatisfy({ $0 == 0 }) {
            log.notice("native ⌘Tab switcher \(state, privacy: .public)")
        } else {
            log.error("native ⌘Tab switcher NOT \(state, privacy: .public), CGError \(results, privacy: .public)")
        }
    }
}
