import XCTest
@testable import AppAgent

/// 面板档位和工作区数据属于会话：随会话落盘、进出废纸篓，超限整笔拒绝。
final class SessionWorkspaceTests: XCTestCase {
    private func agent(_ storage: any SessionStorage) -> AIAgent {
        AIAgent(id: "workspace", profile: .init(autoPersist: false, registerBuiltInTools: false),
                toolCentral: ToolCentral(), providerCentral: ModelProviderCentral(),
                memoryStorage: InMemoryMemoryStorage(), sessionStorage: storage)
    }

    func testPanelAndWorkspaceSurviveRestartAndTrash() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let first = agent(FileSessionStorage(directory: root))
        let session = await first.createSession(title: "Demo")
        session.setChatPanel(.full)
        try session.updateWorkspace { workspace in
            workspace.isShown = true
            workspace.h5.files["index.html"] = "<p>hi</p>"
            workspace.h5.state["tab"] = "2"
            workspace.slots["map"] = SessionWorkspace.Slot(isShown: true, state: ["camera": "{\"zoom\":12.5}"])
        }
        try await first.sessionManager.saveSession(session)
        try await first.deleteSession(session.id)

        let restarted = agent(FileSessionStorage(directory: root))
        try await restarted.restoreAll()
        let restored = try await restarted.sessionManager.restoreArchivedSession(session.id)
        XCTAssertEqual(restored.chatPanel, .full)
        XCTAssertEqual(restored.workspace, session.workspace)
        XCTAssertEqual(restored.workspace.slots["map"]?.state["camera"], "{\"zoom\":12.5}")
    }

    func testOversizedOrInvalidChangeIsRejectedWhole() async throws {
        let session = await agent(InMemorySessionStorage()).createSession(title: "Limits")
        try session.updateWorkspace { workspace in
            workspace.h5.files["index.html"] = "ok"
        }
        XCTAssertThrowsError(try session.updateWorkspace { workspace in
            workspace.title = "changed"
            workspace.h5.files["../escape.js"] = "x"
        })
        XCTAssertThrowsError(try session.updateWorkspace { workspace in
            workspace.h5.state["big"] = String(repeating: "a", count: SessionWorkspaceLimits.maximumStateBytes + 1)
        })
        XCTAssertThrowsError(try session.updateWorkspace { workspace in
            workspace.slots["map"] = SessionWorkspace.Slot(isShown: true)
            workspace.slots["chart"] = SessionWorkspace.Slot(isShown: true)
        })
        XCTAssertEqual(session.workspace.title, "")
        XCTAssertTrue(session.workspace.slots.isEmpty)
        XCTAssertEqual(session.workspace.h5.files, ["index.html": "ok"])
        XCTAssertTrue(session.workspace.h5.state.isEmpty)
    }

    /// H5 层隐藏且没有插槽在显示时不算有内容，否则页面会以一张空白底板盖住 App。
    func testHiddenH5WithoutShownSlotHasNoContent() {
        var workspace = SessionWorkspace(isShown: true, h5: SessionWorkspace.H5(files: ["index.html": "<p>hi</p>"]))
        XCTAssertTrue(workspace.hasContent)
        workspace.h5.isShown = false
        XCTAssertFalse(workspace.hasContent)
        workspace.slots["map"] = SessionWorkspace.Slot(isShown: true)
        XCTAssertTrue(workspace.hasContent)
    }

    func testChatPanelOperationOnlyChangesSessionData() async throws {
        let session = await agent(InMemorySessionStorage()).createSession(title: "Panel")
        XCTAssertEqual(session.chatPanel, .half)
        let output = try await SessionTool().execute(
            arguments: ["op": .string("chat_panel"), "state": .string("collapsed")], session: session
        )
        XCTAssertEqual(session.chatPanel, .collapsed)
        if case .error(let message) = output {
            XCTFail(message)
        }
        let rejected = try await SessionTool().execute(
            arguments: ["op": .string("chat_panel"), "state": .string("expanded")], session: session
        )
        guard case .error = rejected else {
            return XCTFail("bad state should be rejected")
        }
        XCTAssertEqual(session.chatPanel, .collapsed)
    }
}
