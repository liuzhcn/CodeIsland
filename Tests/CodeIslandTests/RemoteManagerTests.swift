import XCTest
import CodeIslandCore
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
        XCTAssertEqual(state.sessions["remote:remote-test:\(session.id)"]?.remoteHostId, "remote-test")

        state.reconcileRemoteCodexSessions([], hostId: "remote-test", hostName: "server", cwdFilter: "")
        XCTAssertNil(state.sessions["remote:remote-test:\(session.id)"])
        XCTAssertEqual(state.activeSessionCount, 0)
    }

    func testRemoteCodexTitleRecoversAfterAttachmentMetadata() {
        let state = AppState()
        let now = Date().timeIntervalSince1970
        let session = RemoteCodexSession(
            id: "remote-title-test", cwd: "/home/leo/projects/hr", model: nil,
            title: "# Files mentioned by the user:\nimage.png", modifiedAt: now, startedAt: now
        )
        state.reconcileRemoteCodexSessions([session], hostId: "remote-test", hostName: "server", cwdFilter: "")
        XCTAssertNil(state.sessions["remote:remote-test:\(session.id)"]?.sessionLabel)

        let renamed = RemoteCodexSession(
            id: session.id, cwd: session.cwd, model: nil,
            title: "评估前端兼容方案", modifiedAt: now + 1, startedAt: now
        )
        state.reconcileRemoteCodexSessions([renamed], hostId: "remote-test", hostName: "server", cwdFilter: "")
        XCTAssertEqual(state.sessions["remote:remote-test:\(session.id)"]?.sessionLabel, "评估前端兼容方案")
    }

    func testFailedRemoteTurnIsNotRevivedByScan() {
        let state = AppState()
        let started = Date().timeIntervalSince1970 - 10
        let session = RemoteCodexSession(
            id: "failed-remote", cwd: "/home/leo/projects/hr", model: nil,
            title: nil, modifiedAt: started + 5, startedAt: started
        )
        state.reconcileRemoteCodexSessions([session], hostId: "remote-test", hostName: "server", cwdFilter: "")
        state.reconcileCodexFailure(sessionId: "remote:remote-test:\(session.id)", ended: Date(timeIntervalSince1970: started + 6))
        state.reconcileRemoteCodexSessions([session], hostId: "remote-test", hostName: "server", cwdFilter: "")
        XCTAssertEqual(state.sessions["remote:remote-test:\(session.id)"]?.status, .idle)
        XCTAssertEqual(state.activeSessionCount, 0)

        let nextTurn = RemoteCodexSession(
            id: session.id, cwd: session.cwd, model: nil, title: nil,
            modifiedAt: started + 9, startedAt: started + 8
        )
        state.reconcileRemoteCodexSessions([nextTurn], hostId: "remote-test", hostName: "server", cwdFilter: "")
        XCTAssertEqual(state.sessions["remote:remote-test:\(session.id)"]?.status, .running)
        XCTAssertEqual(state.activeSessionCount, 1)
    }

    func testRemoteScanAndHooksShareOneRunningCardInEitherOrder() throws {
        for hookFirst in [false, true] {
            let state = AppState()
            let now = Date().timeIntervalSince1970
            let record = RemoteCodexSession(
                id: "same-thread", cwd: "/remote/project", model: nil,
                title: "Remote task", modifiedAt: now, startedAt: now
            )
            func hook(_ name: String) throws -> HookEvent {
                let data = try JSONSerialization.data(withJSONObject: [
                    "hook_event_name": name, "session_id": record.id,
                    "_source": "codex", "_remote_host_id": "remote-test",
                    "cwd": record.cwd
                ])
                return try XCTUnwrap(HookEvent(from: data))
            }
            if hookFirst { state.handleEvent(try hook("UserPromptSubmit")) }
            state.reconcileRemoteCodexSessions([record], hostId: "remote-test", hostName: "server", cwdFilter: "")
            if !hookFirst { state.handleEvent(try hook("UserPromptSubmit")) }
            XCTAssertEqual(state.sessions.count, 1)
            XCTAssertEqual(state.activeSessionCount, 1)
            XCTAssertEqual(state.sessions["remote:remote-test:same-thread"]?.providerSessionId, record.id)
            // A missed Stop hook must still be reconciled by the next scan.
            state.reconcileRemoteCodexSessions([], hostId: "remote-test", hostName: "server", cwdFilter: "")
            XCTAssertEqual(state.activeSessionCount, 0)
        }
    }

    func testRemoteScanRemovesHookOnlyCardWithoutStop() throws {
        let state = AppState()
        let data = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "UserPromptSubmit", "session_id": "ended-thread",
            "_source": "codex", "_remote_host_id": "remote-test",
            "cwd": "/remote/project"
        ])
        state.handleEvent(try XCTUnwrap(HookEvent(from: data)))
        XCTAssertEqual(state.activeSessionCount, 1)
        // An unknown hook may be a CLI task, so an empty desktop scan keeps it.
        state.reconcileRemoteCodexSessions([], hostId: "remote-test", hostName: "server", cwdFilter: "")
        XCTAssertEqual(state.activeSessionCount, 1)
        let cliData = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "UserPromptSubmit", "session_id": "cli-thread",
            "_source": "codex", "_remote_host_id": "remote-test",
            "cwd": "/remote/project"
        ])
        state.handleEvent(try XCTUnwrap(HookEvent(from: cliData)))
        let ended = RemoteCodexSession(id: "ended-thread", cwd: "/remote/project", model: nil,
                                       title: nil, modifiedAt: Date().timeIntervalSince1970,
                                       startedAt: 0, isActive: false)
        state.reconcileRemoteCodexSessions([ended], hostId: "remote-test", hostName: "server", cwdFilter: "")
        XCTAssertEqual(state.activeSessionCount, 1)
        XCTAssertNil(state.sessions["remote:remote-test:ended-thread"])
        XCTAssertNotNil(state.sessions["remote:remote-test:cli-thread"])
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
