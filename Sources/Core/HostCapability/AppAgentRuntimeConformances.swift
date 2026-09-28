// Explicit identities also work when the SDK is compiled into the host module.
// Do not mark integration protocols: host implementations remain host-owned.
extension AIAgent: AppAgentRuntimeOwned {}
extension AIAgentCentral: AppAgentRuntimeOwned {}
extension AISession: AppAgentRuntimeOwned {}
extension AISessionManager: AppAgentRuntimeOwned {}
extension LLMExecutor: AppAgentRuntimeOwned {}
extension RunGovernor: AppAgentRuntimeOwned {}
extension SessionUIState: AppAgentRuntimeOwned {}
extension DecisionResponderCentral: AppAgentRuntimeOwned {}
extension InMemorySessionStorage: AppAgentRuntimeOwned {}
extension FileSessionStorage: AppAgentRuntimeOwned {}
extension ToolCentral: AppAgentRuntimeOwned {}
extension ModelProviderCentral: AppAgentRuntimeOwned {}
extension AnthropicProvider: AppAgentRuntimeOwned {}
extension MemoryStore: AppAgentRuntimeOwned {}
extension HotMemory: AppAgentRuntimeOwned {}
extension InMemoryMemoryStorage: AppAgentRuntimeOwned {}
extension FileMemoryStorage: AppAgentRuntimeOwned {}
extension SkillsManager: AppAgentRuntimeOwned {}
extension TodoTool: AppAgentRuntimeOwned {}
extension AppAgentDebugLog: AppAgentRuntimeOwned {}
extension AppAgentRunLog: AppAgentRuntimeOwned {}
extension AppAgentFailureDemo: AppAgentRuntimeOwned {}
extension AppAgentFailureDemoProvider: AppAgentRuntimeOwned {}
extension UnfairLock: AppAgentRuntimeOwned {}
extension ReadersWriterLock: AppAgentRuntimeOwned {}
extension ReadySignal: AppAgentRuntimeOwned {}
extension ConcurrencyLimiter: AppAgentRuntimeOwned {}
extension Locked: AppAgentRuntimeOwned {}
extension WeakLocked: AppAgentRuntimeOwned {}
extension TrackedLocked: AppAgentRuntimeOwned {}

#if canImport(UIKit)
extension DefaultRuntimeInspectProvider: AppAgentRuntimeOwned {}
extension AppAgentWindow: AppAgentRuntimeOwned {}
extension AppAgentOverlay: AppAgentRuntimeOwned {}
extension AppAgentViewController: AppAgentRuntimeOwned {}
extension AppAgentInputBar: AppAgentRuntimeOwned {}
extension AppAgentMenuButton: AppAgentRuntimeOwned {}
extension AppAgentTextField: AppAgentRuntimeOwned {}
extension AppAgentKeyboardObserver: AppAgentRuntimeOwned {}
extension AppAgentVoiceRecognitionManager: AppAgentRuntimeOwned {}
extension AppAgentDebugViewController: AppAgentRuntimeOwned {}
extension AppAgentFailureDemoViewController: AppAgentRuntimeOwned {}
extension AppAgentRegionDebugViewController: AppAgentRuntimeOwned {}
extension AppAgentRegionDebugOverlay: AppAgentRuntimeOwned {}
extension AppAgentRegionDebugWindow: AppAgentRuntimeOwned {}
extension AppAgentRegionOutlineView: AppAgentRuntimeOwned {}
extension AppAgentRegionDebugPanelView: AppAgentRuntimeOwned {}
extension AppAgentSettingsViewController: AppAgentRuntimeOwned {}
extension AppAgentChatPanelCoordinator: AppAgentRuntimeOwned {}
extension AppAgentChatPanelContainerView: AppAgentRuntimeOwned {}
extension AppAgentChatPanelView: AppAgentRuntimeOwned {}
extension AppAgentChatPanelNavigationBar: AppAgentRuntimeOwned {}
extension AppAgentChatMessageListView: AppAgentRuntimeOwned {}
extension AppAgentChatScrollTrace: AppAgentRuntimeOwned {}
extension AppAgentActivityView: AppAgentRuntimeOwned {}
extension AppAgentRunStageStripView: AppAgentRuntimeOwned {}
extension AppAgentDecisionCardView: AppAgentRuntimeOwned {}
extension AppAgentDecisionPresenter: AppAgentRuntimeOwned {}
extension ChatMessageCell: AppAgentRuntimeOwned {}
extension ChatMessageHeightCache: AppAgentRuntimeOwned {}
extension AppAgentSessionSidebarView: AppAgentRuntimeOwned {}
extension AppAgentSessionListView: AppAgentRuntimeOwned {}
extension AppAgentVoiceInputCoordinator: AppAgentRuntimeOwned {}
extension AppAgentVoiceInputOverlayView: AppAgentRuntimeOwned {}
extension AppAgentVoiceEditModeSession: AppAgentRuntimeOwned {}
extension AppAgentVoiceBubbleView: AppAgentRuntimeOwned {}
extension AppAgentVoiceBottomPanelView: AppAgentRuntimeOwned {}
extension AppAgentVoiceWaveformView: AppAgentRuntimeOwned {}
extension AppAgentVoiceActionZoneView: AppAgentRuntimeOwned {}
#endif

#if canImport(UIKit) && canImport(JavaScriptCore)
extension DefaultHotfixProvider: AppAgentRuntimeOwned {}
#endif
