import AppKit
import Testing
@testable import CmdTabWheel

private typealias F = Fixture

// MARK: - Sectors

@MainActor
struct SectorTests {
    /// Finder without windows, Safari with three (front to back: 203, 201, 202), Notes with one.
    private func wheel(quickSwitchTo previous: pid_t? = nil) -> WheelModel {
        F.wheel([F.app(1, "Finder"), F.app(2, "Safari"), F.app(3, "Notes")],
                windows: [2: [F.window(203), F.window(201), F.window(202)], 3: [F.window(301)]],
                quickSwitchTo: previous)
    }

    @Test func anAppWithSeveralWindowsGetsASectorPerWindowInCreationOrder() {
        let model = wheel()
        #expect(model.names == ["Finder", "Safari", "Safari", "Safari", "Notes"])
        let safari = model.items.filter { $0.pid == 2 }
        #expect(safari.map { $0.window?.id } == [201, 202, 203])
        #expect(safari.map(\.windowNumber) == [1, 2, 3])
    }

    @Test func eachSectorBringsUpItsOwnWindow() {
        let model = wheel()
        #expect(model.chosenWindow(of: model.items[2])?.id == 202)
        #expect(model.chosenWindow(of: model.items[4])?.id == 301) // Notes' only window
        #expect(model.chosenWindow(of: model.items[0]) == nil)     // Finder has none
    }

    @Test func theHubCountsWindowsOnlyForAppsWithSeveral() {
        let model = wheel()
        #expect(model.windowPosition(of: model.items[2]).map { [$0.index, $0.count] } == [1, 3])
        #expect(model.windowPosition(of: model.items[4]) == nil)
        #expect(model.windowPosition(of: model.items[0]) == nil)
    }

    @Test func windowsOfAppsNotOnTheWheelAreDropped() {
        let model = F.wheel([F.app(1, "Finder")], windows: [9: [F.window(900)]])
        #expect(model.windows[9] == nil)
    }

    @Test func aQuickSwitchGoesToThePreviousAppsFrontWindow() {
        #expect(wheel(quickSwitchTo: 2).quickSwitchItem?.window?.id == 203)
        #expect(wheel(quickSwitchTo: 3).quickSwitchItem?.name == "Notes")
        #expect(wheel().quickSwitchItem == nil)
    }

    @Test func doingAnythingCancelsTheQuickSwitch() {
        let byKeyboard = wheel(quickSwitchTo: 2)
        byKeyboard.step(backward: false)
        #expect(byKeyboard.quickSwitchItem == nil)

        let byMouse = wheel(quickSwitchTo: 2)
        byMouse.point(at: 4)
        #expect(byMouse.quickSwitchItem == nil)
    }

    @Test func previewsOfWindowsThatAreGoneAreDropped() throws {
        let model = wheel()
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        model.setPreview(image, for: .window(301))
        model.setPreview(image, for: .window(201))
        model.load(apps: [F.app(2, "Safari"), F.app(3, "Notes")], windows: [3: [F.window(301)]],
                   pointer: .zero, quickSwitchTo: nil)
        #expect(model.previews[.window(301)] != nil)
        #expect(model.previews[.window(201)] == nil)
    }
}

// MARK: - Pointer and keyboard

@MainActor
struct SelectionTests {
    private func wheel() -> WheelModel {
        F.wheel(["Finder", "Safari", "Notes", "Mail"].enumerated().map { F.app(pid_t($0.offset + 1), $0.element) })
    }

    @Test func nothingIsSelectedWhenTheWheelOpens() {
        #expect(wheel().selectedIndex == nil)
    }

    @Test func aTinyMoveDoesNotCount() {
        let model = wheel()
        model.movePointer(to: CGPoint(x: 1, y: 0))
        #expect(model.selectedIndex == nil)
        #expect(!model.wasTouched)
    }

    @Test func pointingPicksTheSectorInThatDirection() {
        let model = wheel()
        model.point(at: 2)
        #expect(model.selectedItem?.name == "Notes")
        #expect(model.wasTouched)
    }

    @Test func theDirectionCountsFarPastTheRimToo() {
        let model = wheel()
        model.point(at: 3, radius: model.layout.outerRadius + 150)
        #expect(model.selectedItem?.name == "Mail")
    }

    @Test func backInTheHubNothingIsSelected() {
        let model = wheel()
        model.point(at: 1)
        model.movePointer(to: CGPoint(x: 10, y: 10))
        #expect(model.selectedIndex == nil)
    }

    @Test func aClickPicksByDirectionWithoutAnyMoveFirst() {
        let model = wheel()
        #expect(model.item(at: model.point(1, radius: model.layout.outerRadius + 150))?.name == "Safari")
        #expect(model.item(at: CGPoint(x: 10, y: 10)) == nil)
    }

    @Test func tabGoesClockwiseAndShiftTabBack() {
        let model = wheel()
        model.step(backward: false)
        #expect(model.selectedItem?.name == "Finder")
        model.step(backward: false)
        #expect(model.selectedItem?.name == "Safari")

        let backwards = wheel()
        backwards.step(backward: true)
        #expect(backwards.selectedItem?.name == "Mail")
    }

    @Test func tabWrapsAround() {
        let model = wheel()
        for _ in 0..<5 { model.step(backward: false) }
        #expect(model.selectedItem?.name == "Finder")
    }
}

// MARK: - Closing windows and quitting apps

@MainActor
struct ClosingTests {
    /// Finder, Terminal, Safari with windows 201–203, Notes with 401.
    private func wheel() -> WheelModel {
        F.wheel([F.app(1, "Finder"), F.app(2, "Terminal"), F.app(3, "Safari"), F.app(4, "Notes")],
                windows: [3: [F.window(201), F.window(202), F.window(203)], 4: [F.window(401)]])
    }

    @Test func theSelectionStaysOnTheAppWhileClosingItsWindowsOneByOne() throws {
        let model = wheel()
        for _ in 0..<4 { model.step(backward: false) }
        #expect(model.selectedItem?.window?.id == 202)

        model.removeWindow(202, of: 3)
        #expect(model.selectedItem?.window?.id == 203)

        model.removeWindow(203, of: 3)
        // One window left: Safari is one sector again, still selected.
        #expect(model.names == ["Finder", "Terminal", "Safari", "Notes"])
        let selected = try #require(model.selectedItem)
        #expect(selected.name == "Safari")
        #expect(model.chosenWindow(of: selected)?.id == 201)
    }

    @Test func whenAnAppQuitsTheNextOneSlidesIntoItsSlot() {
        let model = wheel()
        for _ in 0..<3 { model.step(backward: false) }
        model.removeWindow(202, of: 3)
        model.removeWindow(203, of: 3)

        model.removeApp(3)
        #expect(model.selectedItem?.name == "Notes")
        #expect(model.windows[3] == nil)

        model.removeApp(4) // the last one in the list: the selection goes to the one before
        #expect(model.selectedItem?.name == "Terminal")

        model.removeApp(99) // not on the wheel
        #expect(model.items.count == 2)
    }

    @Test func withTheMouseThePointerPicksAgainAfterAClose() {
        let model = wheel()
        model.point(at: 3) // Safari #2
        #expect(model.selectedItem?.window?.id == 202)
        let pointer = model.point(3)
        model.removeWindow(202, of: 3)
        let angle = atan2(pointer.y, pointer.x)
        #expect(model.selectedIndex == WheelGeometry.index(at: angle, count: model.items.count))
    }

    @Test func afterClosingReleasingCommandGoesBackInsteadOfSwitching() {
        let model = wheel()
        model.step(backward: false)
        #expect(!model.hasClosedSomething)
        model.removeWindow(999, of: 1)
        #expect(model.hasClosedSomething)
        #expect(model.selectedItem?.name == "Finder")
        // Tab after that is a new pick.
        model.step(backward: false)
        #expect(!model.hasClosedSomething)
    }

    @Test func pointingAtAnotherSectorIsANewPickButANudgeIsNot() {
        let model = wheel()
        model.point(at: 1)
        model.removeWindow(999, of: 2)
        model.point(at: 1, radius: 252, nudge: 0.01)
        #expect(model.hasClosedSomething)
        model.point(at: 0)
        #expect(!model.hasClosedSomething)
    }

    @Test func quittingCountsAsClosingButAnAppQuittingByItselfDoesNot() {
        let quitting = wheel()
        quitting.step(backward: false)
        quitting.step(backward: false)
        quitting.noteQuitRequested()
        quitting.removeApp(2)
        #expect(quitting.selectedItem?.name == "Safari")
        #expect(quitting.hasClosedSomething)

        let byItself = wheel()
        byItself.step(backward: false)
        byItself.removeApp(4)
        #expect(!byItself.hasClosedSomething)
    }

    @Test func resetForgetsAboutIt() {
        let model = wheel()
        model.removeWindow(201, of: 3)
        model.reset()
        #expect(!model.hasClosedSomething)
    }

    @Test func theCloseButtonIsOnlyOnTheSelectedSector() {
        let model = wheel()
        for _ in 0..<4 { model.step(backward: false) } // Safari #2
        let count = model.items.count
        #expect(model.closeTarget(at: model.layout.closeButtonCenter(index: 3, count: count))?.window.id == 202)
        #expect(model.closeTarget(at: model.layout.closeButtonCenter(index: 4, count: count)) == nil)
    }
}

// MARK: - Windows elsewhere

@MainActor
struct WindowsElsewhereTests {
    /// Safari: one window here, one on Desktop 2, one minimized. Notes: one on Desktop 3.
    private func wheel() -> WheelModel {
        F.wheel([F.app(2, "Safari"), F.app(3, "Notes")],
                windows: [2: [F.window(201), F.window(205, .otherDesktop("Desktop 2")), F.window(207, .minimized)],
                          3: [F.window(301, .otherDesktop("Desktop 3"))]])
    }

    @Test func theyGetSectorsLikeAnyOtherWindow() {
        let model = wheel()
        #expect(model.items.map { $0.window?.id } == [201, 205, 207, nil])
        #expect(model.chosenWindow(of: model.items[3])?.place == .otherDesktop("Desktop 3"))
    }

    @Test func onlyWindowsOnAShownDesktopOrMinimizedCanBeClosed() {
        let model = wheel()
        #expect(model.closableWindow(of: model.items[0])?.id == 201)
        #expect(model.closableWindow(of: model.items[1]) == nil)
        #expect(model.closableWindow(of: model.items[2])?.id == 207)
        #expect(model.closableWindow(of: model.items[3]) == nil)
    }

    @Test func aWindowOnAnotherDesktopHasNoCloseButton() {
        let model = wheel()
        model.step(backward: false)
        model.step(backward: false) // Safari on Desktop 2
        #expect(model.closeTarget(at: model.layout.closeButtonCenter(index: 1, count: 4)) == nil)
    }

    @Test func theHubSaysWhereTheWindowIs() {
        #expect(AppWindow.Place.here.label == nil)
        #expect(AppWindow.Place.otherDesktop("Desktop 2").label == "Desktop 2")
        #expect(AppWindow.Place.otherDesktop(nil).label == "Another desktop")
        #expect(AppWindow.Place.minimized.label == "Minimized")
    }

    @Test func aQuickSwitchPrefersAWindowOnScreen() {
        let model = F.wheel([F.app(2, "Safari")],
                            windows: [2: [F.window(201), F.window(205, .otherDesktop("Desktop 2"))]],
                            quickSwitchTo: 2)
        #expect(model.quickSwitchItem?.window?.id == 201)
    }
}
