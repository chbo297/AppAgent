#if canImport(UIKit)
import XCTest
import UIKit
@testable import AppAgent

@MainActor
final class AppAgentSettingsProbeLifecycleTests: XCTestCase {
    private actor DiscoveryGate {
        private var continuation: CheckedContinuation<[AppAgentModelCandidate], Error>?
        var isWaiting: Bool { continuation != nil }

        func discover() async throws -> [AppAgentModelCandidate] {
            try await withCheckedThrowingContinuation { continuation = $0 }
        }

        func finish(_ candidates: [AppAgentModelCandidate]) {
            continuation?.resume(returning: candidates)
            continuation = nil
        }

        func fail() {
            continuation?.resume(throwing: AppAgentModelDiscovery.DiscoveryError.emptyResult)
            continuation = nil
        }
    }

    private actor AvailabilityGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var onResult: (@Sendable (AppAgentModelAvailability) -> Void)?
        var isWaiting: Bool { continuation != nil }

        func probe(onResult: @escaping @Sendable (AppAgentModelAvailability) -> Void) async {
            self.onResult = onResult
            await withCheckedContinuation { continuation = $0 }
        }

        func finish(_ result: AppAgentModelAvailability) {
            onResult?(result)
            onResult = nil
            continuation?.resume()
            continuation = nil
        }
    }

    func testEditingEndpointDiscardsLateDiscoveryModels() async throws {
        let gate = DiscoveryGate()
        let controller = makeController()
        controller.discoverModelCandidates = { _ in try await gate.discover() }
        controller.probeModelAvailability = { _, _, _ in }
        controller.runProbe(refetchList: true)
        let task = try XCTUnwrap(controller.probeTask)
        try await waitUntil { await gate.isWaiting }

        let field = try endpointField(controller, row: 0)
        field.text = "https://replacement.example/v1"
        try invokeRegisteredAction(field, for: .editingChanged)
        await gate.finish([.init(modelId: "stale-model", apiProtocol: .openaiCompletions)])
        await task.value

        XCTAssertTrue(task.isCancelled)
        XCTAssertNil(controller.probeTask)
        XCTAssertEqual(controller.tableView(table(controller), numberOfRowsInSection: 1), 1,
                       "旧端点返回的模型不能出现在新端点的候选列表")
    }

    func testCancelDiscardsLateDiscoveryFailure() async throws {
        let gate = DiscoveryGate()
        let controller = makeController()
        controller.discoverModelCandidates = { _ in try await gate.discover() }
        controller.runProbe(refetchList: true)
        let task = try XCTUnwrap(controller.probeTask)
        try await waitUntil { await gate.isWaiting }

        let cancel = try XCTUnwrap(controller.navigationItem.leftBarButtonItem)
        let target = try XCTUnwrap(cancel.target as? NSObject)
        _ = target.perform(try XCTUnwrap(cancel.action))
        await gate.fail()
        await task.value

        XCTAssertTrue(task.isCancelled)
        XCTAssertNil(controller.probeTask)
        XCTAssertNil(controller.presentedViewController, "关闭后不能再弹出迟到的探查失败对话框")
    }

    func testEditingCredentialsDiscardsLateAvailabilityAndClearsOldStatus() async throws {
        let candidate = AppAgentModelCandidate(modelId: "existing-model", apiProtocol: .openaiCompletions)
        let gate = AvailabilityGate()
        let controller = makeController(models: [
            .init(modelId: candidate.modelId, apiProtocol: candidate.apiProtocol)
        ])
        controller.probeModelAvailability = { _, _, report in await gate.probe(onResult: report) }
        controller.runProbe(refetchList: false)
        let task = try XCTUnwrap(controller.probeTask)
        try await waitUntil { await gate.isWaiting }

        let field = try endpointField(controller, row: 1)
        field.text = "replacement-key"
        try invokeRegisteredAction(field, for: .editingChanged)
        await gate.finish(.init(candidate: candidate, isAvailable: true, firstTokenLatency: 0.1))
        await task.value

        let row = controller.tableView(table(controller), cellForRowAt: IndexPath(row: 0, section: 1))
        XCTAssertTrue(task.isCancelled)
        XCTAssertTrue(row.detailTextLabel?.attributedText?.string.contains("未实测") == true,
                      "旧凭据的成功结果不能让新凭据显示绿灯")
    }

    func testConfirmedClearDiscardsLateDiscoveryAndPublishesEmptyConfiguration() async throws {
        let gate = DiscoveryGate()
        let controller = makeController(models: [.init(modelId: "existing", apiProtocol: .openaiCompletions)])
        var clearCalls = 0
        var saved: AppAgentEndpointSettings?
        controller.clearConfiguration = {
            clearCalls += 1
            return true
        }
        controller.onSave = {
            saved = $0
        }
        let confirmation = controller.makeClearConfirmation()
        XCTAssertEqual(confirmation.actions.map(\.style), [.cancel, .destructive])
        XCTAssertEqual(clearCalls, 0, "Presenting confirmation must not clear anything")
        XCTAssertNil(saved)
        XCTAssertTrue(try endpointField(controller, row: 1).isSecureTextEntry)
        let keyField = try endpointField(controller, row: 1)
        let controls = try XCTUnwrap(keyField.rightView as? UIStackView)
        let visibility = try XCTUnwrap(controls.arrangedSubviews.first as? UIButton)
        try invokeRegisteredAction(visibility, for: .touchUpInside)
        XCTAssertFalse(keyField.isSecureTextEntry)
        XCTAssertEqual(keyField.text, "original-key")

        controller.discoverModelCandidates = { _ in
            try await gate.discover()
        }
        controller.probeModelAvailability = { _, _, _ in
            XCTFail("Cleared discovery must never begin availability requests")
        }
        controller.runProbe(refetchList: true)
        let task = try XCTUnwrap(controller.probeTask)
        try await waitUntil {
            await gate.isWaiting
        }
        controller.clearModelConfiguration()
        await gate.finish([.init(modelId: "stale", apiProtocol: .openaiCompletions)])
        await task.value

        XCTAssertTrue(task.isCancelled)
        XCTAssertNil(controller.probeTask)
        XCTAssertEqual(clearCalls, 1)
        let empty = try XCTUnwrap(saved)
        XCTAssertFalse(empty.isUsable)
        XCTAssertEqual(empty.baseURL, "")
        XCTAssertEqual(empty.apiKey, "")
        XCTAssertTrue(empty.enabledModels.isEmpty)
        XCTAssertTrue(empty.customHeaders.isEmpty)
        XCTAssertEqual(try endpointField(controller, row: 0).text, "")
        XCTAssertEqual(try endpointField(controller, row: 1).text, "")
        XCTAssertTrue(keyField.isSecureTextEntry)
        XCTAssertEqual(controller.tableView(table(controller), numberOfRowsInSection: 1), 1)
    }

    func testClearDiscardsLateAvailability() async throws {
        let candidate = AppAgentModelCandidate(modelId: "existing", apiProtocol: .openaiCompletions)
        let gate = AvailabilityGate()
        let controller = makeController(models: [.init(modelId: candidate.modelId, apiProtocol: candidate.apiProtocol)])
        controller.clearConfiguration = {
            true
        }
        controller.probeModelAvailability = { _, _, report in
            await gate.probe(onResult: report)
        }
        controller.runProbe(refetchList: false)
        let task = try XCTUnwrap(controller.probeTask)
        try await waitUntil {
            await gate.isWaiting
        }
        controller.clearModelConfiguration()
        await gate.finish(.init(candidate: candidate, isAvailable: true, firstTokenLatency: 0.1))
        await task.value
        XCTAssertTrue(task.isCancelled)
        XCTAssertNil(controller.probeTask)
        XCTAssertEqual(controller.tableView(table(controller), numberOfRowsInSection: 1), 1)
    }

    func testPersistenceFailuresKeepDraftAndDoNotPublishSuccess() throws {
        for clearing in [false, true] {
            let controller = makeController(models: [.init(modelId: "existing", apiProtocol: .openaiCompletions)])
            controller.onSave = { _ in
                XCTFail("Persistence failure must not be published to the runtime")
            }
            var attempts = 0
            controller.saveConfiguration = { _ in
                attempts += 1
                return false
            }
            controller.clearConfiguration = {
                attempts += 1
                return false
            }
            if clearing {
                controller.clearModelConfiguration()
            } else {
                let save = try XCTUnwrap(controller.navigationItem.rightBarButtonItem)
                let target = try XCTUnwrap(save.target as? NSObject)
                _ = target.perform(try XCTUnwrap(save.action))
            }
            XCTAssertEqual(attempts, 1)
            XCTAssertEqual(try endpointField(controller, row: 1).text, "original-key")
            XCTAssertEqual(controller.tableView(table(controller), numberOfRowsInSection: 1), 2)
        }
    }

    func testProbeKeepsSelectedPriorityAndSortsUnselectedByMeasuredLatency() async throws {
        let names = ["primary", "fallback", "slow", "fast", "failed", "unknown", "tied"]
        let candidates = names.map {
            AppAgentModelCandidate(modelId: $0, apiProtocol: .openaiCompletions)
        }
        let controller = makeController(models: candidates.map {
            AppAgentModelRef(modelId: $0.modelId, apiProtocol: $0.apiProtocol)
        })
        let list = table(controller)
        for row in 2..<names.count {
            controller.tableView(list, didSelectRowAt: IndexPath(row: row, section: 1))
        }
        // 用户将未选项拖到最前；重新探查应恢复已选置前，但保留 primary/fallback 顺序。
        controller.tableView(list, moveRowAt: IndexPath(row: 2, section: 1),
                             to: IndexPath(row: 0, section: 1))
        controller.discoverModelCandidates = { _ in
            candidates
        }
        controller.probeModelAvailability = { _, _, report in
            // 回包顺序故意与耗时顺序不同；已选项即便失败，也不能被取消或降级。
            report(.init(candidate: candidates[2], isAvailable: true, firstTokenLatency: 2))
            report(.init(candidate: candidates[6], isAvailable: true, firstTokenLatency: 0.1))
            report(.init(candidate: candidates[1], isAvailable: true, firstTokenLatency: 0.01))
            report(.init(candidate: candidates[0], isAvailable: false, failureReason: "offline"))
            report(.init(candidate: candidates[3], isAvailable: true, firstTokenLatency: 0.1))
            report(.init(candidate: candidates[4], isAvailable: false, failureReason: "offline"))
            report(.init(candidate: candidates[5], isAvailable: true))
        }
        controller.runProbe(refetchList: true)
        XCTAssertEqual(modelNames(controller).prefix(2), ["primary", "fallback"])
        let task = try XCTUnwrap(controller.probeTask)
        await task.value
        XCTAssertEqual(modelNames(controller), ["primary", "fallback", "fast", "tied", "slow", "failed", "unknown"])

        var saved: AppAgentEndpointSettings?
        controller.saveConfiguration = {
            saved = $0
            return true
        }
        let save = try XCTUnwrap(controller.navigationItem.rightBarButtonItem)
        let target = try XCTUnwrap(save.target as? NSObject)
        _ = target.perform(try XCTUnwrap(save.action))
        XCTAssertEqual(saved?.enabledModels.map(\.modelId), ["primary", "fallback"])
    }

    func testDiscoveryWithoutSelectionSortsFastestFirstWithoutAutoSelecting() async throws {
        let candidates = ["slow", "fast", "failed"].map {
            AppAgentModelCandidate(modelId: $0, apiProtocol: .openaiCompletions)
        }
        let controller = makeController()
        controller.discoverModelCandidates = { _ in
            candidates
        }
        controller.probeModelAvailability = { _, _, report in
            report(.init(candidate: candidates[0], isAvailable: true, firstTokenLatency: 3))
            report(.init(candidate: candidates[2], isAvailable: false, failureReason: "offline"))
            report(.init(candidate: candidates[1], isAvailable: true, firstTokenLatency: 0.2))
        }
        controller.runProbe(refetchList: true)
        let task = try XCTUnwrap(controller.probeTask)
        await task.value
        XCTAssertEqual(modelNames(controller), ["fast", "slow", "failed"])
        for row in candidates.indices {
            let cell = controller.tableView(table(controller), cellForRowAt: IndexPath(row: row, section: 1))
            XCTAssertTrue(cell.accessibilityLabel?.hasSuffix("未启用") == true)
        }
        // 重测走同一排序规则。
        controller.runProbe(refetchList: false)
        let retest = try XCTUnwrap(controller.probeTask)
        await retest.value
        XCTAssertEqual(modelNames(controller), ["fast", "slow", "failed"])
    }

    private func modelNames(_ controller: AppAgentSettingsViewController) -> [String] {
        let list = table(controller)
        let count = controller.tableView(list, numberOfRowsInSection: 1) - 1
        return (0..<count).map {
            controller.tableView(list, cellForRowAt: IndexPath(row: $0, section: 1)).textLabel?.text ?? ""
        }
    }

    private func makeController(models: [AppAgentModelRef] = []) -> AppAgentSettingsViewController {
        let controller = AppAgentSettingsViewController(settings: .init(
            baseURL: "https://original.example/v1", apiKey: "original-key", enabledModels: models
        ))
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.layoutIfNeeded()
        return controller
    }

    private func table(_ controller: AppAgentSettingsViewController) -> UITableView {
        controller.view.subviews.compactMap { $0 as? UITableView }.first!
    }

    private func endpointField(_ controller: AppAgentSettingsViewController, row: Int) throws -> UITextField {
        let cell = controller.tableView(table(controller), cellForRowAt: IndexPath(row: row, section: 0))
        return try XCTUnwrap(cell.contentView.subviews.compactMap { $0 as? UITextField }.first)
    }

    private func waitUntil(_ ready: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await ready() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("探查任务没有进入受控等待")
    }
}
#endif
