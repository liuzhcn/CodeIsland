import XCTest
import CodeIslandCore
@testable import CodeIsland

@MainActor
final class RecentSessionCountFloorTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    func card(age: TimeInterval = 7200, status: AgentStatus = .idle, remote: Bool = false) -> SessionSnapshot {
        var s = SessionSnapshot()
        s.source = "codex"
        s.status = status
        s.lastActivity = now.addingTimeInterval(-age)
        s.lastUserPrompt = "Task"
        if remote { s.remoteHostId = "server" }
        return s
    }

    func cards(_ count: Int) -> [String: SessionSnapshot] {
        Dictionary(uniqueKeysWithValues: (0..<count).map {
            ("task-\($0)", card(age: 7200 + Double($0), remote: $0 % 2 == 0))
        })
    }

    func selected(_ sessions: [String: SessionSnapshot], timeout: Int = 60) -> [String] {
        AppState.expiredRecentSessionIDs(sessions: sessions, timeoutMinutes: timeout, now: now)
    }

    func testZeroThroughFiveExpiredCardsRemain() {
        for count in 0...5 { XCTAssertTrue(selected(cards(count)).isEmpty) }
    }

    func testSixRemovesOnlyOldestAndEightStopsAtFive() {
        XCTAssertEqual(selected(cards(6)), ["task-5"])
        XCTAssertEqual(selected(cards(8)), ["task-7", "task-6", "task-5"])
    }

    func testInsufficientExpiredCandidatesMayLeaveMoreThanFive() {
        var all = cards(8)
        for i in 0..<6 { all["task-\(i)"] = card(age: 3599) }
        XCTAssertEqual(selected(all), ["task-7", "task-6"])
    }

    func testAllActiveStatesProtectedEvenBeyondFive() {
        let statuses: [AgentStatus] = [.running, .processing, .waitingApproval, .waitingQuestion]
        let all = Dictionary(uniqueKeysWithValues: (0..<8).map {
            ("task-\($0)", card(status: statuses[$0 % statuses.count]))
        })
        XCTAssertTrue(selected(all).isEmpty)
        var mixed = all
        mixed["old-idle"] = card()
        XCTAssertEqual(selected(mixed), ["old-idle"])
    }

    func testExactTimeoutAndDisabledCleanup() {
        var all = cards(6)
        for key in all.keys { all[key] = card(age: 3599) }
        XCTAssertTrue(selected(all).isEmpty)
        all["task-0"] = card(age: 3600)
        XCTAssertEqual(selected(all), ["task-0"])
        XCTAssertTrue(selected(cards(8), timeout: 0).isEmpty)
    }

    func testEqualTimesUseStableIDOrderAcrossHosts() {
        let all = Dictionary(uniqueKeysWithValues: ["f", "b", "a", "d", "e", "c"].enumerated().map {
            ($0.element, card(remote: $0.offset % 2 == 0))
        })
        XCTAssertEqual(selected(all), ["a"])
    }

    func testRuntimeCleanupIncludesAiWorkAndExplicitRemovalBypassesFloor() {
        let old = SettingsManager.shared.sessionTimeout
        defer { SettingsManager.shared.sessionTimeout = old }
        SettingsManager.shared.sessionTimeout = 60
        let state = AppState()
        state.sessions = cards(5)
        var aiwork = card(age: 10800)
        aiwork.source = "aiwork"
        aiwork.providerSessionId = "expired"
        state.sessions["aiwork:expired"] = aiwork
        state.pruneExpiredRecentSessions(now: now)
        XCTAssertNil(state.sessions["aiwork:expired"])
        XCTAssertEqual(state.sessions.count, 5)
        state.pruneExpiredRecentSessions(now: now.addingTimeInterval(86400))
        XCTAssertEqual(state.sessions.count, 5)
        state.removeSession("task-0")
        XCTAssertEqual(state.sessions.count, 4)
        state.sessions["aiwork:recent"] = aiwork
        state.sessions["aiwork:recent"]?.lastActivity = now.addingTimeInterval(-120)
        state.sessions["active"] = card(status: .running)
        state.pruneExpiredRecentSessions(now: now)
        XCTAssertNotNil(state.sessions["aiwork:recent"], "No separate 60-second AiWork expiry")
    }

    func testRestoreUsesSameGlobalPolicyForFiveAndEightOldCards() {
        let old = SettingsManager.shared.sessionTimeout
        defer { SettingsManager.shared.sessionTimeout = old; SessionPersistence.clear() }
        SettingsManager.shared.sessionTimeout = 60
        for count in [5, 8] {
            var persisted: [String: SessionSnapshot] = [:]
            for i in 0..<count {
                var s = card(remote: true)
                s.lastActivity = Date().addingTimeInterval(-7200 - Double(i))
                s.providerSessionId = "task-\(i)"
                persisted["remote:server:task-\(i)"] = s
            }
            let expectedRemoved = Set(AppState.expiredRecentSessionIDs(
                sessions: persisted, timeoutMinutes: 60, now: Date()))
            SessionPersistence.save(persisted)
            let state = AppState()
            state.restoreSessions()
            XCTAssertEqual(Set(state.sessions.keys), Set(persisted.keys).subtracting(expectedRemoved))
            XCTAssertEqual(state.totalSessionCount, 5)
        }
    }
}
