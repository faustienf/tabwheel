import CoreGraphics

/// Starting and stopping are asynchronous: finish retiring one capture before starting another.
@MainActor
protocol PreviewCapture: AnyObject {
    func start() async throws
    func stop() async
}

/// Owns just the selected preview. A new selection invalidates old frames immediately,
/// even while ScreenCaptureKit is still finishing an earlier start/stop operation.
@MainActor
final class LiveWindowPreview {
    typealias Factory = @MainActor (PreviewKey, CGSize, @escaping @MainActor (CGImage) -> Void) async throws -> (any PreviewCapture)?

    private struct Request: Equatable {
        let key: PreviewKey
        let size: CGSize
    }

    private let makeCapture: Factory
    private var request: Request?
    private var generation = 0
    private var transition: Task<Void, Never>?
    private var capture: (any PreviewCapture)?
    var isEnabled = true {
        didSet {
            if !isEnabled { stop() }
        }
    }

    init(makeCapture: @escaping Factory) {
        self.makeCapture = makeCapture
    }

    func show(_ key: PreviewKey?, maxSize: CGSize, onImage: @escaping @MainActor (PreviewKey, CGImage) -> Void) {
        guard isEnabled || key == nil else { return }
        let next = key.map { Request(key: $0, size: maxSize) }
        guard next != request else { return }
        request = next
        generation += 1
        let generation = generation
        let previous = transition
        previous?.cancel()

        transition = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            if let old = self.capture {
                self.capture = nil
                await old.stop()
            }
            guard !Task.isCancelled, self.generation == generation, let next else { return }
            do {
                guard let capture = try await self.makeCapture(next.key, next.size, { [weak self] image in
                    guard self?.generation == generation else { return }
                    onImage(next.key, image)
                }) else { return }
                guard !Task.isCancelled, self.generation == generation else {
                    await capture.stop()
                    return
                }
                self.capture = capture
                do {
                    try await capture.start()
                } catch {
                    self.capture = nil
                    let wasCurrent = self.generation == generation
                    if wasCurrent { self.generation += 1 }
                    await capture.stop()
                    if !Task.isCancelled, wasCurrent {
                        log.error("live preview: start failed: \(error.localizedDescription, privacy: .public)")
                    }
                    return
                }
                if Task.isCancelled || self.generation != generation {
                    self.capture = nil
                    await capture.stop()
                }
            } catch {
                if !Task.isCancelled, self.generation == generation {
                    log.error("live preview: setup failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    func stop() {
        show(nil, maxSize: .zero) { _, _ in }
    }
}
