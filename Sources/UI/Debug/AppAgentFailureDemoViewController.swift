#if canImport(UIKit)
import UIKit

/// 独立演示页复用真正的 ChatPanel / session 事件消费，关闭后原会话与草稿原样保留。
final class AppAgentFailureDemoViewController: UIViewController {
    let chat = AppAgentViewController()
    private(set) var demo: AppAgentFailureDemo?
    private(set) var playbackTask: Task<Void, Never>?
    private var didStart = false
    private var generation = UUID()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "报错演示 · 仅本地"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "关闭", style: .plain, target: self, action: #selector(close)
        )
        setPlaybackButton(running: true)
        chat.registersDecisionPresenter = false
        addChild(chat)
        chat.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(chat.view)
        NSLayoutConstraint.activate([
            chat.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            chat.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            chat.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            chat.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        chat.didMove(toParent: self)
        // 演示只能由脚本发送，避免手输/语音/切会话与自动播放交错。
        chat.inputBar.isUserInteractionEnabled = false
        chat.inputBar.alpha = 0.5
        chat.chatPanelView.onSessionListRequested = nil
        chat.chatPanelView.onNewSessionRequested = nil
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didStart else { return }
        didStart = true
        startPlayback()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopPlayback()
    }

    deinit {
        playbackTask?.cancel()
        demo?.session.cancel()
    }

    /// generation 阻止停止/关闭/重播期间的旧 await 续跑；不强持有控制器跨轮等待。
    func startPlayback(stepDelay: UInt64 = 450_000_000, betweenTurns: UInt64 = 1_500_000_000) {
        stopPlayback()
        let token = UUID()
        generation = token
        setPlaybackButton(running: true)
        playbackTask = Task { @MainActor [weak self] in
            let demo = await AppAgentFailureDemo.make(stepDelay: stepDelay)
            guard !Task.isCancelled, self?.generation == token else { return }
            self?.demo = demo
            self?.chat.agent = demo.agent
            self?.chat.switchSession(to: demo.session.id)
            self?.chat.view.layoutIfNeeded()
            self?.chat.setChatPanelDetent(.full, animated: false)
            for (index, scenario) in AppAgentFailureDemo.Scenario.allCases.enumerated() {
                guard !Task.isCancelled, self?.generation == token else { return }
                await demo.prepare(scenario)
                guard !Task.isCancelled, self?.generation == token else { return }
                self?.title = "报错演示 \(index + 1)/\(AppAgentFailureDemo.Scenario.allCases.count)"
                self?.chat.sendMessage(text: scenario.message)
                // 等整条流关闭（executor 已清理本轮），不在终止事件到达时抢发下一轮。
                let streamTask = self?.chat.currentStreamTask
                await streamTask?.value
                guard !Task.isCancelled, self?.generation == token else { return }
                guard demo.session.turnRecords[demo.session.currentTurnID]?.outcome != .cancelled else {
                    self?.stopPlayback()
                    return
                }
                do { try await Task.sleep(nanoseconds: betweenTurns) }
                catch { return }
            }
            guard self?.generation == token else { return }
            self?.title = "演示完成 · 可展开查看"
            self?.playbackTask = nil
            self?.setPlaybackButton(running: false)
        }
    }

    func stopPlayback() {
        generation = UUID()
        playbackTask?.cancel()
        playbackTask = nil
        demo?.session.cancel()
        title = "演示已停止 · 可展开查看"
        setPlaybackButton(running: false)
    }

    private func setPlaybackButton(running: Bool) {
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: running ? "停止" : "重播",
            style: .plain, target: self,
            action: running ? #selector(stopTapped) : #selector(replayTapped)
        )
    }

    @objc private func stopTapped() { stopPlayback() }
    @objc private func replayTapped() { startPlayback() }
    @objc private func close() {
        stopPlayback()
        chat.currentStreamTask?.cancel()
        dismiss(animated: true)
    }
}
#endif
