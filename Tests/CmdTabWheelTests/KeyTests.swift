import CoreGraphics
import Testing
@testable import CmdTabWheel

/// ⌘W and ⌘Q are matched the way macOS matches ⌘-shortcuts: by what the key types in the
/// current layout, and by the US position for layouts without Latin letters.
struct LetterTests {
    @Test func usLayout() {
        #expect(KeyCode.latinLetter(keyCode: 13, character: "w") == "w")
    }

    @Test func layoutsWithoutLatinLettersGoByPosition() {
        #expect(KeyCode.latinLetter(keyCode: 13, character: "ц") == "w") // Russian
        #expect(KeyCode.latinLetter(keyCode: 12, character: "й") == "q")
    }

    @Test func otherLatinLayoutsGoByWhatTheKeyTypes() {
        // AZERTY: W is where US has Z, and the US W spot types Z.
        #expect(KeyCode.latinLetter(keyCode: 6, character: "w") == "w")
        #expect(KeyCode.latinLetter(keyCode: 13, character: "z") == "z")
        #expect(KeyCode.latinLetter(keyCode: 0, character: "q") == "q")
    }
}

/// The keyboard side of the wheel: which key events turn into what, and which are swallowed.
@MainActor
struct InterceptorTests {
    private let tab: Int64 = 48, escape: Int64 = 53, w: Int64 = 13, q: Int64 = 12, other: Int64 = 0

    private final class Recorder {
        var inputs: [WheelInput] = []
    }

    private func makeInterceptor() -> (CommandTabInterceptor, Recorder) {
        let interceptor = CommandTabInterceptor()
        let recorder = Recorder()
        interceptor.onInput = { recorder.inputs.append($0) }
        return (interceptor, recorder)
    }

    /// Returns whether the event is passed on to the app below.
    @discardableResult
    private func press(_ interceptor: CommandTabInterceptor, _ keyCode: Int64, _ flags: CGEventFlags = .maskCommand,
                       up: Bool = false, character: String? = nil, isRepeat: Bool = false) -> Bool {
        interceptor.handle(type: up ? .keyUp : .keyDown, keyCode: keyCode, flags: flags,
                           character: character, isRepeat: isRepeat)
    }

    private func release(_ interceptor: CommandTabInterceptor) -> Bool {
        interceptor.handle(type: .flagsChanged, keyCode: 55, flags: [], character: nil, isRepeat: false)
    }

    @Test func commandTabOpensTabStepsReleasingCommits() {
        let (interceptor, recorder) = makeInterceptor()
        #expect(!press(interceptor, tab))
        #expect(!press(interceptor, tab, up: true))
        #expect(!press(interceptor, tab))
        #expect(!press(interceptor, tab, [.maskCommand, .maskShift]))
        #expect(release(interceptor))
        #expect(recorder.inputs == [.open, .step(backward: false), .step(backward: true), .commit])
    }

    @Test func escapeCancels() {
        let (interceptor, recorder) = makeInterceptor()
        press(interceptor, tab)
        #expect(!press(interceptor, escape, []))
        #expect(recorder.inputs == [.open, .cancel])
        // ⌘ released after that is not a commit.
        _ = release(interceptor)
        #expect(recorder.inputs == [.open, .cancel])
    }

    @Test func commandWAndQActOnTheWheelAndNeverReachTheAppBelow() {
        let (interceptor, recorder) = makeInterceptor()
        press(interceptor, tab)
        #expect(!press(interceptor, w, character: "w"))
        #expect(!press(interceptor, w, up: true, character: "w"))
        #expect(!press(interceptor, q, character: "й"))
        #expect(recorder.inputs == [.open, .closeWindow, .quitApp])
    }

    @Test func holdingWDoesNotCloseWindowAfterWindow() {
        let (interceptor, recorder) = makeInterceptor()
        press(interceptor, tab)
        press(interceptor, w, character: "w")
        #expect(!press(interceptor, w, character: "w", isRepeat: true))
        #expect(recorder.inputs == [.open, .closeWindow])
    }

    @Test func withoutTheWheelEverythingPassesThrough() {
        let (interceptor, recorder) = makeInterceptor()
        #expect(press(interceptor, w, character: "w"))
        #expect(press(interceptor, other, [], character: "a"))
        #expect(press(interceptor, escape, []))
        #expect(recorder.inputs.isEmpty)
    }

    @Test func otherKeysWhileTheWheelIsOpenPassThrough() {
        let (interceptor, recorder) = makeInterceptor()
        press(interceptor, tab)
        #expect(press(interceptor, other, character: "a"))
        #expect(recorder.inputs == [.open])
    }
}
