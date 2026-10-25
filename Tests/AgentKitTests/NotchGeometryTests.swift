import Foundation
import XCTest
@testable import AgentKit

final class NotchGeometryTests: XCTestCase {
    /// 14 インチ MacBook Pro（1512 × 982 pt）相当。
    private let notched = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
        safeAreaTop: 38,
        auxiliaryTopLeftWidth: 664,
        auxiliaryTopRightWidth: 664
    )

    /// 主画面の右に置いた外部ディスプレイ（ノッチ無し）。
    private let external = ScreenMetrics(
        frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1415)
    )

    func testNotchSizeFromAuxiliaryAreas() {
        let geometry = NotchGeometry(screen: notched)
        XCTAssertTrue(geometry.hasNotch)
        XCTAssertEqual(geometry.notchRect, CGRect(x: 664, y: 944, width: 184, height: 38))
    }

    func testNotchWidthFallsBackWhenAuxiliaryAreasAreMissing() {
        var screen = notched
        screen.auxiliaryTopLeftWidth = nil
        let geometry = NotchGeometry(screen: screen)
        XCTAssertEqual(geometry.notchRect.width, NotchGeometry.fallbackNotchWidth)
        XCTAssertEqual(geometry.notchRect.midX, 756)
    }

    func testScreenWithoutNotchUsesMenuBarHeightAtTopCenter() {
        let geometry = NotchGeometry(screen: external)
        XCTAssertFalse(geometry.hasNotch)
        XCTAssertEqual(geometry.notchRect.width, 0)
        XCTAssertEqual(geometry.notchRect.height, 25)
        XCTAssertEqual(geometry.notchRect.midX, 1512 + 1280)
        XCTAssertEqual(geometry.notchRect.maxY, 1440)
    }

    func testHiddenMenuBarFallsBackToDefaultHeight() {
        var screen = external
        screen.visibleFrame = screen.frame
        XCTAssertEqual(NotchGeometry(screen: screen).notchRect.height, NotchGeometry.fallbackBarHeight)
    }

    func testDisplayChoicePrefersNotchedScreen() {
        // 外部ディスプレイがメインでも、自動ならノッチのある画面を選ぶ。
        XCTAssertEqual(DisplayChoice.automatic.screenIndex(in: [external, notched]), 1)
        XCTAssertEqual(DisplayChoice.main.screenIndex(in: [external, notched]), 0)
        XCTAssertEqual(DisplayChoice.automatic.screenIndex(in: [external]), 0)
        XCTAssertNil(DisplayChoice.automatic.screenIndex(in: []))
    }
}

final class NotchLayoutTests: XCTestCase {
    private let notchedGeometry = NotchGeometry(
        hasNotch: true,
        notchRect: CGRect(x: 664, y: 944, width: 184, height: 38),
        screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982)
    )
    private let plainGeometry = NotchGeometry(
        hasNotch: false,
        notchRect: CGRect(x: 1280, y: 1415, width: 0, height: 25),
        screenFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440)
    )

    func testCharacterKeepsViewBoxAspectAndFitsBarHeight() {
        let layout = NotchLayout(geometry: notchedGeometry)
        XCTAssertEqual(layout.characterSize.height, 38)
        XCTAssertEqual(layout.characterSize.width / layout.characterSize.height, 1.4, accuracy: 0.0001)
    }

    func testCharacterSitsInLeftWingOutsideTheNotch() {
        let layout = NotchLayout(geometry: notchedGeometry)
        let character = layout.characterFrame
        let island = layout.islandFrame(for: .character)
        XCTAssertLessThanOrEqual(character.maxX, notchedGeometry.notchRect.minX)
        XCTAssertGreaterThanOrEqual(character.minX, island.minX)
        XCTAssertEqual(character.maxY, 982)
        XCTAssertEqual(island.midX, notchedGeometry.notchRect.midX)
    }

    func testCharacterIsCenteredWithoutNotch() {
        let layout = NotchLayout(geometry: plainGeometry)
        XCTAssertEqual(layout.characterFrame.midX, 1280, accuracy: 0.0001)
        XCTAssertEqual(layout.islandFrame(for: .character).width, layout.wingWidth)
    }

    func testCharacterDoesNotMoveBetweenStates() {
        // characterFrame は状態に依存しないが、どの状態の島にも収まることを確かめる。
        let layout = NotchLayout(geometry: notchedGeometry)
        for state in NotchPresentationState.allCases {
            let island = layout.islandFrame(for: state)
            XCTAssertTrue(island.contains(layout.characterFrame), "\(state)")
        }
    }

    func testIslandsGrowAndFitInPanel() {
        let layout = NotchLayout(geometry: notchedGeometry)
        let character = layout.islandSize(for: .character)
        let peek = layout.islandSize(for: .peek)
        let expanded = layout.islandSize(for: .expanded)
        XCTAssertGreaterThan(peek.height, character.height)
        XCTAssertGreaterThan(expanded.height, peek.height)
        XCTAssertGreaterThanOrEqual(expanded.width, peek.width)
        for state in NotchPresentationState.allCases {
            XCTAssertTrue(layout.panelFrame.contains(layout.islandFrame(for: state)), "\(state)")
        }
        XCTAssertEqual(layout.panelFrame.maxY, 982)
        XCTAssertEqual(layout.panelFrame.midX, notchedGeometry.notchRect.midX)
    }

    func testHoverFrameAddsMarginOnlyWithNotch() {
        let notched = NotchLayout(geometry: notchedGeometry)
        let island = notched.islandFrame(for: .character)
        let hover = notched.hoverFrame(for: .character)
        XCTAssertEqual(hover.minX, island.minX - NotchLayout.hoverMargin)
        XCTAssertEqual(hover.minY, island.minY - NotchLayout.hoverMargin)
        XCTAssertEqual(hover.maxY, island.maxY)

        let plain = NotchLayout(geometry: plainGeometry)
        XCTAssertEqual(plain.hoverFrame(for: .character), plain.islandFrame(for: .character))
    }

    func testEyeCenterMatchesViewBox() {
        let layout = NotchLayout(geometry: notchedGeometry)
        let frame = layout.characterFrame
        // viewBox の (70, 56) = 横は中央、縦は上から 56 %。
        XCTAssertEqual(layout.eyeCenter.x, frame.midX, accuracy: 0.0001)
        XCTAssertEqual(layout.eyeCenter.y, frame.maxY - frame.height * 0.56, accuracy: 0.0001)
    }
}
