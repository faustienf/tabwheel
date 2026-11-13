import AppKit
import ScreenCaptureKit

/// What a preview pictures.
enum PreviewKey: Hashable {
    /// A window: the one switching would bring up, wherever it is.
    case window(CGWindowID)
    /// An app with no window on the wheel (hidden, say): a stand-in picture of one of its windows.
    case app(pid_t)
}

/// Cached screenshots for instant switching, plus a live stream of the window in the hub.
/// Needs Screen Recording permission — without it nothing is captured and the hub
/// shows app icons instead.
///
/// Speed: when the wheel opens, every window on it is captured at once, in parallel, before the
/// user even points anywhere. Results are cached by the model across openings, so from the
/// second ⌘Tab on, a (slightly old) preview shows instantly and the fresh one replaces it.
@MainActor
final class WindowPreviewer {
    /// Every window there is, listed when the wheel opened. Screenshots and the live stream
    /// look windows up here (ScreenCaptureKit needs its own window objects).
    private var content: SCShareableContent?
    private var contentLookup: Task<Void, Never>?
    /// Screenshots being taken. They keep going after the wheel closes: the next ⌘Tab shows them.
    private var snapshotPass: Task<Void, Never>?
    private var freshness = PreviewFreshness()
    var isLivePreviewEnabled = false {
        didSet { livePreview.isEnabled = isLivePreviewEnabled }
    }
    private lazy var livePreview = LiveWindowPreview { [weak self] key, size, onImage in
        guard let self, let lookup = self.contentLookup else { return nil }
        await lookup.value
        guard let content = self.content, !Task.isCancelled else { return nil }
        let window: SCWindow?
        switch key {
        case .window(let id): window = content.windows.first { $0.windowID == id }
        case .app(let pid): window = Self.biggestWindow(of: pid, in: content)
        }
        guard let window else { return nil }
        return try ScreenPreviewCapture(window: window, maxSize: size, onImage: onImage)
    }

    /// Captures every listed window; an app with no windows here (all on another Space, say)
    /// gets one picture of its biggest window instead. Successful results arrive as soon as
    /// they're ready; capture failures leave the last useful image in the cache.
    func refresh(
        windows: [pid_t: [CGWindowID]],
        maxSize: CGSize,
        onImage: @escaping @MainActor (PreviewKey, CGImage) -> Void
    ) {
        livePreview.stop()
        // No permission → don't even ask (no prompt spam).
        guard CGPreflightScreenCaptureAccess() else {
            contentLookup = nil
            content = nil
            return
        }
        let start = ContinuousClock.now
        let lookup = Task {
            do {
                content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            } catch {
                log.error("preview: window list failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        contentLookup = lookup
        freshness.keep(Set(windows.flatMap { pid, ids in ids.isEmpty ? [.app(pid)] : ids.map { .window($0) } }))

        // The last pass is still going (⌘Tab again right away): its pictures are fresh enough.
        guard snapshotPass == nil else { return }
        snapshotPass = Task {
            defer { snapshotPass = nil }
            await lookup.value
            guard let content else { return }
            let listTime = start.duration(to: .now)
            let byID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })

            var targets: [(key: PreviewKey, window: SCWindow?)] = []
            for (pid, ids) in windows {
                if ids.isEmpty {
                    targets.append((.app(pid), Self.biggestWindow(of: pid, in: content)))
                } else {
                    targets += ids.map { (.window($0), byID[$0]) }
                }
            }

            // One task per window. They all live on the main actor (SCWindow can't leave it),
            // but each one just waits on ScreenCaptureKit, so the captures still overlap.
            let captures = targets.map { target in
                Task {
                    let takenAt = ContinuousClock.now
                    guard let image = await Self.capture(target.window, maxSize: maxSize),
                          freshness.accept(target.key, takenAt: takenAt) else { return }
                    onImage(target.key, image)
                }
            }
            for capture in captures {
                await capture.value
            }
            log.notice("""
                previews: \(captures.count, privacy: .public) windows in \
                \(Self.milliseconds(start.duration(to: .now)), privacy: .public) ms \
                (window list \(Self.milliseconds(listTime), privacy: .public) ms)
                """)
        }
    }

    /// Streams the window in the hub (`nil`: nothing in the hub). Only after `refresh`, which
    /// lists the windows, and only with Live Preview on.
    func showLivePreview(for key: PreviewKey?, maxSize: CGSize,
                         onImage: @escaping @MainActor (PreviewKey, CGImage) -> Void) {
        guard isLivePreviewEnabled, contentLookup != nil else { return }
        livePreview.show(key, maxSize: maxSize) { [weak self] key, image in
            // A screenshot started before this frame and finishing after it must not replace it.
            guard let self, self.freshness.accept(key, takenAt: .now) else { return }
            onImage(key, image)
        }
    }

    func stopLivePreview() {
        livePreview.stop()
    }

    private static func capture(_ window: SCWindow?, maxSize: CGSize) async -> CGImage? {
        guard let window else { return nil }
        let (filter, configuration) = ScreenPreviewCapture.configuration(window: window, maxSize: maxSize)
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            log.error("preview: capture failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// For an app with nothing on the current Space: its biggest titled window elsewhere.
    private static func biggestWindow(of pid: pid_t, in content: SCShareableContent) -> SCWindow? {
        content.windows
            .filter {
                $0.owningApplication?.processID == pid
                    && $0.windowLayer == 0
                    && $0.frame.width > 40 && $0.frame.height > 40
                    && !($0.title ?? "").isEmpty
            }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds * 1000 + attoseconds / 1_000_000_000_000_000)
    }
}

/// Which picture of each window is the newest. Screenshots and live frames land out of order:
/// a screenshot started before a live frame can finish after it, and one from the previous ⌘Tab
/// can finish after this one's. An older picture never replaces a newer one.
struct PreviewFreshness {
    private var takenAt: [PreviewKey: ContinuousClock.Instant] = [:]

    /// Whether a picture taken at `instant` is newer than the one shown; if so, it's shown now.
    mutating func accept(_ key: PreviewKey, takenAt instant: ContinuousClock.Instant) -> Bool {
        if let shown = takenAt[key], shown >= instant { return false }
        takenAt[key] = instant
        return true
    }

    /// Forgets the windows that are gone.
    mutating func keep(_ keys: Set<PreviewKey>) {
        takenAt = takenAt.filter { keys.contains($0.key) }
    }
}
