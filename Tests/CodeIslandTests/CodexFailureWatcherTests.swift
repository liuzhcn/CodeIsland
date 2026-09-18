import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

@MainActor
final class CodexFailureWatcherTests: XCTestCase {
    func testFramingHandlesConsecutiveAndPartialFrames() throws {
        var bytes = Data([9, 1, 0, 0, 0, 65, 2, 0, 0, 0, 66])
        bytes.removeFirst() // Data can have a nonzero startIndex.
        XCTAssertEqual(try CodexFailureWatcher.takeFrame(from: &bytes), Data([65]))
        XCTAssertNil(try CodexFailureWatcher.takeFrame(from: &bytes))
        bytes.append(67)
        XCTAssertEqual(try CodexFailureWatcher.takeFrame(from: &bytes), Data([66, 67]))
        XCTAssertTrue(bytes.isEmpty)
        bytes = Data([255, 255, 255, 255])
        XCTAssertThrowsError(try CodexFailureWatcher.takeFrame(from: &bytes))
    }

    func testFailedSnapshotAndPatchesClearRunningButNeverNewerTurns() {
        let state = AppState()
        var session = SessionSnapshot()
        session.source = "codex"
        session.status = .processing
        session.lastActivity = Date(timeIntervalSince1970: 101)
        state.sessions["remote:test"] = session
        let watcher = CodexFailureWatcher(state: state)
        watcher.observe(sessionId: "remote:test", host: "host", thread: "thread")
        func frame(_ change: [String: Any]) -> [String: Any] {
            ["method": "thread-stream-state-changed", "params": ["hostId": "host", "conversationId": "thread", "change": change]]
        }
        let old: [String: Any] = ["status": "failed", "turnStartedAtMs": 90000, "durationMs": 1000]
        let current: [String: Any] = ["status": "inProgress", "turnStartedAtMs": 100000]
        watcher.accept(frame(["type": "snapshot", "conversationState": ["turnHistory": ["history": ["entitiesByKey": ["old": old, "current": current]]]]]))
        XCTAssertEqual(state.sessions["remote:test"]?.status, .processing)
        let patches: [[String: Any]] = [
            ["op": "replace", "path": ["turnHistory", "history", "entitiesByKey", "current", "status"], "value": "failed"],
            ["op": "add", "path": ["turnHistory", "history", "entitiesByKey", "current", "durationMs"], "value": 5000]
        ]
        watcher.accept(frame(["type": "patches", "patches": patches]))
        XCTAssertEqual(state.sessions["remote:test"]?.status, .idle)
        XCTAssertEqual(state.sessions["remote:test"]?.interrupted, true)
        state.sessions["remote:test"]?.status = .processing
        state.sessions["remote:test"]?.lastActivity = Date(timeIntervalSince1970: 106)
        watcher.accept(frame(["type": "patches", "patches": patches]))
        XCTAssertEqual(state.sessions["remote:test"]?.status, .processing)
        XCTAssertNil(CodexFailureWatcher.Turn(["status": "completed", "turnStartedAtMs": 100000, "durationMs": 5000]).ended)
    }
}
