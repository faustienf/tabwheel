import AppKit
import Testing
@testable import CmdTabWheel

@MainActor
struct LiveWindowPreviewTests {
    private let size = CGSize(width: 304, height: 190)

    @MainActor
    private final class Recorder {
        var events: [String] = []
        var captures: [Capture] = []
        var received: [PreviewKey] = []
        var active = 0
        var maximumActive = 0

        func make(_ key: PreviewKey, onImage: @escaping @MainActor (CGImage) -> Void) -> Capture {
            let capture = Capture(key: key, recorder: self, onImage: onImage)
            captures.append(capture)
            return capture
        }
    }

    private enum Failure: Error { case start }

    private final class Capture: PreviewCapture {
        let key: PreviewKey
        unowned let recorder: Recorder
        let onImage: @MainActor (CGImage) -> Void
        var pauseStart = false
        var failsStart = false
        var startGate: CheckedContinuation<Void, Never>?
        var running = false

        init(key: PreviewKey, recorder: Recorder, onImage: @escaping @MainActor (CGImage) -> Void) {
            self.key = key
            self.recorder = recorder
            self.onImage = onImage
        }

        func start() async throws {
            recorder.events.append("start \(key)")
            running = true
            recorder.active += 1
            recorder.maximumActive = max(recorder.maximumActive, recorder.active)
            if pauseStart { await withCheckedContinuation { startGate = $0 } }
            if failsStart { throw Failure.start }
        }

        func stop() async {
            recorder.events.append("stop \(key)")
            if running { recorder.active -= 1; running = false }
        }

        func finishStart() {
            startGate?.resume()
            startGate = nil
        }
    }

    private func image() -> CGImage {
        CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }

    @Test func movingWithinTheSameSectorDoesNotRestartCapture() async {
        let recorder = Recorder()
        let live = LiveWindowPreview { key, _, onImage in recorder.make(key, onImage: onImage) }
        for _ in 0..<20 {
            live.show(.window(1), maxSize: size) { key, _ in recorder.received.append(key) }
        }
        #expect(await waitUntil { recorder.active == 1 })
        #expect(recorder.captures.count == 1)
        recorder.captures[0].onImage(image())
        #expect(recorder.received == [.window(1)])
        live.stop()
        #expect(await waitUntil { recorder.active == 0 })
    }

    @Test func changingWindowsRetiresTheOldStreamAndRejectsItsLateFrames() async {
        let recorder = Recorder()
        let live = LiveWindowPreview { key, _, onImage in recorder.make(key, onImage: onImage) }
        live.show(.window(1), maxSize: size) { key, _ in recorder.received.append(key) }
        #expect(await waitUntil { recorder.active == 1 })
        let first = recorder.captures[0]
        first.onImage(image())
        live.show(.window(2), maxSize: size) { key, _ in recorder.received.append(key) }
        first.onImage(image()) // before the asynchronous stop even runs
        #expect(recorder.received == [.window(1)])
        #expect(await waitUntil { recorder.captures.count == 2 && recorder.active == 1 })
        recorder.captures[1].onImage(image())
        first.onImage(image())
        #expect(recorder.received == [.window(1), .window(2)])
        #expect(recorder.events == ["start window(1)", "stop window(1)", "start window(2)"])
        #expect(recorder.maximumActive == 1)
        live.stop()
        #expect(await waitUntil { recorder.active == 0 })
    }

    @Test func closingWhileCaptureStartsStopsItAsSoonAsStartingFinishes() async {
        let recorder = Recorder()
        let live = LiveWindowPreview { key, _, onImage in
            let capture = recorder.make(key, onImage: onImage)
            capture.pauseStart = true
            return capture
        }
        live.show(.window(1), maxSize: size) { key, _ in recorder.received.append(key) }
        #expect(await waitUntil { recorder.captures.first?.startGate != nil })
        live.stop()
        recorder.captures[0].onImage(image())
        #expect(recorder.received.isEmpty)
        recorder.captures[0].finishStart()
        #expect(await waitUntil { recorder.active == 0 })
        #expect(recorder.events == ["start window(1)", "stop window(1)"])
    }

    @Test func rapidChangesSkipIntermediateWindowsWithoutOverlappingStreams() async {
        let recorder = Recorder()
        let live = LiveWindowPreview { key, _, onImage in
            let capture = recorder.make(key, onImage: onImage)
            capture.pauseStart = key == .window(1)
            return capture
        }
        live.show(.window(1), maxSize: size) { _, _ in }
        #expect(await waitUntil { recorder.captures.first?.startGate != nil })
        live.show(.window(2), maxSize: size) { _, _ in }
        live.show(.window(3), maxSize: size) { key, _ in recorder.received.append(key) }
        recorder.captures[0].finishStart()
        #expect(await waitUntil { recorder.captures.count == 2 && recorder.active == 1 })
        #expect(recorder.captures.map(\.key) == [.window(1), .window(3)])
        #expect(recorder.maximumActive == 1)
        recorder.captures[1].onImage(image())
        #expect(recorder.received == [.window(3)])
        live.stop()
        #expect(await waitUntil { recorder.active == 0 })
    }

    @Test func reopeningTheSameWindowDoesNotAcceptFramesFromThePreviousOpening() async {
        let recorder = Recorder()
        let live = LiveWindowPreview { key, _, onImage in recorder.make(key, onImage: onImage) }
        live.show(.window(1), maxSize: size) { key, _ in recorder.received.append(key) }
        #expect(await waitUntil { recorder.active == 1 })
        let old = recorder.captures[0]
        live.stop()
        live.show(.window(1), maxSize: size) { key, _ in recorder.received.append(key) }
        old.onImage(image())
        #expect(await waitUntil { recorder.captures.count == 2 && recorder.active == 1 })
        recorder.captures[1].onImage(image())
        #expect(recorder.received == [.window(1)])
        #expect(recorder.maximumActive == 1)
        live.stop()
        #expect(await waitUntil { recorder.active == 0 })
    }

    @Test func anEmptyHubStopsCaptureAndNeedsNoReplacementStream() async {
        let recorder = Recorder()
        let live = LiveWindowPreview { key, _, onImage in recorder.make(key, onImage: onImage) }
        live.show(.window(1), maxSize: size) { key, _ in recorder.received.append(key) }
        #expect(await waitUntil { recorder.active == 1 })
        live.show(nil, maxSize: size) { _, _ in }
        recorder.captures[0].onImage(image())
        #expect(await waitUntil { recorder.active == 0 })
        #expect(recorder.received.isEmpty)
        #expect(recorder.captures.count == 1)
    }

    @Test func aFailedStartIsCleanedUpAndTheNextWindowStillWorks() async {
        let recorder = Recorder()
        let live = LiveWindowPreview { key, _, onImage in
            let capture = recorder.make(key, onImage: onImage)
            capture.failsStart = key == .window(1)
            return capture
        }
        live.show(.window(1), maxSize: size) { key, _ in recorder.received.append(key) }
        #expect(await waitUntil { recorder.events.count == 2 && recorder.active == 0 })
        recorder.captures[0].onImage(image())
        #expect(recorder.received.isEmpty)
        live.show(.app(20), maxSize: size) { key, _ in recorder.received.append(key) }
        #expect(await waitUntil { recorder.captures.count == 2 && recorder.active == 1 })
        recorder.captures[1].onImage(image())
        #expect(recorder.received == [.app(20)])
        live.stop()
        #expect(await waitUntil { recorder.active == 0 })
    }

    @Test func aMissingWindowKeepsTheCachedPreviewAndDoesNotStartCapture() async {
        var attempts = 0
        var delivered = false
        let live = LiveWindowPreview { _, _, _ in attempts += 1; return nil }
        live.show(.window(999), maxSize: size) { _, _ in delivered = true }
        #expect(await waitUntil { attempts == 1 })
        #expect(!delivered)
        live.stop()
    }

    @Test func anObsoleteLookupCannotStartCaptureAfterTheSelectionChanges() async {
        let recorder = Recorder()
        var lookupGate: CheckedContinuation<Void, Never>?
        let live = LiveWindowPreview { key, _, onImage in
            if key == .window(1) { await withCheckedContinuation { lookupGate = $0 } }
            return recorder.make(key, onImage: onImage)
        }
        live.show(.window(1), maxSize: size) { key, _ in recorder.received.append(key) }
        #expect(await waitUntil { lookupGate != nil })
        live.show(.window(2), maxSize: size) { key, _ in recorder.received.append(key) }
        lookupGate?.resume()
        #expect(await waitUntil { recorder.captures.count == 2 && recorder.active == 1 })
        #expect(recorder.events == ["stop window(1)", "start window(2)"])
        recorder.captures[0].onImage(image())
        recorder.captures[1].onImage(image())
        #expect(recorder.received == [.window(2)])
        live.stop()
        #expect(await waitUntil { recorder.active == 0 })
    }

    @Test func disablingLivePreviewPreventsCaptureUntilItIsEnabled() async {
        let recorder = Recorder()
        let live = LiveWindowPreview { key, _, onImage in recorder.make(key, onImage: onImage) }
        live.isEnabled = false
        live.show(.window(1), maxSize: size) { key, _ in recorder.received.append(key) }
        #expect(recorder.captures.isEmpty)
        live.isEnabled = true
        live.show(.window(1), maxSize: size) { key, _ in recorder.received.append(key) }
        #expect(await waitUntil { recorder.active == 1 })
        live.isEnabled = false
        recorder.captures[0].onImage(image())
        #expect(recorder.received.isEmpty)
        #expect(await waitUntil { recorder.active == 0 })
        live.show(.window(2), maxSize: size) { _, _ in }
        #expect(recorder.captures.count == 1)
    }

    @Test func disablingDuringStartupCancelsItAndReenablingCanRestartTheSameWindow() async {
        let recorder = Recorder()
        let live = LiveWindowPreview { key, _, onImage in
            let capture = recorder.make(key, onImage: onImage)
            capture.pauseStart = recorder.captures.count == 1
            return capture
        }
        live.show(.window(1), maxSize: size) { key, _ in recorder.received.append(key) }
        #expect(await waitUntil { recorder.captures.first?.startGate != nil })
        live.isEnabled = false
        recorder.captures[0].onImage(image())
        recorder.captures[0].finishStart()
        #expect(await waitUntil { recorder.active == 0 })
        #expect(recorder.received.isEmpty)
        live.isEnabled = true
        live.show(.window(1), maxSize: size) { key, _ in recorder.received.append(key) }
        #expect(await waitUntil { recorder.captures.count == 2 && recorder.active == 1 })
        recorder.captures[0].onImage(image())
        recorder.captures[1].onImage(image())
        #expect(recorder.received == [.window(1)])
        #expect(recorder.maximumActive == 1)
        live.stop()
        #expect(await waitUntil { recorder.active == 0 })
    }
}
