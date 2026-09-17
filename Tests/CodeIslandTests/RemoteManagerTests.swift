import XCTest
@testable import CodeIsland

@MainActor
final class RemoteManagerTests: XCTestCase {
    func testRecoverySkipsManualDisconnectAndInFlightConnections() {
        for status in [SSHForwarder.Status.disconnected, .failed("network down")] {
            XCTAssertTrue(RemoteManager.shouldRetry(autoConnect: true, manuallyDisconnected: false, status: status))
            XCTAssertFalse(RemoteManager.shouldRetry(autoConnect: true, manuallyDisconnected: true, status: status))
            XCTAssertFalse(RemoteManager.shouldRetry(autoConnect: false, manuallyDisconnected: false, status: status))
        }
        for status in [SSHForwarder.Status.connecting, .connected] {
            XCTAssertFalse(RemoteManager.shouldRetry(autoConnect: true, manuallyDisconnected: false, status: status))
        }
    }

    func testReconnectDelayFollowsExpectedBackoff() {
        XCTAssertEqual(RemoteManager.reconnectDelay(attempt: 1), 5)
        XCTAssertEqual(RemoteManager.reconnectDelay(attempt: 2), 15)
        XCTAssertEqual(RemoteManager.reconnectDelay(attempt: 3), 45)
        XCTAssertEqual(RemoteManager.reconnectDelay(attempt: 4), 120)
        XCTAssertEqual(RemoteManager.reconnectDelay(attempt: 5), 300)
    }

    func testReconnectDelayClampsBeyondTable() {
        XCTAssertEqual(RemoteManager.reconnectDelay(attempt: 6), 300)
        XCTAssertEqual(RemoteManager.reconnectDelay(attempt: 100), 300)
    }

    func testReconnectDelayNeverReturnsLessThanFirstStepForBogusInput() {
        XCTAssertEqual(RemoteManager.reconnectDelay(attempt: 0), 5)
        XCTAssertEqual(RemoteManager.reconnectDelay(attempt: -1), 5)
    }
}
