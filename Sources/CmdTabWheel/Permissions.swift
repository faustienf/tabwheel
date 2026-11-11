import AppKit
import ApplicationServices
import ServiceManagement

/// What the app needs from macOS. All checks are cheap and live, so the setup window
/// can poll them and flip a row to "granted" while the user is still in System Settings.
@MainActor
enum Permissions {
    /// Required: the ⌘Tab event tap and raising other apps' windows.
    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// Optional: window previews in the hub. Without it the hub shows app icons.
    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// Puts the app into the Accessibility list (switched off; macOS shows its own alert)
    /// and opens that list, so the user only has to flip the switch.
    static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openPrivacySettings("Privacy_Accessibility")
    }

    /// The system prompt shows only the very first time; afterwards the list in
    /// System Settings is the only way, so open it as well.
    static func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        openPrivacySettings("Privacy_ScreenCapture")
    }

    private static func openPrivacySettings(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// "Open at login" through the system Login Items list (System Settings → General → Login Items).
@MainActor
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
