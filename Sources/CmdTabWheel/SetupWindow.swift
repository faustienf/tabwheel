import AppKit
import ServiceManagement
import SwiftUI

/// First-run setup: what the app needs, what's granted, and buttons that lead to the right
/// place in System Settings. Shown on first launch, whenever Accessibility is missing at
/// launch, and from the menu bar (Setup…).
@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    private static let completedKey = "setupCompleted"

    /// The user went through setup once (Done or Later).
    static var isCompleted: Bool { UserDefaults.standard.bool(forKey: completedKey) }

    private let model = SetupModel()
    private var window: NSWindow?
    private var timer: Timer?

    func show() {
        model.refresh()
        let window = self.window ?? makeWindow()
        self.window = window
        // While setup is open the app gets a Dock icon and a place in ⌘Tab: the user goes
        // back and forth to System Settings and needs a way back here.
        NSApp.setActivationPolicy(.regular)
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        startPolling()
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        NSApp.setActivationPolicy(.accessory) // back to a menu bar app
    }

    private func makeWindow() -> NSWindow {
        let view = SetupView(model: model) { [weak self] in self?.finish() }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "⌘Tab Wheel Setup"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.completedKey)
        window?.close()
    }

    /// macOS has no "permission granted" callback — check twice a second while the window is open.
    private func startPolling() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.refresh() }
        }
    }
}

/// Live state behind the setup window.
@MainActor
@Observable
final class SetupModel {
    private(set) var hasAccessibility = Permissions.hasAccessibility
    private(set) var hasScreenRecording = Permissions.hasScreenRecording
    private(set) var loginItem = LoginItem.status
    /// Why "Open at login" couldn't be switched, if it couldn't.
    private(set) var loginItemError: String?
    /// Screen Recording was requested from this window — macOS will want a relaunch.
    private(set) var askedForScreenRecording = false

    /// Live: reads the real permissions now and on every `refresh()`.
    init() {}

    /// Xcode previews: a fixed state that `refresh()` leaves alone.
    init(previewAccessibility: Bool, screenRecording: Bool, loginItem: SMAppService.Status,
         askedForScreenRecording: Bool = false) {
        hasAccessibility = previewAccessibility
        hasScreenRecording = screenRecording
        self.loginItem = loginItem
        self.askedForScreenRecording = askedForScreenRecording
        isPreview = true
    }

    @ObservationIgnored private var isPreview = false

    /// Only writes what changed: every write re-renders the window.
    func refresh() {
        guard !isPreview else { return }
        let accessibility = Permissions.hasAccessibility
        if accessibility != hasAccessibility { hasAccessibility = accessibility }
        let screenRecording = Permissions.hasScreenRecording
        if screenRecording != hasScreenRecording { hasScreenRecording = screenRecording }
        let login = LoginItem.status
        if login != loginItem { loginItem = login }
    }

    func requestAccessibility() {
        Permissions.requestAccessibility()
    }

    func requestScreenRecording() {
        askedForScreenRecording = true
        Permissions.requestScreenRecording()
    }

    func setOpenAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
        refresh()
    }
}

struct SetupView: View {
    let model: SetupModel
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            VStack(spacing: 0) {
                PermissionRow(
                    symbol: "keyboard",
                    title: "Accessibility",
                    tag: "Required",
                    detail: "Catches ⌘Tab and brings the window you pick to the front.",
                    isGranted: model.hasAccessibility,
                    action: model.requestAccessibility
                )
                Divider().padding(.leading, 60)
                PermissionRow(
                    symbol: "rectangle.dashed.badge.record",
                    title: "Screen Recording",
                    tag: "Optional",
                    detail: model.askedForScreenRecording && !model.hasScreenRecording
                        ? "Once you switch it on, macOS asks to quit and reopen the app. Choose Quit & Reopen."
                        : "Shows window previews in the wheel. Without it you see app icons.",
                    isGranted: model.hasScreenRecording,
                    action: model.requestScreenRecording
                )
                Divider().padding(.leading, 60)
                loginRow
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))

            footer
        }
        .padding(.horizontal, 28)
        .padding(.top, 34) // room for the transparent title bar's close button
        .padding(.bottom, 24)
        .frame(width: 520)
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to ⌘Tab Wheel")
                    .font(.title2.weight(.semibold))
                Text("Hold ⌘ and press Tab to open a wheel of your apps, point at one and let go. It needs a couple of permissions first.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var loginRow: some View {
        SetupRow(symbol: "power", title: "Open at login", tag: nil, detail: loginDetail) {
            if model.loginItem == .requiresApproval {
                Button("Open Login Items", action: LoginItem.openSettings)
            } else {
                Toggle("Open at login", isOn: Binding(
                    get: { model.loginItem == .enabled },
                    set: { model.setOpenAtLogin($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
        }
    }

    private var loginDetail: String {
        if let error = model.loginItemError { return error }
        if model.loginItem == .requiresApproval { return "Allow it in System Settings → General → Login Items." }
        return "Starts in the menu bar when you log in."
    }

    private var footer: some View {
        HStack {
            if model.hasAccessibility {
                Label("Ready. Hold ⌘ and press Tab.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for Accessibility…")
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(model.hasAccessibility ? "Done" : "Later", action: onDone)
                .keyboardShortcut(model.hasAccessibility ? .defaultAction : .cancelAction)
                .controlSize(.large)
        }
    }
}

/// One permission: what it's for, and either a check mark or a button to grant it.
private struct PermissionRow: View {
    let symbol: String
    let title: String
    let tag: String
    let detail: String
    let isGranted: Bool
    let action: () -> Void

    var body: some View {
        SetupRow(symbol: symbol, title: title, tag: tag, detail: detail) {
            if isGranted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .fontWeight(.medium)
            } else {
                Button("Open Settings", action: action)
            }
        }
        .animation(.easeOut(duration: 0.2), value: isGranted)
    }
}

private struct SetupRow<Trailing: View>: View {
    let symbol: String
    let title: String
    let tag: String?
    let detail: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.headline)
                    if let tag {
                        Text(tag)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

struct SetupView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            SetupView(model: SetupModel(previewAccessibility: false, screenRecording: false, loginItem: .notRegistered)) {}
                .previewDisplayName("Nothing granted")
            SetupView(model: SetupModel(previewAccessibility: true, screenRecording: false, loginItem: .requiresApproval,
                                        askedForScreenRecording: true)) {}
                .previewDisplayName("Waiting for Screen Recording")
            SetupView(model: SetupModel(previewAccessibility: true, screenRecording: true, loginItem: .enabled)) {}
                .previewDisplayName("All set")
        }
    }
}
