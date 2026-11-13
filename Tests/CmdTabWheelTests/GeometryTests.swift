import CoreGraphics
import Testing
@testable import CmdTabWheel

/// Slots around the wheel: SwiftUI coordinates (y down), slot 0 at 12 o'clock, then clockwise.
struct GeometryTests {
    @Test func slotZeroIsAtTwelveOClock() {
        #expect(WheelGeometry.index(at: -.pi / 2, count: 4) == 0)
    }

    @Test func slotsGoClockwise() {
        // With y pointing down, angle 0 is 3 o'clock and π/2 is 6 o'clock.
        #expect(WheelGeometry.index(at: 0, count: 4) == 1)
        #expect(WheelGeometry.index(at: .pi / 2, count: 4) == 2)
        #expect(WheelGeometry.index(at: .pi, count: 4) == 3)
    }

    @Test(arguments: 1...12)
    func everySlotsMiddlePointsBackAtIt(count: Int) {
        for index in 0..<count {
            #expect(WheelGeometry.index(at: WheelGeometry.angle(of: index, count: count), count: count) == index)
        }
    }

    @Test func aSlotReachesHalfwayToItsNeighbours() {
        let half = WheelGeometry.sectorAngle(count: 6) / 2
        let top = WheelGeometry.angle(of: 0, count: 6)
        #expect(WheelGeometry.index(at: top + half * 0.99, count: 6) == 0)
        #expect(WheelGeometry.index(at: top - half * 0.99, count: 6) == 0)
        #expect(WheelGeometry.index(at: top + half * 1.01, count: 6) == 1)
        #expect(WheelGeometry.index(at: top - half * 1.01, count: 6) == 5)
    }

    @Test func iconsShrinkWhenCrowdedButNeverGrowPastSixty() {
        let layout = WheelLayout.standard
        #expect(layout.iconSize(count: 0) == 0)
        #expect(layout.iconSize(count: 3) == 60)
        #expect(layout.iconSize(count: 30) < layout.iconSize(count: 10))
    }

    @Test(arguments: [3, 8, 13])
    func theCloseButtonSitsOnTheRailAndIsPartOfIt(count: Int) {
        let layout = WheelLayout.standard
        for index in 0..<count {
            let center = layout.closeButtonCenter(index: index, count: count)
            #expect(abs(hypot(center.x, center.y) - layout.actionRailRadius) < 0.001)
            #expect(layout.actionRailContains(center, index: index, count: count))
            // The opposite side of the wheel is not.
            #expect(!layout.actionRailContains(CGPoint(x: -center.x, y: -center.y), index: index, count: count))
        }
    }
}
