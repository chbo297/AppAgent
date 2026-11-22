//
//  AppAgentSettingsMenuViewController.swift
//  AppAgentUI
//
//  设置落地页：「模型配置」（进入现有的模型/API 设置页）、「语音识别」（打包了多个识别引擎时
//  才出现，进入引擎切换页）与「总是显示思考过程」开关（旁边的 ⓘ 点开浮窗解释）。
//

#if canImport(UIKit)
import UIKit

final class AppAgentSettingsMenuViewController: UITableViewController {
    /// 保存或清除后的回调；清除时透传空配置，调用方仍须应用到运行时。
    var onModelSettingsSaved: ((AppAgentEndpointSettings) -> Void)?
    /// 「总是显示思考过程」开关变化后的回调（宿主据此重建当前会话列表）。
    var onAlwaysShowThinkingChanged: ((Bool) -> Void)?

    private enum Row: Int, CaseIterable {
        case modelConfig, voiceRecognition, alwaysShowThinking
    }

    /// 只打包了系统识别时没有可切换的引擎，「语音识别」入口不展示。
    private var rows: [Row] {
        Row.allCases.filter { row in
            row != .voiceRecognition || AppAgentVoiceRecognitionCentral.default.engines.count > 1
        }
    }

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "设置"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(done)
        )
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 从语音识别页返回时刷新右侧的当前引擎名。
        tableView.reloadData()
    }

    @objc private func done() { dismiss(animated: true) }

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.accessoryView = nil
        cell.accessoryType = .none
        cell.selectionStyle = .default
        switch rows[indexPath.row] {
        case .modelConfig:
            cell.textLabel?.text = "模型配置"
            cell.accessoryType = .disclosureIndicator
        case .voiceRecognition:
            cell.textLabel?.text = "语音识别"
            cell.detailTextLabel?.text = AppAgentVoiceRecognitionCentral.default.activeEngine.displayName
            cell.accessoryType = .disclosureIndicator
        case .alwaysShowThinking:
            cell.textLabel?.text = "总是显示思考过程"
            cell.selectionStyle = .none
            cell.accessoryView = makeThinkingAccessory()
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch rows[indexPath.row] {
        case .modelConfig:
            let modelVC = AppAgentSettingsViewController()
            modelVC.onSave = { [weak self] settings in
                self?.onModelSettingsSaved?(settings)
            }
            navigationController?.pushViewController(modelVC, animated: true)
        case .voiceRecognition:
            navigationController?.pushViewController(AppAgentVoiceRecognitionSettingsViewController(), animated: true)
        case .alwaysShowThinking:
            break
        }
    }

    // MARK: - 「总是显示思考过程」开关 + ⓘ 说明

    /// accessoryView = [ⓘ 信息按钮] + [开关]，横向排布。
    private func makeThinkingAccessory() -> UIView {
        let info = UIButton(type: .infoLight)
        info.addTarget(self, action: #selector(showThinkingInfo), for: .touchUpInside)

        let toggle = UISwitch()
        toggle.isOn = AppAgentSettingsStore.alwaysShowThinkingProcess
        toggle.addTarget(self, action: #selector(thinkingToggleChanged(_:)), for: .valueChanged)

        let stack = UIStackView(arrangedSubviews: [info, toggle])
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        stack.frame = CGRect(x: 0, y: 0, width: stack.systemLayoutSizeFitting(
            UIView.layoutFittingCompressedSize
        ).width, height: 32)
        return stack
    }

    @objc private func thinkingToggleChanged(_ sender: UISwitch) {
        AppAgentSettingsStore.alwaysShowThinkingProcess = sender.isOn
        onAlwaysShowThinkingChanged?(sender.isOn)
    }

    @objc private func showThinkingInfo() {
        let message = """
        打开后：即使某轮成功给出最终结果，也会在结果上方保留可展开的「处理过程」入口（小三角 + 标题）。

        关闭后：成功的回复只显示最终结果，界面更干净。

        无论开关状态，报错或异常的回合都会保留过程入口（默认收起），并在结果下方给出错误摘要。
        """
        let alert = UIAlertController(title: "总是显示思考过程", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .default))
        present(alert, animated: true)
    }
}
#endif
