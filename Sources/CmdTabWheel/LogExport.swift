import AppKit
import Carbon
import OSLog
import UniformTypeIdentifiers

/// Menu bar → Save Log…: one text file to attach to a bug report, no Terminal needed.
///
/// - This run's log. Without special privileges an app can only read its own entries, and
///   only since it was launched — so a crashed run's log is gone.
/// - That's what the latest crash report is for, if there's one from the last week.
/// - A few facts about the Mac and the app's state that explain most problems.
///
/// Nothing here is private: the log holds app names and errors, never window titles or keys,
/// and the save panel shows where the file goes.
@MainActor
enum LogExport {
    static func save() {
        let panel = NSSavePanel()
        panel.title = "Save Log"
        panel.message = "A text file to attach to a bug report: what ⌘Tab Wheel did since it started, and a few facts about this Mac."
        panel.nameFieldStringValue = "CmdTabWheel v\(AppVersion.number) log \(fileDate()).txt"
        panel.allowedContentTypes = [.plainText]
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        NSApp.activate() // a menu bar app's panel would open behind the front app
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let summary = summary()
        Task {
            // Reading the log store takes a moment: off the main thread.
            let text = await Task.detached(priority: .userInitiated) {
                summary + "\n" + logEntries() + latestCrashReport()
            }.value
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }

    /// The state that explains most problems: permissions, Secure Input, whether the wheel is on.
    private static func summary() -> String {
        let isInApplications = Bundle.main.bundleURL.deletingLastPathComponent().lastPathComponent == "Applications"
        let wheelEnabled = UserDefaults.standard.object(forKey: "wheelEnabled") as? Bool ?? true
        let secureInput = IsSecureEventInputEnabled() ? "on, held by \(SecureInput.ownerName() ?? "an app")" : "off"
        return """
            ⌘Tab Wheel \(AppVersion.description)\(isInApplications ? "" : ", not in an Applications folder")
            macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(hardwareModel())
            Displays: \(NSScreen.screens.count)
            Accessibility: \(Permissions.hasAccessibility ? "granted" : "NOT granted")
            Screen Recording: \(Permissions.hasScreenRecording ? "granted" : "not granted")
            Wheel: \(wheelEnabled ? "on" : "off")
            Secure Input: \(secureInput)
            Saved: \(Date().formatted(date: .abbreviated, time: .standard))

            """
    }

    nonisolated private static func logEntries() -> String {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let entries = try store.getEntries(matching: NSPredicate(format: "subsystem == %@", logSubsystem))
            let lines = entries.compactMap { entry -> String? in
                guard let entry = entry as? OSLogEntryLog else { return nil }
                return "\(entry.date.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3)))) "
                    + "\(level(entry.level)) \(entry.composedMessage)"
            }
            return "── Log since launch ──\n" + (lines.isEmpty ? "(empty)" : lines.joined(separator: "\n")) + "\n"
        } catch {
            return "── Log since launch ──\ncouldn't read it: \(error.localizedDescription)\n"
        }
    }

    nonisolated private static func level(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .error: "ERROR"
        case .fault: "FAULT"
        case .debug: "debug"
        case .info: "info "
        default: "     "
        }
    }

    /// The newest crash report of the app from the last 7 days, whole.
    nonisolated private static func latestCrashReport() -> String {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        let weekAgo = Date().addingTimeInterval(-7 * 24 * 3600)
        let reports = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        let latest = reports
            .filter { $0.lastPathComponent.hasPrefix("CmdTabWheel") }
            .compactMap { url -> (URL, Date)? in
                guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      date > weekAgo
                else { return nil }
                return (url, date)
            }
            .max { $0.1 < $1.1 }
        guard let (url, date) = latest, let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "\n── Crash reports ──\nnone in the last 7 days\n"
        }
        return "\n── Latest crash report: \(url.lastPathComponent), \(date.formatted()) ──\n" + text + "\n"
    }

    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [UInt8](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(decoding: model.prefix { $0 != 0 }, as: UTF8.self)
    }

    private static func fileDate() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return formatter.string(from: Date())
    }
}
