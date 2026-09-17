//
//  AppAgentSettingsViewController.swift
//  AppAgentUI
//
//  AppAgent 层级内的「设置」面板：配置一个大模型接口（baseURL + apiKey）。
//  「探查接口」会并行询问 OpenAI / Anthropic 两种协议各声明支持哪些模型，展开成
//  「模型 × 协议」列表（同一模型支持两种协议时列为两条），再并行发一次最小请求实测
//  真实可用性：绿点可用（附首 token 时长）、红点不可用。
//  用户勾选启用并拖拽排序，顺序即优先级：[0] 为默认模型，其余按序作为回退。
//

#if canImport(UIKit)
import UIKit

public final class AppAgentSettingsViewController: UIViewController {

    /// 用户点击「保存」并通过校验后回调，携带最新设置（此时已写入本地存储）。
    public var onSave: ((AppAgentEndpointSettings) -> Void)?

    /// 单条模型（模型 × 协议）的实测状态。
    private enum ProbeState {
        case untested
        case testing
        /// 可用，附首 token 返回时长（秒）。
        case available(TimeInterval)
        /// 不可用，附简短原因。
        case unavailable(String)
    }

    /// 模型行的可编辑工作态：候选（模型 id + 协议）、是否勾选启用、实测状态。
    private struct ModelRow {
        var candidate: AppAgentModelCandidate
        var enabled: Bool
        var probe: ProbeState = .untested
    }

    // 工作态（编辑期间的可变副本；保存时组装回 AppAgentEndpointSettings）。
    private var baseURL: String
    private var apiKey: String
    private var customHeaders: [String: String]
    private var contextWindow: Int
    private var maxTokens: Int
    private var modelRows: [ModelRow]
    /// 探查 / 实测进行中，避免重复触发。
    private var isBusy = false

    private let tableView = UITableView(frame: .zero, style: .grouped)
    private let baseURLField = UITextField()
    private let apiKeyField = UITextField()
    /// apiKey 输入框右侧的「探查接口」按钮。
    private let apiKeyProbeButton = UIButton(type: .system)

    private enum Section: Int, CaseIterable { case endpoint, models }

    public init(settings: AppAgentEndpointSettings = AppAgentSettingsStore.loadOrDefault()) {
        baseURL = settings.baseURL
        apiKey = settings.apiKey
        customHeaders = settings.customHeaders
        contextWindow = settings.contextWindow
        maxTokens = settings.maxTokens
        modelRows = settings.enabledModels.map {
            ModelRow(
                candidate: AppAgentModelCandidate(modelId: $0.modelId, apiProtocol: $0.apiProtocol),
                enabled: true
            )
        }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        let settings = AppAgentSettingsStore.loadOrDefault()
        baseURL = settings.baseURL
        apiKey = settings.apiKey
        customHeaders = settings.customHeaders
        contextWindow = settings.contextWindow
        maxTokens = settings.maxTokens
        modelRows = settings.enabledModels.map {
            ModelRow(
                candidate: AppAgentModelCandidate(modelId: $0.modelId, apiProtocol: $0.apiProtocol),
                enabled: true
            )
        }
        super.init(coder: coder)
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = "AppAgent 设置"
        view.backgroundColor = AppAgentAppearance.overlayBackground

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(didTapCancel)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .save, target: self, action: #selector(didTapSave)
        )

        tableView.frame = view.bounds
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView.backgroundColor = .clear
        tableView.keyboardDismissMode = .interactive
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsSelectionDuringEditing = true
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        // 常驻编辑态：拖拽把手始终可见，勾选仍走点击。
        tableView.isEditing = true
        view.addSubview(tableView)

        configureField(baseURLField, placeholder: "接口地址，如 https://.../v1", secure: false)
        baseURLField.keyboardType = .URL
        baseURLField.text = baseURL
        baseURLField.addTarget(self, action: #selector(baseURLChanged), for: .editingChanged)

        configureField(apiKeyField, placeholder: "在此填写你的 API Key", secure: true)
        apiKeyField.text = apiKey
        apiKeyField.addTarget(self, action: #selector(apiKeyChanged), for: .editingChanged)

        // apiKey 右侧「探查接口」按钮（让位给它，关掉清除按钮）。
        apiKeyField.clearButtonMode = .never
        let probeIcon = UIImage(systemName: "sparkle.magnifyingglass") ?? UIImage(systemName: "magnifyingglass")
        apiKeyProbeButton.setImage(probeIcon, for: .normal)
        apiKeyProbeButton.tintColor = AppAgentAppearance.accent
        apiKeyProbeButton.accessibilityLabel = "探查接口支持的模型并实测可用性"
        apiKeyProbeButton.frame = CGRect(x: 0, y: 0, width: 34, height: 26)
        apiKeyProbeButton.addTarget(self, action: #selector(didTapProbe), for: .touchUpInside)
        apiKeyField.rightView = apiKeyProbeButton
        apiKeyField.rightViewMode = .always
    }

    // MARK: - Helpers

    private func configureField(_ field: UITextField, placeholder: String, secure: Bool) {
        field.placeholder = placeholder
        field.font = .systemFont(ofSize: 15)
        field.textColor = AppAgentAppearance.primaryText
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.clearButtonMode = .whileEditing
        field.isSecureTextEntry = secure
        field.returnKeyType = .done
        field.delegate = self
    }

    static func protocolDisplayName(_ p: APIProtocol) -> String {
        switch p {
        case .anthropicMessages: return "Anthropic"
        case .openaiCompletions: return "OpenAI"
        default: return p.rawValue
        }
    }

    private func currentSettings() -> AppAgentEndpointSettings {
        AppAgentEndpointSettings(
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: apiKey,
            customHeaders: customHeaders,
            enabledModels: modelRows.filter { $0.enabled }.map {
                AppAgentModelRef(modelId: $0.candidate.modelId, apiProtocol: $0.candidate.apiProtocol)
            },
            contextWindow: contextWindow,
            maxTokens: maxTokens
        )
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }

    // MARK: - Field / nav actions

    @objc private func baseURLChanged() { baseURL = baseURLField.text ?? "" }
    @objc private func apiKeyChanged() { apiKey = apiKeyField.text ?? "" }

    @objc private func didTapCancel() { dismiss(animated: true) }

    @objc private func didTapSave() {
        let settings = currentSettings()
        guard !settings.baseURL.isEmpty else { showAlert("信息不完整", "请填写接口地址。"); return }
        guard !settings.enabledModels.isEmpty else {
            showAlert("尚未选择模型", "请至少勾选一个模型（可先「探查接口」或手动添加）。"); return
        }
        AppAgentSettingsStore.save(settings)
        onSave?(settings)
        dismiss(animated: true)
    }

    // MARK: - 探查接口 + 并行实测

    /// apiKey 右侧放大镜：拉取接口声明支持的模型（两种协议并行）+ 并行实测可用性。
    @objc private func didTapProbe() { runProbe(refetchList: true) }

    /// 模型区头部按钮：列表为空时等同「探查接口」，否则只对现有条目重测可用性。
    @objc private func didTapRetest() { runProbe(refetchList: modelRows.isEmpty) }

    private func runProbe(refetchList: Bool) {
        view.endEditing(true)
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { showAlert("信息不完整", "请先填写接口地址。"); return }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showAlert("信息不完整", "请先填写 API Key。"); return
        }
        guard !isBusy else { return }

        setBusy(true)
        let key = apiKey
        let headers = customHeaders
        let window = contextWindow
        let tokens = maxTokens

        Task { @MainActor in
            if refetchList {
                do {
                    let candidates = try await AppAgentModelDiscovery.discoverCandidates(
                        baseURL: base, apiKey: key, customHeaders: headers
                    )
                    self.mergeCandidates(candidates)
                    self.tableView.reloadData()
                } catch {
                    self.setBusy(false)
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    self.promptManualAdd(afterFailure: message)
                    return
                }
            }
            await self.testAllRows(
                baseURL: base, apiKey: key, customHeaders: headers, contextWindow: window, maxTokens: tokens
            )
            self.setBusy(false)
        }
    }

    /// 并行实测所有条目：每个结果一回来就刷新对应行，逐个点亮绿/红点。
    private func testAllRows(
        baseURL: String,
        apiKey: String,
        customHeaders: [String: String],
        contextWindow: Int,
        maxTokens: Int
    ) async {
        guard !modelRows.isEmpty else { return }
        for index in modelRows.indices { modelRows[index].probe = .testing }
        tableView.reloadSections(IndexSet(integer: Section.models.rawValue), with: .none)

        let candidates = modelRows.map { $0.candidate }
        let (stream, continuation) = AsyncStream<AppAgentModelAvailability>.makePair()
        let probe = Task.detached {
            await AppAgentModelDiscovery.probeAvailability(
                candidates: candidates,
                baseURL: baseURL,
                apiKey: apiKey,
                customHeaders: customHeaders,
                contextWindow: contextWindow,
                maxTokens: maxTokens
            ) { continuation.yield($0) }
            continuation.finish()
        }
        for await result in stream { applyAvailability(result) }
        _ = await probe.value
    }

    private func applyAvailability(_ result: AppAgentModelAvailability) {
        guard let index = modelRows.firstIndex(where: { $0.candidate == result.candidate }) else { return }
        modelRows[index].probe = result.isAvailable
            ? .available(result.firstTokenLatency ?? 0)
            : .unavailable(result.failureReason ?? "不可用")
        tableView.reloadRows(at: [IndexPath(row: index, section: Section.models.rawValue)], with: .none)
    }

    /// 忙碌态：apiKey 右侧按钮换成转圈，并同步模型区头部按钮的标题与禁用态。
    private func setBusy(_ busy: Bool) {
        isBusy = busy
        if busy {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.frame = CGRect(x: 0, y: 0, width: 34, height: 26)
            spinner.startAnimating()
            apiKeyField.rightView = spinner
        } else {
            apiKeyField.rightView = apiKeyProbeButton
        }
        tableView.reloadSections(IndexSet(integer: Section.models.rawValue), with: .none)
    }

    /// 合并探查结果：接口声明支持的全部「模型 × 协议」都列出；已有条目保留用户勾选与上次实测，
    /// 新条目默认未勾选。此前没有任何启用项时自动勾选第一条。
    private func mergeCandidates(_ candidates: [AppAgentModelCandidate]) {
        let known = Set(modelRows.map { $0.candidate })
        for candidate in candidates where !known.contains(candidate) {
            modelRows.append(ModelRow(candidate: candidate, enabled: false))
        }
        if !modelRows.contains(where: { $0.enabled }), !modelRows.isEmpty {
            modelRows[0].enabled = true
        }
    }

    /// 探查失败、或接口没列出想用的模型时，手动补一条（需指定协议）。
    private func promptManualAdd(afterFailure message: String?) {
        let title = message == nil ? "手动添加模型" : "探查失败"
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addTextField {
            $0.placeholder = "模型 id，如 gpt-4o"
            $0.autocapitalizationType = .none
            $0.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        for proto in AppAgentModelDiscovery.defaultCandidateProtocols {
            let action = UIAlertAction(
                title: "添加（\(Self.protocolDisplayName(proto))）", style: .default
            ) { [weak self, weak alert] _ in
                let text = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let self = self, let text = text, !text.isEmpty else { return }
                self.addManualRow(modelId: text, apiProtocol: proto)
            }
            alert.addAction(action)
        }
        present(alert, animated: true)
    }

    private func addManualRow(modelId: String, apiProtocol: APIProtocol) {
        let candidate = AppAgentModelCandidate(modelId: modelId, apiProtocol: apiProtocol)
        if let index = modelRows.firstIndex(where: { $0.candidate == candidate }) {
            modelRows[index].enabled = true
        } else {
            modelRows.append(ModelRow(candidate: candidate, enabled: true))
        }
        tableView.reloadData()
    }
}

extension AppAgentSettingsViewController: UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate {

    public func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .endpoint: return 2
        case .models: return modelRows.count + 1 // +1 = 手动添加
        }
    }

    public func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat { 40 }

    public func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let header = UIView()
        let label = UILabel()
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = AppAgentAppearance.secondaryText
        label.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 20),
            label.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -6)
        ])

        switch Section(rawValue: section)! {
        case .endpoint:
            label.text = "接口"
        case .models:
            label.text = "模型"
            let button = UIButton(type: .system)
            let idleTitle = modelRows.isEmpty ? "探查接口" : "重测可用性"
            button.setTitle(isBusy ? "探查中…" : idleTitle, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
            button.setTitleColor(AppAgentAppearance.accent, for: .normal)
            button.isEnabled = !isBusy
            button.addTarget(self, action: #selector(didTapRetest), for: .touchUpInside)
            button.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(button)
            NSLayoutConstraint.activate([
                button.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -18),
                button.centerYAnchor.constraint(equalTo: label.centerYAnchor)
            ])
        }
        return header
    }

    public func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .endpoint:
            return "填好地址与 API Key 后点右侧放大镜：并行探查 OpenAI / Anthropic 两种协议声明支持的模型。"
        case .models:
            return "同一模型支持两种协议时会分成两条，各自标注协议。绿点＝实测可用（附首 token 时长），"
                + "红点＝不可用，灰点＝未实测。勾选启用、拖动排序，第一条为默认模型，其余按序作为备选。"
        }
    }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section)! {
        case .endpoint:
            return fieldCell(indexPath.row == 0 ? baseURLField : apiKeyField,
                             title: indexPath.row == 0 ? "接口地址" : "API Key")
        case .models:
            if indexPath.row == modelRows.count {
                let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
                cell.backgroundColor = AppAgentAppearance.inputBarBackground
                cell.textLabel?.text = "＋ 手动添加模型"
                cell.textLabel?.textColor = AppAgentAppearance.accent
                return cell
            }
            let row = modelRows[indexPath.row]
            let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
            cell.backgroundColor = AppAgentAppearance.inputBarBackground
            cell.imageView?.image = UIImage(systemName: row.enabled ? "checkmark.circle.fill" : "circle")
            cell.imageView?.tintColor = row.enabled ? AppAgentAppearance.accent : AppAgentAppearance.secondaryText
            cell.textLabel?.text = row.candidate.modelId
            cell.textLabel?.textColor = AppAgentAppearance.primaryText
            cell.textLabel?.numberOfLines = 1
            cell.textLabel?.lineBreakMode = .byTruncatingMiddle
            cell.detailTextLabel?.attributedText = Self.statusLine(for: row)
            cell.detailTextLabel?.numberOfLines = 1
            cell.detailTextLabel?.lineBreakMode = .byTruncatingTail
            cell.accessibilityLabel = "\(row.candidate.modelId)，\(Self.statusText(for: row))，\(row.enabled ? "已启用" : "未启用")"
            cell.showsReorderControl = true
            return cell
        }
    }

    /// 「● 协议 · 状态」一行：圆点用颜色表达实测结果。
    private static func statusLine(for row: ModelRow) -> NSAttributedString {
        let line = NSMutableAttributedString(
            string: "● ", attributes: [.foregroundColor: statusColor(for: row.probe)]
        )
        line.append(NSAttributedString(
            string: statusText(for: row), attributes: [.foregroundColor: AppAgentAppearance.secondaryText]
        ))
        return line
    }

    private static func statusColor(for state: ProbeState) -> UIColor {
        switch state {
        case .untested: return .systemGray
        case .testing: return .systemOrange
        case .available: return .systemGreen
        case .unavailable: return .systemRed
        }
    }

    private static func statusText(for row: ModelRow) -> String {
        let proto = protocolDisplayName(row.candidate.apiProtocol)
        switch row.probe {
        case .untested: return "\(proto) · 未实测"
        case .testing: return "\(proto) · 实测中…"
        case .available(let latency): return "\(proto) · 首 token \(String(format: "%.2f", latency))s"
        case .unavailable(let reason): return "\(proto) · 不可用（\(reason)）"
        }
    }

    /// 内嵌文本框的输入行：左侧标题，右侧文本框。
    private func fieldCell(_ field: UITextField, title: String) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.backgroundColor = AppAgentAppearance.inputBarBackground
        cell.selectionStyle = .none

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        titleLabel.textColor = AppAgentAppearance.primaryText
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)

        field.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(titleLabel)
        cell.contentView.addSubview(field)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 16),
            titleLabel.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -16),
            field.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 6),
            field.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -6)
        ])
        field.textAlignment = .right
        return cell
    }

    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard Section(rawValue: indexPath.section) == .models else { return }
        if indexPath.row == modelRows.count {
            promptManualAdd(afterFailure: nil)
        } else {
            modelRows[indexPath.row].enabled.toggle()
            tableView.reloadRows(at: [indexPath], with: .none)
        }
    }

    // MARK: - 拖拽调整优先级（常驻编辑态，勾选仍走点击）

    public func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        indexPath.section == Section.models.rawValue && indexPath.row < modelRows.count
    }

    public func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle { .none }

    public func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool { false }

    public func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        indexPath.section == Section.models.rawValue && indexPath.row < modelRows.count
    }

    public func tableView(_ tableView: UITableView, targetIndexPathForMoveFromRowAt sourceIndexPath: IndexPath, toProposedIndexPath proposed: IndexPath) -> IndexPath {
        guard proposed.section == Section.models.rawValue else {
            return IndexPath(row: max(0, modelRows.count - 1), section: Section.models.rawValue)
        }
        return IndexPath(row: min(proposed.row, modelRows.count - 1), section: Section.models.rawValue)
    }

    public func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        let dest = min(destinationIndexPath.row, modelRows.count - 1)
        let moved = modelRows.remove(at: sourceIndexPath.row)
        modelRows.insert(moved, at: dest)
    }

    // MARK: - UITextFieldDelegate

    public func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }



}
#endif
