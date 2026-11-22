//
//  AppAgentVoiceRecognitionSettingsViewController.swift
//  AppAgentUI
//
//  语音识别引擎切换页：列出本次打包注册进来的全部引擎，勾选即生效（下一次语音输入起）。
//  需要凭据的引擎点右侧 ⓘ 进它自己的配置页；选中但未配置时提示并实际回退到系统识别。
//

#if canImport(AVFoundation) && canImport(Speech) && (os(iOS) || targetEnvironment(macCatalyst))
import UIKit

final class AppAgentVoiceRecognitionSettingsViewController: UITableViewController {
    private let central: AppAgentVoiceRecognitionCentral

    init(central: AppAgentVoiceRecognitionCentral = .default) {
        self.central = central
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "语音识别"
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 从引擎配置页返回后，「未配置」提示可能已经消失。
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        central.engines.count
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        let selected = central.selectedEngineID
        guard let engine = central.engine(id: selected), !engine.isConfigured() else {
            return "切换后从下一次语音输入开始生效。"
        }
        return "「\(engine.displayName)」尚未配置，当前实际使用系统识别。点右侧 ⓘ 完成配置。"
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let engine = central.engines[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = engine.displayName
        cell.detailTextLabel?.text = engine.isConfigured() ? engine.summary : "未配置 · \(engine.summary)"
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.detailTextLabel?.numberOfLines = 0
        let isSelected = engine.id == central.selectedEngineID
        cell.accessoryType = engine.makeSettingsViewController == nil ? .none : .detailButton
        cell.imageView?.image = UIImage(systemName: isSelected ? "checkmark.circle.fill" : "circle")
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let engine = central.engines[indexPath.row]
        central.selectedEngineID = engine.id
        tableView.reloadData()
        // 选中一个还没配置的引擎：直接带去配置页，省得用户再找入口。
        if !engine.isConfigured() {
            openSettings(for: engine)
        }
    }

    override func tableView(_ tableView: UITableView, accessoryButtonTappedForRowWith indexPath: IndexPath) {
        openSettings(for: central.engines[indexPath.row])
    }

    private func openSettings(for engine: AppAgentVoiceRecognitionEngine) {
        guard let settingsVC = engine.makeSettingsViewController?() else {
            return
        }
        navigationController?.pushViewController(settingsVC, animated: true)
    }
}
#endif
