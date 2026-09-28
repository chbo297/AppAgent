#if canImport(UIKit)
import UIKit

/// 与设置 / 调试共用现有呈现层级，不创建窗口；容器本身也明确属于 SDK。
final class AppAgentSessionTrashNavigationController: UINavigationController, AppAgentRuntimeOwned {}

/// 仅供人工管理归档会话。写操作不注册工具，也不导出 ObjC selector。
@MainActor
final class AppAgentSessionTrashViewController: UIViewController, AppAgentRuntimeOwned {
    struct Operations {
        var load: @MainActor () async throws -> [SessionSnapshot]
        var restore: @MainActor (String) async throws -> Void
        var purge: @MainActor (String) async throws -> Void
    }

    struct DeletionConfirmation {
        let sessionID: String
        let token: UUID
    }

    /// 操作菜单的关闭只消费它自己的 token，不能走外层废纸篓的关闭回调。
    @MainActor
    private final class ActionSheetDismissalDelegate: NSObject, UIPopoverPresentationControllerDelegate {
        private weak var owner: AppAgentSessionTrashViewController?
        private let token: UUID

        init(owner: AppAgentSessionTrashViewController, token: UUID) {
            self.owner = owner
            self.token = token
            super.init()
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            _ = owner?.consumeActionSheet(token)
        }

        func popoverPresentationControllerDidDismissPopover(
            _ popoverPresentationController: UIPopoverPresentationController
        ) {
            _ = owner?.consumeActionSheet(token)
        }
    }

    var onSessionsChanged: (() -> Void)?
    private(set) var snapshots: [SessionSnapshot] = []
    private(set) var statusMessage: String?
    private(set) var isLoading = false
    private(set) var isMutating = false
    private(set) var isClosed = false
    private(set) var pendingDeletion: DeletionConfirmation?
    private(set) var operationTask: Task<Void, Never>?

    private let operations: Operations
    private var operationID: UUID?
    private var actionSheetToken: UUID?
    // UIKit 弱持有 presentation delegate，至少保留到该 sheet 的 token 被消费。
    private var actionSheetDismissalDelegate: ActionSheetDismissalDelegate?
    private var statusIsError = false
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let statusLabel = UILabel()
    private let emptyLabel = UILabel()
    private let retryButton = UIButton(type: .system)

    convenience init(sessionManager: AISessionManager) {
        self.init(operations: Operations(
            load: { try await sessionManager.archivedSessions() },
            restore: { _ = try await sessionManager.restoreArchivedSession($0) },
            purge: { try await sessionManager.purgeArchivedSession($0) }
        ))
    }

    init(operations: Operations) {
        self.operations = operations
        super.init(nibName: nil, bundle: nil)
        title = "废纸篓"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "完成", primaryAction: UIAction { [weak self] _ in self?.close() }
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "刷新", primaryAction: UIAction { [weak self] _ in self?.reloadSessions() }
        )

        let explanation = UILabel()
        explanation.text = "已归档的会话可恢复。轻点会话进行操作。\n废纸篓不会自动清空；永久删除后不可恢复。"
        explanation.font = .preferredFont(forTextStyle: .footnote)
        explanation.textColor = .secondaryLabel
        explanation.numberOfLines = 0
        explanation.adjustsFontForContentSizeCategory = true
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.numberOfLines = 0
        statusLabel.accessibilityIdentifier = "session_trash_status"
        retryButton.setTitle("重新加载", for: .normal)
        retryButton.addAction(UIAction { [weak self] _ in self?.reloadSessions() }, for: .touchUpInside)
        let header = UIStackView(arrangedSubviews: [explanation, statusLabel, retryButton])
        header.axis = .vertical
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)

        emptyLabel.text = "废纸篓为空"
        emptyLabel.textAlignment = .center
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.font = .preferredFont(forTextStyle: .body)
        emptyLabel.adjustsFontForContentSizeCategory = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 84
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.accessibilityIdentifier = "session_trash_list"
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            tableView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        reloadSessions()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // 弹 action sheet 不是关闭；只在整个管理界面离开时废弃异步回调。
        if isBeingDismissed || navigationController?.isBeingDismissed == true || isMovingFromParent {
            invalidateForDismissal()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.presentationController?.delegate = self
    }

    @nonobjc
    func reloadSessions() {
        guard canStartOperation else { return }
        isLoading = true
        let token = beginOperation(message: "正在加载废纸篓…")
        let load = operations.load
        operationTask = Task { @MainActor [weak self] in
            guard self?.accepts(token) == true else { return }
            do {
                let snapshots = try await load()
                guard let self, self.accepts(token) else { return }
                self.snapshots = snapshots.sorted {
                    $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt
                }
                self.endOperation(message: nil)
            } catch {
                guard let self, self.accepts(token) else { return }
                self.endOperation(message: "加载废纸篓失败：\(error.localizedDescription)", isError: true)
            }
        }
    }

    /// 第二次人工确认的凭据由 UI 生成；旧弹窗 / 重复点击不能复用它。
    @nonobjc
    func makeDeletionConfirmation(for id: String) -> UIAlertController? {
        guard canStartOperation, let snapshot = snapshots.first(where: { $0.id == id }) else { return nil }
        let confirmation = DeletionConfirmation(sessionID: id, token: UUID())
        pendingDeletion = confirmation
        render()
        let alert = UIAlertController(
            title: "永久删除会话？",
            message: "永久删除「\(Self.displayTitle(snapshot.title))」及其全部消息？此操作不可恢复，无法撤销。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
            self?.cancelDeletion(token: confirmation.token)
        })
        alert.addAction(UIAlertAction(title: "永久删除", style: .destructive) { [weak self] _ in
            self?.confirmDeletion(token: confirmation.token)
        })
        return alert
    }

    @nonobjc
    func cancelDeletion(token: UUID) {
        guard pendingDeletion?.token == token else { return }
        pendingDeletion = nil
        render()
    }

    @nonobjc
    func confirmDeletion(token: UUID) {
        guard !isClosed, let confirmation = pendingDeletion,
              confirmation.token == token, operationID == nil else { return }
        pendingDeletion = nil // 在 Task 创建前消费，挡住双击和已关闭弹窗的迟到回调。
        performMutation(id: confirmation.sessionID, permanently: true)
    }

    @nonobjc
    func restoreSession(_ id: String) {
        performMutation(id: id, permanently: false)
    }

    @nonobjc
    private func performMutation(id: String, permanently: Bool) {
        guard canStartOperation, snapshots.contains(where: { $0.id == id }) else { return }
        isMutating = true
        let action = permanently ? "永久删除" : "恢复"
        let token = beginOperation(message: "正在\(action)…")
        let operation = permanently ? operations.purge : operations.restore
        operationTask = Task { @MainActor [weak self] in
            guard self?.accepts(token) == true else { return }
            do {
                try await operation(id)
                guard let self, self.accepts(token) else { return }
                self.snapshots.removeAll { $0.id == id }
                self.endOperation(message: permanently ? "会话已永久删除。" : "会话已恢复，可返回会话列表继续对话。")
                self.onSessionsChanged?()
            } catch {
                guard let self, self.accepts(token) else { return }
                // 不乐观移除行，也不重试写操作；失败后由用户自行决定下一步。
                self.endOperation(message: "\(action)失败：\(error.localizedDescription)", isError: true)
            }
        }
    }

    @nonobjc
    func makeSessionActions(
        for id: String,
        sourceView: UIView,
        sourceRect: CGRect,
        popoverProvider: @MainActor (UIAlertController) -> UIPopoverPresentationController? = {
            $0.popoverPresentationController
        }
    ) -> UIAlertController? {
        guard canStartOperation, let snapshot = snapshots.first(where: { $0.id == id }) else { return nil }
        let token = UUID()
        actionSheetToken = token
        let dismissalDelegate = ActionSheetDismissalDelegate(owner: self, token: token)
        actionSheetDismissalDelegate = dismissalDelegate
        render()
        let sheet = UIAlertController(
            title: Self.displayTitle(snapshot.title), message: "已归档会话", preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: "恢复会话", style: .default) { [weak self] _ in
            guard let self, self.consumeActionSheet(token) else { return }
            self.restoreSession(id)
        })
        sheet.addAction(UIAlertAction(title: "永久删除…", style: .destructive) { [weak self] _ in
            guard let self, self.consumeActionSheet(token),
                  let confirmation = self.makeDeletionConfirmation(for: id),
                  let confirmationToken = self.pendingDeletion?.token else { return }
            // 等第一层 action sheet 完全收起后再呈现二次确认，不能叠在转场中的弹窗上。
            let show = { [weak self] in
                guard let self, !self.isClosed,
                      self.pendingDeletion?.token == confirmationToken else { return }
                self.present(confirmation, animated: true)
            }
            if let presented = self.presentedViewController {
                presented.dismiss(animated: true, completion: show)
            } else {
                show()
            }
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
            _ = self?.consumeActionSheet(token)
        })
        // iPad / Catalyst 必须有锚点；不需要也不允许为操作菜单创建新 window。
        // 非 popover 呈现（如 Catalyst alert）由 Cancel action 消费 token。
        // popover 额外接收外点取消和自适应 dismissal；始终绑定此 sheet 的 delegate。
        // 不设置 presentationController.delegate：UIAlertController 在 alert
        // 呈现形态下禁止修改这个通用 delegate。
        if let popover = popoverProvider(sheet) {
            popover.sourceView = sourceView
            popover.sourceRect = sourceRect
            popover.delegate = dismissalDelegate
        }
        return sheet
    }

    @nonobjc
    private func consumeActionSheet(_ token: UUID) -> Bool {
        guard !isClosed, actionSheetToken == token else { return false }
        actionSheetToken = nil
        actionSheetDismissalDelegate = nil
        render()
        return true
    }

    @nonobjc
    func close() {
        guard !isMutating, !isClosed else { return }
        invalidateForDismissal()
        dismiss(animated: true)
    }

    /// 关闭后即使底层忽略取消并完成写入，也不能再触发 UI 回调或操纵当前会话。
    @nonobjc
    func invalidateForDismissal() {
        guard !isClosed else { return }
        isClosed = true
        operationID = nil
        actionSheetToken = nil
        actionSheetDismissalDelegate = nil
        pendingDeletion = nil
        operationTask?.cancel()
        operationTask = nil
        onSessionsChanged = nil
    }

    private var canStartOperation: Bool {
        !isClosed && operationID == nil && pendingDeletion == nil && actionSheetToken == nil
    }

    private func beginOperation(message: String) -> UUID {
        let token = UUID()
        operationID = token
        statusMessage = message
        statusIsError = false
        render()
        return token
    }

    private func accepts(_ token: UUID) -> Bool {
        !isClosed && operationID == token && !Task.isCancelled
    }

    private func endOperation(message: String?, isError: Bool = false) {
        operationID = nil
        operationTask = nil
        isLoading = false
        isMutating = false
        statusMessage = message
        statusIsError = isError
        render()
    }

    private func render() {
        guard isViewLoaded else { return }
        statusLabel.text = statusMessage
        statusLabel.textColor = statusIsError ? .systemRed : .secondaryLabel
        statusLabel.isHidden = statusMessage == nil
        retryButton.isHidden = !statusIsError
        retryButton.isEnabled = canStartOperation
        navigationItem.rightBarButtonItem?.isEnabled = canStartOperation
        navigationItem.leftBarButtonItem?.isEnabled = !isMutating
        // 写入期间不能手动退出再重复提交；加载期间可以关闭，回调会失效。
        isModalInPresentation = isMutating
        navigationController?.isModalInPresentation = isMutating
        tableView.isUserInteractionEnabled = canStartOperation
        tableView.backgroundView = snapshots.isEmpty && !isLoading && !statusIsError ? emptyLabel : nil
        tableView.reloadData()
    }

    private static func displayTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名会话" : trimmed
    }
}

extension AppAgentSessionTrashViewController: UITableViewDataSource, UITableViewDelegate, UIAdaptivePresentationControllerDelegate {
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard let navigationController,
              presentationController.presentedViewController === navigationController else { return }
        invalidateForDismissal()
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { snapshots.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "ArchivedSession")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "ArchivedSession")
        let snapshot = snapshots[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = Self.displayTitle(snapshot.title)
        content.textProperties.numberOfLines = 2
        let updated = DateFormatter.localizedString(from: snapshot.updatedAt, dateStyle: .short, timeStyle: .short)
        content.secondaryText = "\(snapshot.messages.count) 条消息 · 最后更新 \(updated)"
        content.secondaryTextProperties.numberOfLines = 2
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityHint = "轻点可恢复或永久删除会话"
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        guard snapshots.indices.contains(indexPath.row), presentedViewController == nil,
              let sheet = makeSessionActions(
                for: snapshots[indexPath.row].id, sourceView: tableView,
                sourceRect: tableView.rectForRow(at: indexPath)
              ) else { return }
        present(sheet, animated: true)
    }
}
#endif
