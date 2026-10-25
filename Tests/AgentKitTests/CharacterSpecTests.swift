import Foundation
import XCTest
@testable import AgentKit

final class EyeTrackingTests: XCTestCase {
    private let eye = CGPoint(x: 100, y: 500)

    func testCursorOnTheEyeDoesNotMove() {
        XCTAssertEqual(EyeTracking.offset(eyeCenter: eye, cursor: eye), .zero)
    }

    func testFarCursorReachesMaximum() {
        let right = EyeTracking.offset(eyeCenter: eye, cursor: CGPoint(x: 1000, y: 500))
        XCTAssertEqual(right.dx, EyeTracking.maxHorizontal, accuracy: 0.0001)
        XCTAssertEqual(right.dy, 0, accuracy: 0.0001)

        let left = EyeTracking.offset(eyeCenter: eye, cursor: CGPoint(x: -1000, y: 500))
        XCTAssertEqual(left.dx, -EyeTracking.maxHorizontal, accuracy: 0.0001)
    }

    func testDownwardMovesMoreThanUpward() {
        // グローバル座標は y が上向きなので、y が小さいほど画面の下。
        let below = EyeTracking.offset(eyeCenter: eye, cursor: CGPoint(x: 100, y: 0))
        XCTAssertEqual(below.dy, EyeTracking.maxDown, accuracy: 0.0001)

        let above = EyeTracking.offset(eyeCenter: eye, cursor: CGPoint(x: 100, y: 1000))
        XCTAssertEqual(above.dy, -EyeTracking.maxUp, accuracy: 0.0001)
    }

    func testMovementScalesWithDistanceUntil220Points() {
        let near = EyeTracking.offset(eyeCenter: eye, cursor: CGPoint(x: 210, y: 500))
        XCTAssertEqual(near.dx, EyeTracking.maxHorizontal * 0.5, accuracy: 0.0001)
        let edge = EyeTracking.offset(eyeCenter: eye, cursor: CGPoint(x: 320, y: 500))
        XCTAssertEqual(edge.dx, EyeTracking.maxHorizontal, accuracy: 0.0001)
    }

    func testSmallChangesDoNotRedraw() {
        let a = EyeOffset(dx: 1, dy: 1)
        XCTAssertFalse(EyeTracking.needsRedraw(from: a, to: EyeOffset(dx: 1.1, dy: 0.9)))
        XCTAssertTrue(EyeTracking.needsRedraw(from: a, to: EyeOffset(dx: 1.3, dy: 1)))
    }
}

final class CharacterAnimationTests: XCTestCase {
    func testIdleBreathingStaysWithinSpec() {
        var minScaleY: CGFloat = 1
        var maxScaleX: CGFloat = 1
        for step in 0..<360 {
            let pose = CharacterAnimation.pose(for: .idle, at: Double(step) * 0.01)
            minScaleY = min(minScaleY, pose.scaleY)
            maxScaleX = max(maxScaleX, pose.scaleX)
        }
        XCTAssertEqual(maxScaleX, 1.04, accuracy: 0.001)
        XCTAssertEqual(minScaleY, 0.95, accuracy: 0.001)
    }

    func testBlinkHappensOncePerInterval() {
        XCTAssertLessThan(CharacterAnimation.blinkOpenness(at: 0.09), 0.3)
        XCTAssertEqual(CharacterAnimation.blinkOpenness(at: 1), 1)
        XCTAssertLessThan(CharacterAnimation.blinkOpenness(at: 4.5 + 0.09), 0.3)
    }

    func testIdleBlinkIsVisibleAtIdleFrameRate() {
        // 待機中の描画間隔でも、まばたきが少なくとも 1 フレームは描かれる。
        let interval = CharacterAnimation.frameInterval(for: .idle)!
        XCTAssertLessThan(interval, CharacterAnimation.blinkDuration / 2)
    }

    func testWaitingHopsUpAndLands() {
        let top = CharacterAnimation.pose(for: .waiting, at: 1.2 * 0.2)
        XCTAssertEqual(top.offsetY, -10, accuracy: 0.001)
        let landed = CharacterAnimation.pose(for: .waiting, at: 1.2 * 0.7)
        XCTAssertEqual(landed.offsetY, 0)
    }

    func testDoneSwaysThreeDegrees() {
        let quarter = CharacterAnimation.pose(for: .done, at: CharacterAnimation.swayPeriod / 4)
        XCTAssertEqual(quarter.rotationDegrees, 3, accuracy: 0.001)
    }

    func testErrorIsSquashedAndStatic() {
        XCTAssertNil(CharacterAnimation.frameInterval(for: .error))
        let a = CharacterAnimation.pose(for: .error, at: 0)
        let b = CharacterAnimation.pose(for: .error, at: 1.234)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.scaleY, 0.9)
    }

    func testReduceMotionStopsMovement() {
        for mood in CharacterMood.allCases where mood != .error {
            for time in [0.1, 0.5, 1.3, 2.0] {
                XCTAssertEqual(CharacterAnimation.pose(for: mood, at: time, reduceMotion: true), .neutral, "\(mood)")
            }
        }
    }

    func testNegativeTimeIsHandled() {
        let pose = CharacterAnimation.pose(for: .idle, at: -0.9)
        XCTAssertTrue(pose.scaleX >= 1 && pose.scaleX <= 1.04)
    }
}

final class CharacterSpecTests: XCTestCase {
    func testBodyIsClosedAndFitsViewBox() {
        let segments = CharacterSpec.bodySegments
        guard case .move(let start) = segments.first, case .curve(let end, _, _) = segments.last else {
            return XCTFail("輪郭は move で始まり curve で終わる")
        }
        XCTAssertEqual(start, end)
        for segment in segments {
            let points: [CGPoint]
            switch segment {
            case .move(let p), .line(let p): points = [p]
            case .curve(let p, let c1, let c2): points = [p, c1, c2]
            }
            for p in points {
                XCTAssertTrue((0...CharacterSpec.viewBoxWidth).contains(p.x))
                XCTAssertTrue((0...CharacterSpec.viewBoxHeight).contains(p.y))
            }
        }
    }

    func testEyesAreSymmetric() {
        XCTAssertEqual(CharacterSpec.eyesMidpoint, CGPoint(x: 70, y: 56))
    }
}
