//
//  AppAgentDebugViewController.swift
//  AppAgentUI
//
//  调试窗口：实时展示模型接口调用记录（请求 / 成功 / 失败 / 重试 / 模型回退），
//  支持只看异常、清空、以及导出（文本 / JSON，分享或复制到剪贴板）。
//

#if canImport(UIKit)
import UIKit

public final class AppAgentDebugViewController: UIViewController {

    private let log: AppAgentDebugLog
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let statusLabel = UILabel()
    private let filterControl = UISegmentedControl(items: ["全部", "仅异常"])

    /// 当前展示的记录（倒序：最新在最上）。
    private var rows: [AppAgentDebugEvent] = []
    /// 是否跟随最新（列表滚到顶部时为真）。
    private var onlyFailures = false

    public init(log: AppAgentDebugLog = .shared) {
        self.log = log
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        self.log = .shared
        super.init(coder: coder)
    }

    deinit {
        log.onEvent = nil
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = "调试"
        view.backgroundColor = AppAgentAppearance.overlayBackground

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "关闭", style: .plain, target: self, action: #selector(didTapClose)
        )
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(barButtonSystemItem: .action, target: self, action: #selector(didTapExport)),
            UIBarButtonItem(barButtonSystemItem: .trash, target: self, action: #selector(didTapClear))
        ]

        filterControl.selectedSegmentIndex = 0
        filterControl.addTarget(self, action: #selector(filterChanged), for: .valueChanged)

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = AppAgentAppearance.secondaryText
        statusLabel.textAlignment = .center

        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 56
        view.addSubview(filterControl)
        view.addSubview(statusLabel)
        view.addSubview(tableView)

        reload()
        // 实时订阅：新记录到达即插入列表顶部。
        log.onEvent = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reload()
            }
        }
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let top = view.safeAreaInsets.top
        filterControl.frame = CGRect(x: 16, y: top + 8, width: view.bounds.width - 32, height: 30)
        statusLabel.frame = CGRect(x: 16, y: filterControl.frame.maxY + 6, width: view.bounds.width - 32, height: 16)
        let listTop = statusLabel.frame.maxY + 6
        tableView.frame = CGRect(
            x: 0, y: listTop, width: view.bounds.width, height: max(0, view.bounds.height - listTop)
        )
    }

    // MARK: - Data

    private func reload() {
        let all = log.snapshot()
        let filtered = onlyFailures
            ? all.filter { $0.kind == .failure || $0.kind == .retry || $0.kind == .fallback }
            : all
        rows = filtered.reversed()
        let failureCount = all.filter { $0.kind == .failure }.count
        let retryCount = all.filter { $0.kind == .retry }.count
        let fallbackCount = all.filter { $0.kind == .fallback }.count
        statusLabel.text = "共 \(all.count) 条 · 失败 \(failureCount) · 重试 \(retryCount) · 回退 \(fallbackCount)"
        tableView.reloadData()
    }

    // MARK: - Actions

    @objc private func didTapClose() {
        dismiss(animated: true)
    }

    @objc private func filterChanged() {
        onlyFailures = filterControl.selectedSegmentIndex == 1
        reload()
    }

    @objc private func didTapClear() {
        log.clear()
        reload()
    }

    /// 导出：文本或 JSON，分享面板 + 复制到剪贴板兜底。
    @objc private func didTapExport() {
        let sheet = UIAlertController(title: "导出调试信息", message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "分享文本", style: .default) { [weak self] _ in
            self?.share(text: self?.log.exportText() ?? "", fileName: "appagent-debug.log")
        })
        sheet.addAction(UIAlertAction(title: "分享 JSON", style: .default) { [weak self] _ in
            self?.share(text: self?.log.exportJSON() ?? "", fileName: "appagent-debug.json")
        })
        sheet.addAction(UIAlertAction(title: "复制到剪贴板", style: .default) { [weak self] _ in
            guard let self = self else { return }
            UIPasteboard.general.string = self.log.exportText()
            self.toast("已复制 \(self.rows.count) 条记录")
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.barButtonItem = navigationItem.rightBarButtonItems?.first
        }
        present(sheet, animated: true)
    }

    /// 写入临时文件后走系统分享（可存文件、发消息、拷贝）。
    private func share(text: String, fileName: String) {
        guard !text.isEmpty else { toast("暂无记录"); return }
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(fileName)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            UIPasteboard.general.string = text
            toast("写文件失败，已复制到剪贴板")
            return
        }
        let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = share.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: 40, width: 1, height: 1)
        }
        present(share, animated: true)
    }

    private func toast(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        present(alert, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            alert.dismiss(animated: true)
        }
    }

    static func color(for kind: AppAgentDebugEvent.Kind) -> UIColor {
        switch kind {
        case .request: return .systemGray
        case .success: return .systemGreen
        case .failure: return .systemRed
        case .retry: return .systemOrange
        case .fallback: return .systemBlue
        case .info: return .systemTeal
        }
    }
}

extension AppAgentDebugViewController: UITableViewDataSource, UITableViewDelegate {

    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        max(rows.count, 1)
    }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = .clear
        cell.selectionStyle = .none
        cell.textLabel?.numberOfLines = 0
        cell.textLabel?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        cell.detailTextLabel?.numberOfLines = 0
        cell.detailTextLabel?.font = .systemFont(ofSize: 11)
        cell.detailTextLabel?.textColor = AppAgentAppearance.secondaryText

        guard !rows.isEmpty else {
            cell.textLabel?.text = "暂无记录：发起一次对话或在设置页「探查接口」后再回来看。"
            cell.textLabel?.textColor = AppAgentAppearance.secondaryText
            return cell
        }

        let event = rows[indexPath.row]
        let head = NSMutableAttributedString(
            string: "● ", attributes: [.foregroundColor: Self.color(for: event.kind)]
        )
        head.append(NSAttributedString(
            string: event.line, attributes: [.foregroundColor: AppAgentAppearance.primaryText]
        ))
        cell.textLabel?.attributedText = head
        if let sessionId = event.sessionId {
            cell.detailTextLabel?.text = "session \(sessionId.prefix(8))"
        }
        return cell
    }

    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard indexPath.row < rows.count else { return }
        UIPasteboard.general.string = rows[indexPath.row].line
        toast("已复制该条记录")
    }
}
#endif

