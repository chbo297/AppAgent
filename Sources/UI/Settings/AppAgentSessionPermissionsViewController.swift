//
//  AppAgentSessionPermissionsViewController.swift
//  AppAgentUI
//
//  会话设置：列出宿主登记的权限和它们在当前会话里的状态，可直接修改或撤销。
//

#if canImport(UIKit)
import UIKit

final class AppAgentSessionPermissionsViewController: UITableViewController {
    /// 权限有改动后回调，调用方据此保存会话。
    var onPermissionsChanged: ((AISession) -> Void)?

    private let session: AISession
    private var permissions: [AppAgentPermission] = []

    init(session: AISession) {
        self.session = session
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "会话设置"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(done)
        )
        permissions = session.registeredPermissions
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(permissionStoreChanged),
            name: AppAgentPermissionStore.didChangeNotification,
            object: nil
        )
    }

    @objc private func done() {
        dismiss(animated: true)
    }

    @objc private func permissionStoreChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.tableView.reloadData()
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        1
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        "权限"
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if permissions.isEmpty {
            return nil
        }
        return "「在本会话中允许」只对当前会话生效；「始终允许」对本设备上的所有会话生效。选「每次询问」会同时撤销这两种授权。"
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        max(permissions.count, 1)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        guard permissions.indices.contains(indexPath.row) else {
            cell.textLabel?.text = "当前 App 没有需要授权的权限"
            cell.textLabel?.textColor = .secondaryLabel
            cell.selectionStyle = .none
            return cell
        }
        let permission = permissions[indexPath.row]
        cell.textLabel?.text = permission.title
        cell.detailTextLabel?.text = permission.summary
        cell.detailTextLabel?.numberOfLines = 0
        cell.detailTextLabel?.textColor = .secondaryLabel
        let status = UILabel()
        status.text = Self.label(for: session.permissionGrant(for: permission))
        status.font = .systemFont(ofSize: 15)
        status.textColor = .secondaryLabel
        status.sizeToFit()
        cell.accessoryView = status
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard permissions.indices.contains(indexPath.row) else {
            return
        }
        let permission = permissions[indexPath.row]
        let current = session.permissionGrant(for: permission)
        let sheet = UIAlertController(title: permission.title, message: permission.summary, preferredStyle: .actionSheet)
        for grant in AppAgentPermissionGrant.allCases {
            let title = grant == current ? "✓ " + Self.label(for: grant) : Self.label(for: grant)
            sheet.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                self?.apply(grant, to: permission)
            })
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let popover = sheet.popoverPresentationController, let cell = tableView.cellForRow(at: indexPath) {
            popover.sourceView = cell
            popover.sourceRect = cell.bounds
        }
        present(sheet, animated: true)
    }

    private func apply(_ grant: AppAgentPermissionGrant, to permission: AppAgentPermission) {
        session.setPermissionGrant(grant, for: permission)
        tableView.reloadData()
        onPermissionsChanged?(session)
    }

    static func label(for grant: AppAgentPermissionGrant) -> String {
        switch grant {
        case .ask:
            return "每次询问"
        case .session:
            return "在本会话中允许"
        case .always:
            return "始终允许"
        }
    }
}

extension AppAgentViewController {
    /// 对话页顶部栏的设置按钮：打开当前会话的权限列表。
    func presentSessionSettings() {
        guard let session = currentSession else {
            return
        }
        let settingsVC = AppAgentSessionPermissionsViewController(session: session)
        settingsVC.onPermissionsChanged = { [weak self] session in
            guard let agent = self?.agent else {
                return
            }
            Task {
                try? await agent.sessionManager.saveSession(session)
            }
        }
        let nav = UINavigationController(rootViewController: settingsVC)
        nav.modalPresentationStyle = .formSheet

        var presenter: UIViewController = self
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        presenter.present(nav, animated: true)
    }
}
#endif
