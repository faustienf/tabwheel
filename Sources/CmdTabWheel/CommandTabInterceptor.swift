import AppKit
import Carbon
import CoreGraphics
import IOKit
import os

/// Where the app's log entries go in the unified log (`log show --predicate 'subsystem == …'`).
let logSubsystem = "com.faustienf.CmdTabWheel"
let log = Logger(subsystem: logSubsystem, category: "app")

/// What the user does with the wheel on the keyboard.
enum WheelInput: Equatable {
    case open                    // ⌘Tab pressed
    case step(backward: Bool)    // Tab / ⇧Tab again while ⌘ is still held
    case commit                  // ⌘ released
    case cancel                  // Esc
    case closeWindow             // ⌘W: close the selected window
    case quitApp                 // ⌘Q: quit the selected app
}

/// Catches ⌘Tab system-wide via a CGEventTap and turns it into `WheelInput`.
/// Creating the tap requires Accessibility permission — without it `start()` returns false.
/// Keyboard only: the mouse has its own tap, on only while the wheel is open (see MouseTap).
@MainActor
final class CommandTabInterceptor {
    var onInput: @MainActor (WheelInput) -> Void = { _ in }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// ⌘Tab was pressed and ⌘ is still held — the wheel is open.
    private var isActive = false
    /// Some app holds Secure Input, see `checkSecureInput`.
    private var isSecureInputOn = false
    private var secureInputTimer: Timer?

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
        isSecureInputOn = false
        checkSecureInput()
        // No notification exists for it — poll; the check is a cheap, local call.
        secureInputTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSecureInput() }
        }
        log.notice("⌘Tab interceptor started")
        return true
    }

    /// While any app holds Secure Input (a focused password field; Chrome and some terminals
    /// also leave it on by mistake), macOS shows no keystrokes to event taps, ours included.
    /// With the system switcher off, ⌘Tab would then do nothing at all — so for that time the
    /// system switcher gets ⌘Tab back.
    private func checkSecureInput() {
        let isOn = IsSecureEventInputEnabled()
        guard isOn != isSecureInputOn, !isActive else { return }
        isSecureInputOn = isOn
        NativeSwitcher.setEnabled(isOn)
        if isOn {
            let owner = SecureInput.ownerName() ?? "an app"
            log.notice("Secure Input is on (\(owner, privacy: .public)): system ⌘Tab until it's off")
        } else {
            log.notice("Secure Input is off: the wheel has ⌘Tab again")
        }
    }

    /// The wheel was closed some other way (a mouse click) while ⌘ is still held:
    /// releasing ⌘ now means nothing, and Tab with ⌘ still down opens the wheel again.
    func endSession() {
        isActive = false
    }

    func stop() {
        secureInputTimer?.invalidate()
        secureInputTimer = nil
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
    /// `character`: what the key types in the current layout (key events with ⌘ only).
    func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags,
                character: String?, isRepeat: Bool) -> Bool {
        let command = flags.contains(.maskCommand)
        let letter = command ? KeyCode.latinLetter(keyCode: keyCode, character: character) : nil

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

        // ⌘W / ⌘Q on the selected sector, like ⌘Q in the system switcher. Never passed on:
        // the app below must not close its own window. Auto-repeat is ignored — holding W
        // shouldn't close window after window.
        case .keyDown where isActive && letter == "w":
            if !isRepeat { onInput(.closeWindow) }
            return false

        case .keyDown where isActive && letter == "q":
            if !isRepeat { onInput(.quitApp) }
            return false

        case .keyUp where isActive && (letter == "w" || letter == "q"):
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

enum KeyCode {
    static let tab: Int64 = 48    // kVK_Tab
    static let escape: Int64 = 53 // kVK_Escape

    /// Latin letters at their US positions (kVK_ANSI_W, kVK_ANSI_Q).
    private static let usLetters: [Int64: String] = [13: "w", 12: "q"]

    /// The Latin letter a key types, the way macOS matches ⌘-shortcuts: by the current layout
    /// (AZERTY, Dvorak…), and by the US position for layouts without Latin letters (Russian…).
    static func latinLetter(keyCode: Int64, character: String?) -> String? {
        if let character, character.count == 1, character.unicodeScalars.allSatisfy({ $0.isASCII }) {
            return character
        }
        return usLetters[keyCode]
    }
}

/// Who holds Secure Input — for the log, so it's clear which app to blame.
enum SecureInput {
    static func ownerName() -> String? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard let users = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
                  .takeRetainedValue() as? [[String: Any]],
              let pid = users.lazy.compactMap({ $0["kCGSSessionSecureInputPID"] as? pid_t }).first
        else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
    }
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
    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    // The typed character only matters for ⌘-shortcuts, so skip the NSEvent for anything else.
    // Key events only: asking a flagsChanged event for characters throws.
    let isKey = type == .keyDown || type == .keyUp
    let character = isKey && flags.contains(.maskCommand)
        ? NSEvent(cgEvent: event)?.charactersIgnoringModifiers?.lowercased()
        : nil
    // The tap's run loop source is on the main run loop, so we are on the main thread.
    let pass = MainActor.assumeIsolated {
        interceptor.handle(type: type, keyCode: keyCode, flags: flags, character: character, isRepeat: isRepeat)
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
