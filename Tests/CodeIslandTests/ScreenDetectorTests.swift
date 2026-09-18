import AppKit
import XCTest
@testable import CodeIsland

final class ScreenDetectorTests: XCTestCase {
    func testMouseDownWinsOverStaleFocusUntilWindowServerSettles() {
        let clicked = CGPoint(x: 1800, y: 300)
        let screens = [
            ScreenDetector.Candidate(frame: CGRect(x: 0, y: 0, width: 1500, height: 1000), hasNotch: true, isMain: true),
            ScreenDetector.Candidate(frame: CGRect(x: 1500, y: 0, width: 1920, height: 1080), hasNotch: false, isMain: false)
        ]
        let oldWindow = CGRect(x: 100, y: 100, width: 500, height: 400)
        let newWindow = CGRect(x: 1600, y: 100, width: 500, height: 400)
        for time in [10.0, 10.1, 10.49] {
            let point = ScreenDetector.recentClickPoint((clicked, 10), now: time)
            XCTAssertEqual(ScreenDetector.autoPreferredIndex(candidates: screens, activeWindowBounds: oldWindow, desktopPoint: point), 1)
        }
        let settled = ScreenDetector.recentClickPoint((clicked, 10), now: 10.5)
        XCTAssertNil(settled)
        XCTAssertEqual(ScreenDetector.autoPreferredIndex(candidates: screens, activeWindowBounds: newWindow, desktopPoint: settled), 1)
        // Subsequent keyboard/window movement is no longer pinned to the old click.
        XCTAssertEqual(ScreenDetector.autoPreferredIndex(candidates: screens, activeWindowBounds: oldWindow, desktopPoint: settled), 0)
    }

    func testDesktopClickOverridesUnrelatedWindowAndUsesAppKitCoordinates() {
        let screens = [
            ScreenDetector.Candidate(frame: CGRect(x: 0, y: 0, width: 1500, height: 1000), hasNotch: true, isMain: true),
            ScreenDetector.Candidate(frame: CGRect(x: 0, y: 1000, width: 1920, height: 1080), hasNotch: false, isMain: false)
        ]
        let finder = CGRect(x: 100, y: 100, width: 500, height: 400)
        XCTAssertEqual(ScreenDetector.autoPreferredIndex(candidates: screens, activeWindowBounds: finder, desktopPoint: CGPoint(x: 800, y: 1500)), 1)
        XCTAssertEqual(ScreenDetector.autoPreferredIndex(candidates: screens, activeWindowBounds: finder), 0)
        let upperWindow = ScreenDetector.appKitBounds(CGRect(x: 100, y: -700, width: 500, height: 400), primaryHeight: 1000)
        XCTAssertEqual(upperWindow.minY, 1300)
        XCTAssertEqual(ScreenDetector.autoPreferredIndex(candidates: screens, activeWindowBounds: upperWindow), 1)
    }

    func testAutoPreferredIndexUsesActiveWorkScreenBeforeBuiltInScreen() {
        let candidates = [
            ScreenDetector.Candidate(
                frame: NSRect(x: 0, y: 0, width: 1512, height: 982),
                hasNotch: true,
                isMain: true
            ),
            ScreenDetector.Candidate(
                frame: NSRect(x: 1512, y: 0, width: 1920, height: 1080),
                hasNotch: false,
                isMain: false
            )
        ]

        let index = ScreenDetector.autoPreferredIndex(
            candidates: candidates,
            activeWindowBounds: NSRect(x: 1800, y: 100, width: 1000, height: 800)
        )

        XCTAssertEqual(index, 1)
    }

    func testAutoPreferredIndexFallsBackToBuiltInScreenWhenNoActiveWorkScreenExists() {
        let candidates = [
            ScreenDetector.Candidate(
                frame: NSRect(x: 0, y: 0, width: 1512, height: 982),
                hasNotch: true,
                isMain: false
            ),
            ScreenDetector.Candidate(
                frame: NSRect(x: 1512, y: 0, width: 1920, height: 1080),
                hasNotch: false,
                isMain: true
            )
        ]

        let index = ScreenDetector.autoPreferredIndex(
            candidates: candidates,
            activeWindowBounds: nil
        )

        XCTAssertEqual(index, 0)
    }

    func testAutoPreferredIndexFallsBackToMainScreenWhenNoBuiltInScreenExists() {
        let candidates = [
            ScreenDetector.Candidate(
                frame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
                hasNotch: false,
                isMain: false
            ),
            ScreenDetector.Candidate(
                frame: NSRect(x: 1920, y: 0, width: 1920, height: 1080),
                hasNotch: false,
                isMain: true
            )
        ]

        let index = ScreenDetector.autoPreferredIndex(
            candidates: candidates,
            activeWindowBounds: nil
        )

        XCTAssertEqual(index, 1)
    }
}
