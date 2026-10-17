import XCTest
import CodeIslandCore
@testable import CodeIsland

@MainActor
final class RecentSessionRetentionTests: XCTestCase {
    func testCompletedRemoteTaskRemainsAndRepeatedSnapshotsDoNotExtendRetention() throws {
        let state = AppState()
        let now = Date().timeIntervalSince1970
        let running = RemoteCodexSession(id: "recent", cwd: "/repo", model: nil,
            title: "Recent task", modifiedAt: now, startedAt: now)
        state.reconcileRemoteCodexSessions([running], hostId: "host", hostName: "server", cwdFilter: "")
        let ended = RemoteCodexSession(id: "recent", cwd: "/repo", model: nil,
            title: "Recent task", modifiedAt: now + 1, startedAt: now, isActive: false)
        state.reconcileRemoteCodexSessions([ended], hostId: "host", hostName: "server", cwdFilter: "")
        XCTAssertEqual(state.activeSessionCount, 0)
        XCTAssertEqual(state.totalSessionCount, 1)
        let key = "remote:host:recent"
        XCTAssertEqual(state.sessions[key]?.status, .idle)
        let saved = Date(timeIntervalSince1970: now - 120)
        state.sessions[key]?.lastActivity = saved
        state.reconcileRemoteCodexSessions([ended], hostId: "host", hostName: "server", cwdFilter: "")
        XCTAssertEqual(state.sessions[key]?.lastActivity, saved)
        state.reconcileRemoteCodexSessions([running], hostId: "host", hostName: "server", cwdFilter: "")
        XCTAssertEqual(state.totalSessionCount, 1)
        XCTAssertEqual(state.activeSessionCount, 1)
    }

    func testEmptyAuthoritativeSnapshotSettlesButRetainsKnownTask() {
        let state = AppState()
        let now = Date().timeIntervalSince1970
        let running = RemoteCodexSession(id: "recent", cwd: "/repo", model: nil,
            title: "Recent task", modifiedAt: now, startedAt: now)
        state.reconcileRemoteCodexSessions([running], hostId: "host", hostName: "server", cwdFilter: "")
        state.reconcileRemoteCodexSessions([], hostId: "host", hostName: "server", cwdFilter: "")
        XCTAssertEqual(state.activeSessionCount, 0)
        XCTAssertEqual(state.totalSessionCount, 1)
    }

    func testExplicitRetentionSettingOverridesUnmonitoredFallback() {
        XCTAssertFalse(AppState.isStaleIdleSession(idleMinutes: 10, userTimeoutMinutes: 60,
            hasMonitor: false, hermesChatElsewhere: false))
        XCTAssertFalse(AppState.isStaleIdleSession(idleMinutes: 59, userTimeoutMinutes: 60,
            hasMonitor: false, hermesChatElsewhere: false))
        XCTAssertTrue(AppState.isStaleIdleSession(idleMinutes: 60, userTimeoutMinutes: 60,
            hasMonitor: false, hermesChatElsewhere: false))
        XCTAssertFalse(AppState.isStaleIdleSession(idleMinutes: 1000, userTimeoutMinutes: 0,
            hasMonitor: false, hermesChatElsewhere: false))
    }
    func testDisconnectRetainsCardAndReconnectDeduplicatesIt() {
        let state = AppState()
        let now = Date().timeIntervalSince1970
        let record = RemoteCodexSession(id: "recent", cwd: "/repo", model: nil,
            title: "Recent task", modifiedAt: now, startedAt: now)
        state.reconcileRemoteCodexSessions([record], hostId: "host", hostName: "server", cwdFilter: "")
        state.markRemoteSessionsDisconnected(hostId: "host")
        XCTAssertEqual(state.totalSessionCount, 1)
        XCTAssertEqual(state.activeSessionCount, 0)
        XCTAssertEqual(state.sessions["remote:host:recent"]?.connectionLost, true)
        let oldDate = Date(timeIntervalSince1970: now - 10)
        state.sessions["remote:host:recent"]?.lastActivity = oldDate
        state.markRemoteSessionsDisconnected(hostId: "host")
        XCTAssertEqual(state.sessions["remote:host:recent"]?.lastActivity, oldDate)
        state.reconcileRemoteCodexSessions([record], hostId: "host", hostName: "server", cwdFilter: "")
        XCTAssertEqual(state.totalSessionCount, 1)
        XCTAssertEqual(state.activeSessionCount, 1)
        XCTAssertEqual(state.sessions["remote:host:recent"]?.connectionLost, false)
    }

    func testRemoteRecentCardSurvivesRestartBeyondThirtyMinutes() throws {
        let savedTimeout = SettingsManager.shared.sessionTimeout
        defer { SettingsManager.shared.sessionTimeout = savedTimeout; SessionPersistence.clear() }
        SettingsManager.shared.sessionTimeout = 60
        var card = SessionSnapshot()
        card.source = "codex"
        card.remoteHostId = "host"
        card.remoteHostName = "server"
        card.termBundleId = AppState.codexAppBundleId
        card.providerSessionId = "recent"
        card.sessionTitle = "Recent task"
        card.lastAssistantMessage = "Done"
        card.lastActivity = Date().addingTimeInterval(-45 * 60)
        SessionPersistence.save(["remote:host:recent": card])
        let state = AppState()
        state.restoreSessions()
        XCTAssertEqual(state.totalSessionCount, 1)
        XCTAssertEqual(state.sessions["remote:host:recent"]?.lastAssistantMessage, "Done")
        XCTAssertEqual(state.sessions["remote:host:recent"]?.remoteHostId, "host")
        XCTAssertEqual(state.sessions["remote:host:recent"]?.connectionLost, true)
        card.lastActivity = Date().addingTimeInterval(-61 * 60)
        SessionPersistence.save(["remote:host:expired": card])
        let expired = AppState()
        expired.restoreSessions()
        XCTAssertEqual(expired.totalSessionCount, 0)
    }

}
