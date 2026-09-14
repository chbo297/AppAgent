//
//  LijiPanelViewController.swift
//  OpenAPP — Liji 面板 UI
//
//  「需求列表 / 分享给我的」个人中心容器：顶部分段控制切换两个列表，
//  数据来自注入的 LijiServerClient，动作（应用/分享/取消/重新生成/开关）直接调用对应 API。
//  分享成功后用系统分享面板呈现二维码图片 URL 供用户发送。
//

#if canImport(UIKit)
import UIKit

public final class LijiPanelViewController: UIViewController {
    private let client: LijiServerClient
    private let segmented = UISegmentedControl(items: ["我的需求", "分享给我的"])
    private let requirementList = LijiRequirementListView()
    private let grantList = LijiGrantListView()

    public init(client: LijiServerClient) {
        self.client = client
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = "app agent 个人中心"
        view.backgroundColor = .systemBackground

        segmented.selectedSegmentIndex = 0
        segmented.addTarget(self, action: #selector(segmentChanged), for: .valueChanged)
        segmented.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(segmented)

        requirementList.translatesAutoresizingMaskIntoConstraints = false
        requirementList.onAction = { [weak self] row, action in self?.handle(row: row, action: action) }
        requirementList.onRefresh = { [weak self] in self?.reloadRequirements() }
        view.addSubview(requirementList)

        grantList.translatesAutoresizingMaskIntoConstraints = false
        grantList.isHidden = true
        grantList.onToggle = { [weak self] row, enabled in self?.toggleGrant(row, enabled: enabled) }
        grantList.onRefresh = { [weak self] in self?.reloadGrants() }
        view.addSubview(grantList)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            segmented.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            segmented.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            segmented.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),

            requirementList.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 8),
            requirementList.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            requirementList.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            requirementList.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            grantList.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 8),
            grantList.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            grantList.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            grantList.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        reloadRequirements()
    }

    @objc private func segmentChanged() {
        let showRequirements = segmented.selectedSegmentIndex == 0
        requirementList.isHidden = !showRequirements
        grantList.isHidden = showRequirements
        if showRequirements { reloadRequirements() } else { reloadGrants() }
    }

    private func reloadRequirements() {
        Task { @MainActor in
            do {
                let tasks = try await client.listTasks()
                requirementList.setRows(LijiPanelDataSource.requirementRows(from: tasks))
            } catch {
                requirementList.setRows([])
            }
        }
    }

    private func reloadGrants() {
        Task { @MainActor in
            do {
                let grants = try await client.granted()
                grantList.setRows(LijiPanelDataSource.grantRows(from: grants))
            } catch {
                grantList.setRows([])
            }
        }
    }

    private func handle(row: LijiRequirementRow, action: LijiRequirementAction) {
        Task { @MainActor in
            do {
                switch action {
                case .apply:
                    guard let patchId = row.patchId else { return }
                    _ = try await client.downloadPatch(patchId: patchId)
                    // 下载后的实际应用需宿主注入 HotfixProvider（见 HotfixTool / BMBandageHotfixAdapter）。
                case .share:
                    guard let patchId = row.patchId else { return }
                    let share = try await client.share(patchId: patchId)
                    presentShareSheet(url: share.shareUrl)
                case .cancel:
                    _ = try await client.updateStatus(requirementId: row.id, status: "disabled")
                case .regenerate:
                    _ = try await client.regenerate(requirementId: row.id)
                }
                reloadRequirements()
            } catch {
                reloadRequirements()
            }
        }
    }

    private func toggleGrant(_ row: LijiGrantRow, enabled: Bool) {
        Task { @MainActor in
            _ = try? await client.toggleGrant(token: row.token, enabled: enabled)
            reloadGrants()
        }
    }

    private func presentShareSheet(url: String) {
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        present(sheet, animated: true)
    }
}

#endif
