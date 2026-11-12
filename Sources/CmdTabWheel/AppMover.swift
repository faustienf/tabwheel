import AppKit
import Darwin

/// Started from outside the Applications folder (Downloads, a disk image, a build folder), the
/// app offers to move itself there and relaunches from the new place — like most Mac apps do.
/// Runs first thing at launch, before setup: Login Items remember where the app was when it
/// was added, so it should already be in its final place by then.
///
/// Debug builds never ask: they run from build/ under Xcode on purpose.
@MainActor
enum AppMover {
    /// "Do Not Move" + "Don't ask again".
    private static let suppressedKey = "moveToApplicationsSuppressed"
    /// "Open at login" was on for the old copy; the moved copy turns it back on for itself.
    private static let reRegisterLoginItemKey = "reRegisterLoginItemAfterMove"

    /// True when the app is moving and relaunching: the caller should stop launching.
    static func moveIfNeeded() -> Bool {
        finishPreviousMove()
        #if DEBUG
        return false
        #else
        let running = Bundle.main.bundleURL
        guard running.pathExtension == "app",
              !isInApplicationsFolder(running),
              !UserDefaults.standard.bool(forKey: suppressedKey)
        else { return false }

        // Downloaded apps run from a randomized read-only copy (App Translocation) until moved.
        // Work with the real one.
        let source = originalLocation(of: running)
        guard !isInApplicationsFolder(source) else { return false }

        let folder = installFolder()
        let destination = folder.appendingPathComponent(source.lastPathComponent)
        guard askToMove(from: source) else { return false }

        let isReadOnly = (try? source.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        let diskImage = isReadOnly ? diskImageVolume(containing: source) : nil
        do {
            try install(source, at: destination)
        } catch {
            log.error("move to Applications failed: \(error.localizedDescription, privacy: .public)")
            showFailure(error)
            return false
        }
        if !isReadOnly {
            // The Trash, not rm: it's the user's file, and they can still get it back.
            try? FileManager.default.trashItem(at: source, resultingItemURL: nil)
        }
        if LoginItem.status == .enabled {
            try? LoginItem.setEnabled(false)
            UserDefaults.standard.set(true, forKey: reRegisterLoginItemKey)
        }
        // The folder's name only: a full ~/Applications path would carry the user's name.
        log.notice("moved to \(folder.lastPathComponent, privacy: .public), relaunching")
        relaunch(destination, ejecting: diskImage)
        return true
        #endif
    }

    // MARK: - Where

    private static var applicationsFolders: [URL] {
        FileManager.default.urls(for: .applicationDirectory, in: [.localDomainMask, .userDomainMask])
    }

    private static func isInApplicationsFolder(_ url: URL) -> Bool {
        // Resolve the folder, not the app: an app in /Applications may itself be a symlink
        // to somewhere else (Safari is) and is still in /Applications.
        let folder = url.deletingLastPathComponent().resolvingSymlinksInPath().path + "/"
        return applicationsFolders.contains { folder.hasPrefix($0.resolvingSymlinksInPath().path + "/") }
    }

    /// /Applications; for a user who can't write there (not an admin), ~/Applications.
    private static func installFolder() -> URL {
        let system = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if FileManager.default.isWritableFile(atPath: system.path) { return system }
        let user = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
        try? FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        return user
    }

    /// Undoes App Translocation (Security framework, private API — looked up at runtime).
    private static func originalLocation(of url: URL) -> URL {
        typealias IsTranslocated = @convention(c) (
            CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?
        ) -> UInt8 // Boolean
        typealias OriginalPath = @convention(c) (
            CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?
        ) -> Unmanaged<CFURL>?

        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let isTranslocatedSymbol = dlsym(security, "SecTranslocateIsTranslocatedURL"),
              let originalPathSymbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL")
        else { return url }
        let isTranslocated = unsafeBitCast(isTranslocatedSymbol, to: IsTranslocated.self)
        let originalPath = unsafeBitCast(originalPathSymbol, to: OriginalPath.self)

        var translocated = false
        guard isTranslocated(url as CFURL, &translocated, nil) != 0, translocated,
              let original = originalPath(url as CFURL, nil)?.takeRetainedValue()
        else { return url }
        return original as URL
    }

    /// The mount point, if `url` sits on a mounted disk image.
    private static func diskImageVolume(containing url: URL) -> URL? {
        guard let volume = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume else { return nil }
        let hdiutil = Process()
        hdiutil.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        hdiutil.arguments = ["info", "-plist"]
        let output = Pipe()
        hdiutil.standardOutput = output
        guard (try? hdiutil.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        hdiutil.waitUntilExit()

        guard let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = info["images"] as? [[String: Any]]
        else { return nil }
        let mountPoints = images
            .flatMap { $0["system-entities"] as? [[String: Any]] ?? [] }
            .compactMap { $0["mount-point"] as? String }
        let volumePath = volume.standardizedFileURL.path
        return mountPoints.contains { URL(fileURLWithPath: $0).standardizedFileURL.path == volumePath } ? volume : nil
    }

    // MARK: - Moving

    private static func askToMove(from source: URL) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Move to the Applications folder?"
        alert.informativeText = """
            ⌘Tab Wheel is running from “\(FileManager.default.displayName(atPath: source.deletingLastPathComponent().path))”. \
            Moved to Applications, it can open at login and won’t vanish when this folder gets cleaned up.
            """
        alert.addButton(withTitle: "Move to Applications")
        let doNotMove = alert.addButton(withTitle: "Do Not Move")
        doNotMove.keyEquivalent = "\u{1b}"
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don’t ask again"

        NSApp.activate()
        let response = alert.runModal()
        if response == .alertFirstButtonReturn { return true }
        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: suppressedKey)
        }
        return false
    }

    /// Copies the app to `destination`, replacing (and quitting) a copy that's already there.
    private static func install(_ source: URL, at destination: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            quitApp(at: destination)
            try fileManager.trashItem(at: destination, resultingItemURL: nil)
        }
        try fileManager.copyItem(at: source, to: destination)
        // It already passed Gatekeeper to get this far. Without the quarantine flag the new copy
        // opens without another warning and isn't translocated again.
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-dr", "com.apple.quarantine", destination.path]
        try? xattr.run()
        xattr.waitUntilExit()
    }

    /// An older copy being replaced may be running (two copies would fight over ⌘Tab).
    private static func quitApp(at url: URL) {
        let path = url.resolvingSymlinksInPath().path
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != me && $0.bundleURL?.resolvingSymlinksInPath().path == path }
        others.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(3)
        while others.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    /// A tiny shell outlives us: waits until this process is gone, ejects the disk image the app
    /// came from (if any), and opens the moved copy.
    private static func relaunch(_ app: URL, ejecting diskImage: URL?) {
        let script = """
            while /bin/kill -0 "$1" >/dev/null 2>&1; do /bin/sleep 0.1; done
            [ -n "$3" ] && /usr/bin/hdiutil detach "$3" -quiet
            /usr/bin/open "$2"
            """
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", script, "relaunch",
                           String(ProcessInfo.processInfo.processIdentifier), app.path, diskImage?.path ?? ""]
        do {
            try shell.run()
        } catch {
            // No shell (shouldn't happen): start the new copy now, as a separate instance.
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        }
        NSApp.terminate(nil)
    }

    /// In the moved copy: turn "Open at login" back on if the old copy had it.
    private static func finishPreviousMove() {
        guard UserDefaults.standard.bool(forKey: reRegisterLoginItemKey) else { return }
        UserDefaults.standard.removeObject(forKey: reRegisterLoginItemKey)
        try? LoginItem.setEnabled(true)
    }

    private static func showFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t move ⌘Tab Wheel to Applications"
        alert.informativeText = "\(error.localizedDescription)\n\nYou can drag it there in Finder yourself."
        alert.runModal()
    }
}
