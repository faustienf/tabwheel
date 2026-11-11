import AppKit
import ScreenCaptureKit

/// What a preview pictures.
enum PreviewKey: Hashable {
    /// A window on the current Space — the one switching would bring up.
    case window(CGWindowID)
    /// An app with no window on the current Space: a stand-in picture of one from elsewhere.
    case app(pid_t)
}

/// Screenshots of app windows for the hub, via ScreenCaptureKit.
/// Needs Screen Recording permission — without it nothing is captured and the hub
/// shows app icons instead.
///
/// Speed: when the wheel opens, every window on it is captured at once, in parallel, before the
/// user even points anywhere. Results are cached by the model across openings, so from the
/// second ⌘Tab on, a (slightly old) preview shows instantly and the fresh one replaces it.
@MainActor
final class WindowPreviewer {
    private var refreshTask: Task<Void, Never>?

    /// Captures every listed window; an app with no windows here (all on another Space, say)
    /// gets one picture of its biggest window instead. `onImage` gets every result as soon as
    /// it's ready (nil = nothing worth showing).
    func refresh(
        windows: [pid_t: [CGWindowID]],
        maxSize: CGSize,
        onImage: @escaping @MainActor (PreviewKey, CGImage?) -> Void
    ) {
        // No permission → don't even ask (no prompt spam). Already running → let it finish.
        guard CGPreflightScreenCaptureAccess(), refreshTask == nil else { return }

        refreshTask = Task {
            defer { refreshTask = nil }
            let start = ContinuousClock.now

            let content: SCShareableContent
            do {
                content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            } catch {
                log.error("preview: window list failed: \(error.localizedDescription, privacy: .public)")
                return
            }
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
                Task { onImage(target.key, await Self.capture(target.window, maxSize: maxSize)) }
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

    private static func capture(_ window: SCWindow?, maxSize: CGSize) async -> CGImage? {
        guard let window else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        // Capture straight at the size we draw — smaller image, faster capture.
        let fit = min(maxSize.width / window.frame.width, maxSize.height / window.frame.height, 1)
        configuration.width = max(1, Int(window.frame.width * fit * scale))
        configuration.height = max(1, Int(window.frame.height * fit * scale))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
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
