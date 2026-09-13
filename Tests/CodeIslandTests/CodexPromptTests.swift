import XCTest
@testable import CodeIsland
import CodeIslandCore

final class CodexPromptTests: XCTestCase {
    func testCodexHistoryAndStreamingUserMessages() throws {
        let rows: [[String: Any]] = [
            ["type":"response_item", "payload":["type":"message","role":"user","content":[["type":"input_text","text":"第一问"]]]],
            ["type":"response_item", "payload":["type":"message","role":"user","content":[["type":"input_text","text":"第二问"]]]],
            ["type":"response_item", "payload":["type":"message","role":"assistant","content":[["type":"output_text","text":"回复"]]]]
        ]
        let data = try rows.reduce(into: Data()) { $0.append(try JSONSerialization.data(withJSONObject: $1)); $0.append(10) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(JSONLTailer.scanLines(data).delta.lastUserPrompt, "第二问")
        let messages = AppState.readRecentFromCodexTranscript(path: file.path).1
        XCTAssertEqual(messages.filter(\.isUser).map(\.text), ["第二问"])
        XCTAssertEqual(messages.last?.text, "回复")
    }
    func testRealProjectLabels() {
        let state: [String: Any] = [
            "thread-project-assignments": ["a": ["projectKind": "local", "projectId": "p"], "b": ["projectKind": "remote", "projectId": "r"]],
            "local-projects": ["p": ["name": "本地项目"]],
            "remote-projects": [["id": "r", "label": "远程项目"]]
        ]
        XCTAssertEqual(SessionTitleStore.codexProjectName(sessionId: "a", state: state), "本地项目")
        XCTAssertEqual(SessionTitleStore.codexProjectName(sessionId: "b", state: state), "远程项目")
        XCTAssertNil(SessionTitleStore.codexProjectName(sessionId: "unassigned", state: state))
    }

    func testBrowserContextPreview() {
        let context = "<in-app-browser-context source=\"ambient-ui-state\">\nAutomatically supplied context\n</in-app-browser-context>"
        XCTAssertEqual(ChatMessageTextFormatter.userPreview(context + "\n\n## My request:\n可以优化么？"), "可以优化么？")
        XCTAssertEqual(ChatMessageTextFormatter.userPreview("# Files mentioned by the user:\nimage.png\n" + context + "\n## My request:\n检查图片"), "检查图片")
        XCTAssertEqual(ChatMessageTextFormatter.userPreview(context + "\n继续处理"), "继续处理")
        let quoted = "请解释这个标签：" + context
        XCTAssertTrue(ChatMessageTextFormatter.userPreview(quoted).contains("<in-app-browser-context"))
        XCTAssertEqual(ChatMessageTextFormatter.userPreview("## My request: 普通正文"), "## My request: 普通正文")
    }

    func testAttachedPromptPreview() {
        XCTAssertEqual(ChatMessageTextFormatter.userPreview("\n# Files mentioned by the user:\nfile.png\n\n## My request:\n检查图片\n说明原因"), "检查图片 说明原因")
        XCTAssertEqual(ChatMessageTextFormatter.userPreview("\n正常问题\n"), "正常问题")
    }
}
