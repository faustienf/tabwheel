import Testing
@testable import CmdTabWheel

/// Screenshots and live frames land out of order; the hub keeps the newest picture.
struct PreviewFreshnessTests {
    private let start = ContinuousClock.now

    private func at(_ milliseconds: Int) -> ContinuousClock.Instant {
        start + .milliseconds(milliseconds)
    }

    /// `accept`, outside `#expect`: the macro can't hold a mutating call.
    private func take(_ freshness: inout PreviewFreshness, _ key: PreviewKey,
                      takenAt instant: ContinuousClock.Instant) -> Bool {
        freshness.accept(key, takenAt: instant)
    }

    @Test func aNewerPictureReplacesAnOlderOne() {
        var freshness = PreviewFreshness()
        #expect(take(&freshness, .window(1), takenAt: at(0)))
        #expect(take(&freshness, .window(1), takenAt: at(100)))
    }

    @Test func aScreenshotFinishingAfterALiveFrameIsDropped() {
        var freshness = PreviewFreshness()
        let screenshotStarted = at(0)
        #expect(take(&freshness, .window(1), takenAt: at(50))) // the live frame
        #expect(!take(&freshness, .window(1), takenAt: screenshotStarted))
    }

    @Test func eachWindowCountsOnItsOwn() {
        var freshness = PreviewFreshness()
        #expect(take(&freshness, .window(1), takenAt: at(100)))
        #expect(take(&freshness, .window(2), takenAt: at(0)))
        #expect(take(&freshness, .app(1), takenAt: at(0)))
    }

    @Test func goneWindowsAreForgotten() {
        var freshness = PreviewFreshness()
        #expect(take(&freshness, .window(1), takenAt: at(100)))
        #expect(take(&freshness, .window(2), takenAt: at(100)))
        freshness.keep([.window(2)])
        #expect(take(&freshness, .window(1), takenAt: at(0)))
        #expect(!take(&freshness, .window(2), takenAt: at(0)))
    }
}
