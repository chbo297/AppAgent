#if canImport(UIKit)
import XCTest
import UIKit
@testable import AppAgent

/// 只构建 UIView / VC；不创建窗口，不依赖 Catalyst 的 NSApplication。
@MainActor
final class SessionTrashUITests: XCTestCase {
    private struct StorageFailure: LocalizedError {
        var errorDescription: String? { "磁盘不可写" }
    }

    private func snapshot(_ id: String, title: String = "归档会话", updated: TimeInterval = 1) -> SessionSnapshot {
        SessionSnapshot(
            id: id, title: title, createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: updated),
            messages: [AIAgentMessage(role: .user, content: [.text("保留消息")])]
        )
    }

    private func makeAgent() async -> AIAgent {
        await AIAgentCentral().create(
            name: "trash-ui",
            profile: AIAgentProfile(autoPersist: false, registerBuiltInTools: false),
            sessionStorage: InMemorySessionStorage()
        )
    }

    private func table(in view: UIView) throws -> UITableView {
        try XCTUnwrap(view.subviews.compactMap { $0 as? UITableView }.first)
    }

    /// iOS 校验真实 alert 接线；Catalyst 可将 action sheet 呈现为无 popover 的 alert。
    /// 使用公开 initializer 创建未呈现的普通 controller fixture，仍执行生产配置路径。
    private func makeActionsWithPopover(
        controller: AppAgentSessionTrashViewController,
        id: String,
        anchor: UIView
    ) throws -> (sheet: UIAlertController, popover: UIPopoverPresentationController) {
        #if targetEnvironment(macCatalyst)
        let fixture = UIPopoverPresentationController(
            presentedViewController: UIViewController(),
            presenting: UIViewController()
        )
        let sheet = try XCTUnwrap(controller.makeSessionActions(
            for: id, sourceView: anchor, sourceRect: anchor.bounds,
            popoverProvider: { _ in fixture }
        ))
        return (sheet, fixture)
        #else
        let sheet = try XCTUnwrap(controller.makeSessionActions(
            for: id, sourceView: anchor, sourceRect: anchor.bounds
        ))
        return (sheet, try XCTUnwrap(sheet.popoverPresentationController))
        #endif
    }

    func testSidebarEntryIsDiscoverableEvenWhenEmptyAndSwipeSaysArchive() throws {
        let list = AppAgentSessionListView(frame: CGRect(x: 0, y: 0, width: 195, height: 600))
        list.layoutIfNeeded()
        let entry = try XCTUnwrap(list.subviews.compactMap { $0 as? UIButton }.first {
            $0.accessibilityIdentifier == "session_trash_entry"
        })
        XCTAssertEqual(entry.title(for: .normal), "废纸篓")
        XCTAssertFalse(entry.isHidden)
        XCTAssertTrue(list.bounds.contains(entry.frame))
        var tapped = 0
        list.onTrashTapped = { tapped += 1 }
        entry.sendActions(for: .touchUpInside)
        XCTAssertEqual(tapped, 1)

        let item = AppAgentSessionSidebarItem(sessionID: "a", title: "A", detail: "", isSelected: true)
        list.setItems([item])
        let table = try table(in: list)
        let actions = try XCTUnwrap(list.tableView(
            table, trailingSwipeActionsConfigurationForRowAt: IndexPath(row: 0, section: 0)
        ))
        XCTAssertEqual(actions.actions.map(\.title), ["移入废纸篓"])
        XCTAssertFalse(actions.performsFirstActionWithFullSwipe)
        XCTAssertTrue(list.beginArchiving("a"))
        XCTAssertFalse(list.beginArchiving("a"))
        XCTAssertFalse(entry.isEnabled)
        XCTAssertEqual(list.items, [item], "保存前不乐观移除会话")
        list.finishArchiving(error: "移入废纸篓失败：磁盘不可写")
        XCTAssertTrue(entry.isEnabled)
        XCTAssertEqual(list.items, [item])
        list.setItems([.init(sessionID: nil, title: "演示", detail: "", isSelected: false)])
        XCTAssertNil(list.tableView(table, trailingSwipeActionsConfigurationForRowAt: IndexPath(row: 0, section: 0)))
    }

    func testArchiveFailurePreservesCurrentMessagesDraftAndObserver() async throws {
        let agent = await makeAgent()
        let session = await agent.createSession(title: "不能丢")
        session.addUserMessage("原有消息")
        let controller = AppAgentViewController()
        controller.agent = agent
        controller.switchSession(to: session.id)
        controller.inputBar.text = "未发送草稿"
        controller.expandedActivityTurnIDs.insert(42)
        let messageIDs = controller.chatMessages.map(\.id)
        let entered = expectation(description: "归档挂起")
        var resume: CheckedContinuation<Void, Never>?
        var calls = 0
        let operation = Task { @MainActor in
            await controller.archiveSessionFromSidebar(session.id, archive: { _ in
                calls += 1
                await withCheckedContinuation { resume = $0; entered.fulfill() }
                throw StorageFailure()
            })
        }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(controller.currentSessionId, session.id)
        XCTAssertEqual(controller.chatMessages.map(\.id), messageIDs)
        XCTAssertNotNil(session.uiState.onChange)
        controller.sendMessage(text: "未发送草稿")
        XCTAssertEqual(controller.inputBar.text, "未发送草稿")
        XCTAssertEqual(controller.chatMessages.map(\.id), messageIDs)
        await controller.archiveSessionFromSidebar(session.id, archive: { _ in calls += 1 })
        XCTAssertEqual(calls, 1)
        resume?.resume()
        await operation.value
        XCTAssertTrue(controller.currentSession === session)
        XCTAssertEqual(controller.chatMessages.map(\.id), messageIDs)
        XCTAssertEqual(controller.inputBar.text, "未发送草稿")
        XCTAssertEqual(controller.expandedActivityTurnIDs, [42])
        XCTAssertNotNil(session.uiState.onChange)
        XCTAssertTrue(controller.sessionSidebarView.sessionListView.archiveError?.contains("磁盘不可写") == true)
    }

    func testArchiveCurrentSwitchesAfterSuccessAndCreatesOnlyWhenLast() async throws {
        let agent = await makeAgent()
        let first = await agent.createSession(title: "First")
        let second = await agent.createSession(title: "Second")
        let controller = AppAgentViewController()
        controller.agent = agent
        controller.switchSession(to: first.id)
        await controller.archiveSessionFromSidebar(first.id)
        XCTAssertEqual(controller.currentSessionId, second.id)
        XCTAssertNil(agent.session(id: first.id))
        XCTAssertEqual(agent.allSessions.count, 1)
        let archived = try await agent.sessionManager.archivedSessions()
        XCTAssertEqual(archived.map(\.id), [first.id])

        await controller.archiveSessionFromSidebar(second.id)
        XCTAssertNotNil(controller.currentSession)
        XCTAssertNotEqual(controller.currentSessionId, second.id)
        XCTAssertEqual(agent.allSessions.count, 1)
        XCTAssertNil(controller.sessionSidebarView.sessionListView.archiveError)
    }

    func testArchiveLateSuccessDoesNotStealUserSessionSwitch() async throws {
        let agent = await makeAgent()
        let first = await agent.createSession(title: "First")
        let second = await agent.createSession(title: "Second")
        let controller = AppAgentViewController()
        controller.agent = agent
        controller.switchSession(to: first.id)
        let entered = expectation(description: "归档等待")
        var resume: CheckedContinuation<Void, Never>?
        let task = Task { @MainActor in
            await controller.archiveSessionFromSidebar(first.id, archive: { id in
                await withCheckedContinuation { resume = $0; entered.fulfill() }
                try await agent.sessionManager.archiveSession(id)
            })
        }
        await fulfillment(of: [entered], timeout: 2)
        controller.switchSession(to: second.id)
        resume?.resume()
        await task.value
        XCTAssertEqual(controller.currentSessionId, second.id)
        XCTAssertNotNil(second.uiState.onChange)
        XCTAssertEqual(agent.allSessions.count, 1)
    }

    func testArchiveLateSuccessDoesNotTouchReplacementAgent() async throws {
        let original = await makeAgent()
        let oldSession = await original.createSession(title: "Old")
        let replacement = await makeAgent()
        let newSession = await replacement.createSession(title: "New")
        let controller = AppAgentViewController()
        controller.agent = original
        controller.switchSession(to: oldSession.id)
        let entered = expectation(description: "旧 agent 等待")
        var resume: CheckedContinuation<Void, Never>?
        let task = Task { @MainActor in
            await controller.archiveSessionFromSidebar(oldSession.id, archive: { id in
                await withCheckedContinuation { resume = $0; entered.fulfill() }
                try await original.sessionManager.archiveSession(id)
            })
        }
        await fulfillment(of: [entered], timeout: 2)
        controller.agent = replacement
        controller.switchSession(to: newSession.id)
        resume?.resume()
        await task.value
        XCTAssertTrue(controller.currentSession === newSession)
        XCTAssertEqual(replacement.allSessions.count, 1)
    }

    func testAgentRebindImmediatelyUnlocksAndOldArchiveCompletionCannotUnlockNewOperation() async throws {
        let original = await makeAgent()
        let oldSession = await original.createSession(title: "Old")
        let replacement = await makeAgent()
        let newSession = await replacement.createSession(title: "New")
        let controller = AppAgentViewController()
        controller.agent = original
        controller.switchSession(to: oldSession.id)

        let oldEntered = expectation(description: "旧归档等待")
        var resumeOld: CheckedContinuation<Void, Never>?
        let oldTask = Task { @MainActor in
            await controller.archiveSessionFromSidebar(oldSession.id, archive: { _ in
                await withCheckedContinuation {
                    resumeOld = $0
                    oldEntered.fulfill()
                }
            })
        }
        await fulfillment(of: [oldEntered], timeout: 2)
        let oldToken = try XCTUnwrap(controller.archiveOperationToken)
        XCTAssertEqual(controller.sessionSidebarView.sessionListView.archivingSessionID, oldSession.id)

        controller.agent = replacement
        XCTAssertNil(controller.archiveOperationToken)
        XCTAssertNil(controller.sessionSidebarView.sessionListView.archivingSessionID)

        controller.switchSession(to: newSession.id)
        let newEntered = expectation(description: "新归档等待")
        var resumeNew: CheckedContinuation<Void, Never>?
        let newTask = Task { @MainActor in
            await controller.archiveSessionFromSidebar(newSession.id, archive: { _ in
                await withCheckedContinuation {
                    resumeNew = $0
                    newEntered.fulfill()
                }
                throw StorageFailure()
            })
        }
        await fulfillment(of: [newEntered], timeout: 2)
        let newToken = try XCTUnwrap(controller.archiveOperationToken)
        XCTAssertNotEqual(oldToken, newToken)

        resumeOld?.resume()
        await oldTask.value
        XCTAssertEqual(controller.archiveOperationToken, newToken)
        XCTAssertEqual(
            controller.sessionSidebarView.sessionListView.archivingSessionID,
            newSession.id
        )
        XCTAssertNil(controller.sessionSidebarView.sessionListView.archiveError)

        resumeNew?.resume()
        await newTask.value
        XCTAssertNil(controller.archiveOperationToken)
        XCTAssertNil(controller.sessionSidebarView.sessionListView.archivingSessionID)
        XCTAssertTrue(controller.sessionSidebarView.sessionListView.archiveError?.contains("磁盘不可写") == true)
    }

    func testAgentRebindDuringCreateSessionCannotClearNewOperation() async throws {
        let original = await makeAgent()
        let oldSession = await original.createSession(title: "Only Old")
        let replacement = await makeAgent()
        let newSession = await replacement.createSession(title: "New")
        let controller = AppAgentViewController()
        controller.agent = original
        controller.switchSession(to: oldSession.id)

        let createEntered = expectation(description: "旧创建新会话等待")
        var resumeCreate: CheckedContinuation<Void, Never>?
        let oldTask = Task { @MainActor in
            await controller.archiveSessionFromSidebar(oldSession.id, archive: { _ in }, createSession: {
                await withCheckedContinuation {
                    resumeCreate = $0
                    createEntered.fulfill()
                }
                return await original.createSession(title: "迟到会话")
            })
        }
        await fulfillment(of: [createEntered], timeout: 2)
        XCTAssertEqual(controller.sessionSidebarView.sessionListView.archivingSessionID, oldSession.id)

        controller.agent = replacement
        XCTAssertNil(controller.sessionSidebarView.sessionListView.archivingSessionID)
        controller.switchSession(to: newSession.id)

        let newEntered = expectation(description: "新归档等待")
        var resumeNew: CheckedContinuation<Void, Never>?
        let newTask = Task { @MainActor in
            await controller.archiveSessionFromSidebar(newSession.id, archive: { _ in
                await withCheckedContinuation {
                    resumeNew = $0
                    newEntered.fulfill()
                }
                throw StorageFailure()
            })
        }
        await fulfillment(of: [newEntered], timeout: 2)
        let newToken = try XCTUnwrap(controller.archiveOperationToken)
        resumeCreate?.resume()
        await oldTask.value
        XCTAssertEqual(controller.archiveOperationToken, newToken)
        XCTAssertEqual(controller.sessionSidebarView.sessionListView.archivingSessionID, newSession.id)

        resumeNew?.resume()
        await newTask.value
        XCTAssertNil(controller.archiveOperationToken)
        XCTAssertNil(controller.sessionSidebarView.sessionListView.archivingSessionID)
    }

    func testLoadRendersRowsWithoutAutomaticallyRestoringOrPurging() async throws {
        let old = snapshot("old", updated: 1)
        let recent = snapshot("recent", title: " \n", updated: 2)
        var writes = 0
        let controller = AppAgentSessionTrashViewController(operations: .init(
            load: { [old, recent] }, restore: { _ in writes += 1 }, purge: { _ in writes += 1 }
        ))
        controller.loadViewIfNeeded()
        await controller.operationTask?.value
        XCTAssertEqual(controller.snapshots.map(\.id), ["recent", "old"])
        XCTAssertEqual(writes, 0)
        let table = try table(in: controller.view)
        XCTAssertEqual(controller.tableView(table, numberOfRowsInSection: 0), 2)
        let cell = controller.tableView(table, cellForRowAt: IndexPath(row: 0, section: 0))
        let content = try XCTUnwrap(cell.contentConfiguration as? UIListContentConfiguration)
        XCTAssertEqual(content.text, "未命名会话")
        XCTAssertTrue(content.secondaryText?.contains("1 条消息") == true)
        XCTAssertTrue(content.secondaryText?.contains("最后更新") == true)
        controller.invalidateForDismissal()
        XCTAssertEqual(writes, 0)
    }

    func testLoadFailureIsVisibleAndCanRetry() async throws {
        var attempts = 0
        let controller = AppAgentSessionTrashViewController(operations: .init(
            load: {
                attempts += 1
                if attempts == 1 { throw StorageFailure() }
                return []
            }, restore: { _ in XCTFail("加载不能恢复") }, purge: { _ in XCTFail("加载不能永久删除") }
        ))
        controller.loadViewIfNeeded()
        await controller.operationTask?.value
        XCTAssertTrue(controller.statusMessage?.contains("加载废纸篓失败：磁盘不可写") == true)
        controller.reloadSessions()
        await controller.operationTask?.value
        XCTAssertEqual(attempts, 2)
        XCTAssertNil(controller.statusMessage)
        XCTAssertNotNil((try table(in: controller.view)).backgroundView as? UILabel)
    }

    func testDefaultActionSheetConstructionDoesNotPurge() async throws {
        let archived = snapshot("a")
        var writes = 0
        let controller = AppAgentSessionTrashViewController(operations: .init(
            load: { [archived] }, restore: { _ in writes += 1 }, purge: { _ in writes += 1 }
        ))
        controller.loadViewIfNeeded()
        await controller.operationTask?.value
        let anchor = UIView()
        // 不注入 fixture，覆盖 Catalyst 的真实非 popover 路径，构造过程不得抛 UIKit 异常。
        let sheet = try XCTUnwrap(controller.makeSessionActions(
            for: "a", sourceView: anchor, sourceRect: anchor.bounds
        ))
        XCTAssertEqual(sheet.preferredStyle, .actionSheet)
        XCTAssertEqual(sheet.actions.map(\.title), ["恢复会话", "永久删除…", "取消"])
        XCTAssertEqual(sheet.actions.map(\.style), [.default, .destructive, .cancel])
        XCTAssertNil(controller.pendingDeletion)
        XCTAssertEqual(writes, 0)
        controller.invalidateForDismissal()
        XCTAssertEqual(writes, 0)
    }

    func testActionSheetHasPopoverSourceAndDoesNotPurge() async throws {
        let archived = snapshot("a")
        var purges = 0
        let controller = AppAgentSessionTrashViewController(operations: .init(
            load: { [archived] }, restore: { _ in }, purge: { _ in purges += 1 }
        ))
        controller.loadViewIfNeeded()
        await controller.operationTask?.value
        let anchor = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 60))
        let (sheet, popover) = try makeActionsWithPopover(controller: controller, id: "a", anchor: anchor)
        XCTAssertEqual(sheet.preferredStyle, .actionSheet)
        XCTAssertEqual(sheet.actions.map(\.title), ["恢复会话", "永久删除…", "取消"])
        XCTAssertTrue(popover.sourceView === anchor)
        XCTAssertEqual(popover.sourceRect, anchor.bounds)
        XCTAssertNil(controller.pendingDeletion)
        XCTAssertEqual(purges, 0)
        XCTAssertNil(controller.makeSessionActions(for: "a", sourceView: anchor, sourceRect: anchor.bounds))
        controller.invalidateForDismissal()
        XCTAssertEqual(purges, 0)
    }

    func testActionSheetAdaptiveDismissalUnlocksWithoutClosingTrash() async throws {
        try await checkActionSheetDismissal(adaptive: true)
    }

    func testActionSheetPopoverDismissalUnlocksWithoutClosingTrash() async throws {
        try await checkActionSheetDismissal(adaptive: false)
    }

    private func checkActionSheetDismissal(adaptive: Bool) async throws {
        let archived = snapshot("a")
        var writes = 0
        var changes = 0
        let controller = AppAgentSessionTrashViewController(operations: .init(
            load: { [archived] }, restore: { _ in writes += 1 }, purge: { _ in writes += 1 }
        ))
        controller.onSessionsChanged = { changes += 1 }
        controller.loadViewIfNeeded()
        await controller.operationTask?.value
        let table = try table(in: controller.view)
        let anchor = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 60))
        let (_, firstPopover) = try makeActionsWithPopover(controller: controller, id: "a", anchor: anchor)
        // 从实际接线读取 popover delegate；它独立于废纸篓自身的关闭 delegate。
        let popoverDelegate = try XCTUnwrap(firstPopover.delegate)
        XCTAssertFalse(table.isUserInteractionEnabled)
        XCTAssertEqual(controller.navigationItem.rightBarButtonItem?.isEnabled, false)
        // 不 present、不构建 UIWindow；分别模拟自适应 dismissal 和 iPad popover 外点取消。
        // iOS 13 起两者都由 UIKit 走 `UIAdaptivePresentationControllerDelegate` 的
        // `presentationControllerDidDismiss(_:)`，差别只在交回来的 presentationController
        // 是自适应后的容器还是 popover 本体 —— 生产侧两条回调都只做 consumeActionSheet(token)。
        let dismissedController: UIPresentationController = adaptive
            ? UIPresentationController(
                presentedViewController: UIViewController(), presenting: nil
            )
            : firstPopover
        popoverDelegate.presentationControllerDidDismiss?(dismissedController)
        XCTAssertFalse(controller.isClosed)
        XCTAssertNotNil(controller.onSessionsChanged)
        XCTAssertTrue(table.isUserInteractionEnabled)
        XCTAssertEqual(controller.navigationItem.rightBarButtonItem?.isEnabled, true)
        XCTAssertNil(controller.pendingDeletion)
        XCTAssertEqual(writes, 0)

        let (_, secondPopover) = try makeActionsWithPopover(controller: controller, id: "a", anchor: anchor)
        let secondDelegate = try XCTUnwrap(secondPopover.delegate)
        XCTAssertFalse(secondDelegate === popoverDelegate, "每张 sheet 必须绑定自己的 token")
        for _ in 0..<2 {
            popoverDelegate.presentationControllerDidDismiss?(firstPopover)
        }
        XCTAssertFalse(controller.isClosed)
        XCTAssertFalse(table.isUserInteractionEnabled)
        XCTAssertEqual(controller.navigationItem.rightBarButtonItem?.isEnabled, false)
        XCTAssertNil(controller.makeSessionActions(for: "a", sourceView: anchor, sourceRect: anchor.bounds))
        XCTAssertNil(controller.makeDeletionConfirmation(for: "a"))
        secondDelegate.presentationControllerDidDismiss?(secondPopover)

        // sheet 的迟到通知不代表取消 / 接受人工二次确认，更不能自动 purge。
        _ = try XCTUnwrap(controller.makeDeletionConfirmation(for: "a"))
        let confirmationToken = try XCTUnwrap(controller.pendingDeletion?.token)
        popoverDelegate.presentationControllerDidDismiss?(firstPopover)
        secondDelegate.presentationControllerDidDismiss?(secondPopover)
        XCTAssertEqual(controller.pendingDeletion?.token, confirmationToken)
        XCTAssertFalse(table.isUserInteractionEnabled)
        XCTAssertNil(controller.operationTask)
        XCTAssertEqual(writes, 0)
        controller.confirmDeletion(token: confirmationToken)
        await controller.operationTask?.value
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(changes, 1, "sheet 关闭不能清掉废纸篓的变更回调")
        XCTAssertFalse(controller.isClosed)
        controller.invalidateForDismissal()
    }

    func testOnlyTrashContainerDismissalClosesController() async throws {
        let archived = snapshot("a")
        var writes = 0
        let controller = AppAgentSessionTrashViewController(operations: .init(
            load: { [archived] }, restore: { _ in writes += 1 }, purge: { _ in writes += 1 }
        ))
        let navigation = AppAgentSessionTrashNavigationController(rootViewController: controller)
        controller.loadViewIfNeeded()
        await controller.operationTask?.value
        _ = try XCTUnwrap(controller.makeDeletionConfirmation(for: "a"))
        let token = try XCTUnwrap(controller.pendingDeletion?.token)
        let unrelated = UIPresentationController(
            presentedViewController: UIViewController(), presenting: UIViewController()
        )
        controller.presentationControllerDidDismiss(unrelated)
        XCTAssertFalse(controller.isClosed)
        XCTAssertEqual(controller.pendingDeletion?.token, token)
        let container = UIPresentationController(
            presentedViewController: navigation, presenting: UIViewController()
        )
        controller.presentationControllerDidDismiss(container)
        XCTAssertTrue(controller.isClosed)
        XCTAssertNil(controller.pendingDeletion)
        controller.confirmDeletion(token: token)
        XCTAssertEqual(writes, 0)
    }

    func testPermanentDeleteRequiresFreshConfirmationAndRunsOnce() async throws {
        let archived = snapshot("a")
        var purges = 0
        var changed = 0
        let controller = AppAgentSessionTrashViewController(operations: .init(
            load: { [archived] }, restore: { _ in }, purge: { id in
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertEqual(id, "a")
                purges += 1
            }
        ))
        controller.onSessionsChanged = { changed += 1 }
        controller.loadViewIfNeeded()
        await controller.operationTask?.value
        controller.confirmDeletion(token: UUID())
        XCTAssertEqual(purges, 0)
        let alert = try XCTUnwrap(controller.makeDeletionConfirmation(for: "a"))
        let cancelled = try XCTUnwrap(controller.pendingDeletion?.token)
        XCTAssertEqual(alert.preferredStyle, .alert)
        XCTAssertTrue(alert.message?.contains("不可恢复") == true)
        XCTAssertEqual(alert.actions.map(\.title), ["取消", "永久删除"])
        XCTAssertEqual(alert.actions.last?.style, .destructive)
        XCTAssertEqual(purges, 0)
        controller.cancelDeletion(token: cancelled)
        controller.confirmDeletion(token: cancelled)
        XCTAssertNil(controller.operationTask)
        _ = try XCTUnwrap(controller.makeDeletionConfirmation(for: "a"))
        let confirmed = try XCTUnwrap(controller.pendingDeletion?.token)
        controller.confirmDeletion(token: cancelled)
        XCTAssertEqual(controller.pendingDeletion?.token, confirmed)
        controller.confirmDeletion(token: confirmed)
        controller.confirmDeletion(token: confirmed)
        XCTAssertTrue(controller.isMutating)
        XCTAssertTrue(controller.isModalInPresentation)
        controller.close()
        XCTAssertFalse(controller.isClosed, "写入未完成时禁用退出")
        await controller.operationTask?.value
        XCTAssertEqual(purges, 1)
        XCTAssertEqual(changed, 1)
        XCTAssertTrue(controller.snapshots.isEmpty)
        XCTAssertFalse(controller.isMutating)
        XCTAssertFalse(controller.responds(to: NSSelectorFromString("confirmDeletionWithToken:")))
        XCTAssertFalse(controller.responds(to: NSSelectorFromString("purgeArchivedSession:")))
    }

    func testRestoreAndPurgeFailuresRetainRowsAndShowSpecificErrors() async throws {
        let archived = snapshot("a")
        var changed = 0
        let controller = AppAgentSessionTrashViewController(operations: .init(
            load: { [archived] },
            restore: { _ in throw StorageFailure() },
            purge: { _ in throw StorageFailure() }
        ))
        controller.onSessionsChanged = { changed += 1 }
        controller.loadViewIfNeeded()
        await controller.operationTask?.value
        controller.restoreSession("a")
        await controller.operationTask?.value
        XCTAssertEqual(controller.snapshots.map(\.id), ["a"])
        XCTAssertEqual(controller.statusMessage, "恢复失败：磁盘不可写")
        _ = try XCTUnwrap(controller.makeDeletionConfirmation(for: "a"))
        controller.confirmDeletion(token: try XCTUnwrap(controller.pendingDeletion?.token))
        await controller.operationTask?.value
        XCTAssertEqual(controller.snapshots.map(\.id), ["a"])
        XCTAssertEqual(controller.statusMessage, "永久删除失败：磁盘不可写")
        XCTAssertEqual(changed, 0)
        XCTAssertFalse(controller.isMutating)
    }

    func testRestoreRunsOnceAndCloseDoesNotSwitchActiveConversation() async throws {
        let agent = await makeAgent()
        let archived = await agent.createSession(title: "Archived")
        let active = await agent.createSession(title: "Active")
        try await agent.sessionManager.archiveSession(archived.id)
        let chat = AppAgentViewController()
        chat.agent = agent
        chat.switchSession(to: active.id)
        let controller = AppAgentSessionTrashViewController(sessionManager: agent.sessionManager)
        var changed = 0
        controller.onSessionsChanged = { changed += 1 }
        controller.loadViewIfNeeded()
        await controller.operationTask?.value
        controller.restoreSession(archived.id)
        controller.restoreSession(archived.id)
        await controller.operationTask?.value
        XCTAssertEqual(changed, 1)
        XCTAssertNotNil(agent.session(id: archived.id))
        XCTAssertTrue(controller.snapshots.isEmpty)
        controller.invalidateForDismissal()
        XCTAssertTrue(chat.currentSession === active)
    }

    func testClosingInvalidatesPendingConfirmationAndLateLoad() async throws {
        let archived = snapshot("a")
        let entered = expectation(description: "读取挂起")
        var resume: CheckedContinuation<Void, Never>?
        var purges = 0
        let controller = AppAgentSessionTrashViewController(operations: .init(
            load: {
                await withCheckedContinuation { resume = $0; entered.fulfill() }
                return [archived] // 故意忽略 Task 取消，模拟已进入存储的迟到回调。
            }, restore: { _ in }, purge: { _ in purges += 1 }
        ))
        controller.loadViewIfNeeded()
        let task = controller.operationTask
        await fulfillment(of: [entered], timeout: 2)
        controller.invalidateForDismissal()
        resume?.resume()
        await task?.value
        XCTAssertTrue(controller.snapshots.isEmpty)
        XCTAssertNil(controller.makeDeletionConfirmation(for: "a"))
        XCTAssertEqual(purges, 0)

        let loaded = AppAgentSessionTrashViewController(operations: .init(
            load: { [archived] }, restore: { _ in }, purge: { _ in purges += 1 }
        ))
        loaded.loadViewIfNeeded()
        await loaded.operationTask?.value
        _ = try XCTUnwrap(loaded.makeDeletionConfirmation(for: "a"))
        let token = try XCTUnwrap(loaded.pendingDeletion?.token)
        loaded.invalidateForDismissal()
        loaded.confirmDeletion(token: token)
        XCTAssertNil(loaded.operationTask)
        XCTAssertEqual(purges, 0)
    }

    func testLateMutationCompletionCannotNotifyClosedInterface() async throws {
        let archived = snapshot("a")
        let entered = expectation(description: "恢复挂起")
        var resume: CheckedContinuation<Void, Never>?
        var changes = 0
        let controller = AppAgentSessionTrashViewController(operations: .init(
            load: { [archived] },
            restore: { _ in await withCheckedContinuation { resume = $0; entered.fulfill() } },
            purge: { _ in XCTFail("不能自动清空") }
        ))
        controller.onSessionsChanged = { changes += 1 }
        controller.loadViewIfNeeded()
        await controller.operationTask?.value
        controller.restoreSession("a")
        let task = controller.operationTask
        await fulfillment(of: [entered], timeout: 2)
        controller.invalidateForDismissal() // 宿主强制移除界面，不是普通完成按钮。
        resume?.resume()
        await task?.value
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(controller.snapshots.map(\.id), ["a"])
    }
}
#endif
