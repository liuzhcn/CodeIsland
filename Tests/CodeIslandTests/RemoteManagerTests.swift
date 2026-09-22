import XCTest
@testable import CodeIsland

@MainActor
final class RemoteManagerTests: XCTestCase {
    func testRemoteCodexScanAddsAndRemovesActiveSession() {
        let state = AppState()
        let session = RemoteCodexSession(
            id: "remote-codex-test", cwd: "/home/leo/projects/hr", model: "gpt-6-astra",
            title: "Investigate hr", modifiedAt: Date().timeIntervalSince1970,
            startedAt: Date().timeIntervalSince1970
        )
        state.reconcileRemoteCodexSessions([session], hostId: "remote-test", hostName: "server", cwdFilter: "")
        XCTAssertEqual(state.activeSessionCount, 1)
        XCTAssertEqual(state.sessions[session.id]?.remoteHostId, "remote-test")

        state.reconcileRemoteCodexSessions([], hostId: "remote-test", hostName: "server", cwdFilter: "")
        XCTAssertNil(state.sessions[session.id])
        XCTAssertEqual(state.activeSessionCount, 0)
    }

    func testFailedRemoteTurnIsNotRevivedByScan() {
        let state = AppState()
        let started = Date().timeIntervalSince1970 - 10
        let session = RemoteCodexSession(
            id: "failed-remote", cwd: "/home/leo/projects/hr", model: nil,
            title: nil, modifiedAt: started + 5, startedAt: started
        )
        state.reconcileRemoteCodexSessions([session], hostId: "remote-test", hostName: "server", cwdFilter: "")
        state.reconcileCodexFailure(sessionId: session.id, ended: Date(timeIntervalSince1970: started + 6))
        state.reconcileRemoteCodexSessions([session], hostId: "remote-test", hostName: "server", cwdFilter: "")
        XCTAssertEqual(state.sessions[session.id]?.status, .idle)
        XCTAssertEqual(state.activeSessionCount, 0)

        let nextTurn = RemoteCodexSession(
            id: session.id, cwd: session.cwd, model: nil, title: nil,
            modifiedAt: started + 9, startedAt: started + 8
        )
        state.reconcileRemoteCodexSessions([nextTurn], hostId: "remote-test", hostName: "server", cwdFilter: "")
        XCTAssertEqual(state.sessions[session.id]?.status, .running)
        XCTAssertEqual(state.activeSessionCount, 1)
    }

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
