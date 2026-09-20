import XCTest
@testable import CodeIslandCore

final class CodexNativeSubagentRoutingTests: XCTestCase {
    func testCodexSubagentSessionStartDoesNotResetParentSession() throws {
        var parent = SessionSnapshot()
        parent.source = "codex"
        parent.status = .running
        parent.currentTool = "spawn_agent"
        parent.model = "gpt-5.4"
        parent.cwd = "/repo"
        parent.transcriptPath = "/tmp/parent.jsonl"

        var sessions = ["parent": parent]
        let event = try decode([
            "hook_event_name": "SessionStart",
            "session_id": "parent",
            "_source": "codex",
            "agent_id": "child",
            "agent_type": "default",
            "model": "gpt-5.4-mini",
            "cwd": "/repo",
            "transcript_path": "/tmp/child.jsonl",
        ])

        let effects = reduceEvent(sessions: &sessions, event: event, maxHistory: 10)

        XCTAssertEqual(sessions["parent"]?.model, "gpt-5.4")
        XCTAssertEqual(sessions["parent"]?.transcriptPath, "/tmp/parent.jsonl")
        XCTAssertEqual(sessions["parent"]?.subagents["child"]?.agentType, "default")
        XCTAssertEqual(sessions["parent"]?.status, .running)
        XCTAssertTrue(effects.contains(.setActiveSession(sessionId: "parent")))
    }

    func testCodexSubagentPromptAndStopAreConsumedByParentSubagentState() throws {
        var parent = SessionSnapshot()
        parent.source = "codex"
        parent.status = .running
        parent.lastUserPrompt = "main prompt"
        parent.addRecentMessage(ChatMessage(isUser: true, text: "main prompt"))
        parent.subagents["child"] = SubagentState(agentId: "child", agentType: "default")

        var sessions = ["parent": parent]
        let promptEvent = try decode([
            "hook_event_name": "UserPromptSubmit",
            "session_id": "parent",
            "_source": "codex",
            "agent_id": "child",
            "agent_type": "default",
            "prompt": "child task",
        ])
        _ = reduceEvent(sessions: &sessions, event: promptEvent, maxHistory: 10)

        XCTAssertEqual(sessions["parent"]?.lastUserPrompt, "main prompt")
        XCTAssertEqual(sessions["parent"]?.recentMessages.map(\.text), ["main prompt"])
        XCTAssertEqual(sessions["parent"]?.subagents["child"]?.status, .processing)

        let stopEvent = try decode([
            "hook_event_name": "Stop",
            "session_id": "parent",
            "_source": "codex",
            "agent_id": "child",
            "agent_type": "default",
        ])
        _ = reduceEvent(sessions: &sessions, event: stopEvent, maxHistory: 10)

        XCTAssertTrue(sessions["parent"]?.subagents.isEmpty == true)
        XCTAssertEqual(sessions["parent"]?.status, .processing)
    }

    func testInTurnSessionStartPreservesStateAndIsSilentLocallyAndRemotely() throws {
        for remote in [false, true] {
            for status in [AgentStatus.processing, .running, .waitingApproval, .waitingQuestion] {
                var session = SessionSnapshot()
                session.source = "codex"
                session.status = status
                session.currentTool = "shell"
                session.lastUserPrompt = "original task"
                session.sessionTitle = "Task title"
                session.addRecentMessage(ChatMessage(isUser: true, text: "original task"))
                if remote { session.remoteHostId = "remote-host" }
                var sessions = ["parent": session]
                let event = try decode([
                    "hook_event_name": "SessionStart", "session_id": "parent",
                    "_source": "codex", "source": "compact", "cwd": "/repo"
                ])
                let effects = reduceEvent(sessions: &sessions, event: event, maxHistory: 10)
                XCTAssertEqual(sessions["parent"]?.status, status)
                XCTAssertEqual(sessions["parent"]?.currentTool, "shell")
                XCTAssertEqual(sessions["parent"]?.startTime, session.startTime)
                XCTAssertEqual(sessions["parent"]?.lastUserPrompt, "original task")
                XCTAssertEqual(sessions["parent"]?.recentMessages.map(\.text), ["original task"])
                XCTAssertEqual(sessions["parent"]?.sessionTitle, "Task title")
                XCTAssertEqual(sessions["parent"]?.cwd, "/repo")
                XCTAssertEqual(sessions["parent"]?.remoteHostId, session.remoteHostId)
                XCTAssertTrue(effects.isEmpty)
                let stop = try decode(["hook_event_name": "Stop", "session_id": "parent", "_source": "codex"])
                let completed = reduceEvent(sessions: &sessions, event: stop, maxHistory: 10)
                XCTAssertEqual(sessions["parent"]?.status, .idle)
                XCTAssertTrue(completed.contains(.enqueueCompletion(sessionId: "parent")))
                XCTAssertTrue(completed.contains(.playSound("Stop")))
            }
        }
        var fresh: [String: SessionSnapshot] = [:]
        let start = try decode(["hook_event_name": "SessionStart", "session_id": "new", "_source": "codex"])
        XCTAssertTrue(reduceEvent(sessions: &fresh, event: start, maxHistory: 10).contains(.playSound("SessionStart")))
    }

    private func decode(_ payload: [String: Any]) throws -> HookEvent {
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let event = HookEvent(from: data) else {
            XCTFail("HookEvent should decode payload: \(payload)")
            throw NSError(domain: "CodexNativeSubagentRoutingTests", code: 1)
        }
        return event
    }
}
