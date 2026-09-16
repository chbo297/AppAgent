//
//  AppAgentPresentationDelegate.swift
//  AppAgentUI
//

#if canImport(UIKit)
import Foundation

/// UI-layer presentation events emitted by the AppAgent chat surface.
///
/// Split out from `AIAgentDelegate` on purpose: run start/stop/complete are *core*
/// concepts (they live alongside `didCompleteRun` on the agent), whereas "which session
/// is currently displayed" and "is the chat panel visible" are purely UI concepts. The
/// core `AIAgent` has no notion of a current session or panel visibility and must not
/// depend on the UI layer, so these events get their own `@MainActor` protocol driven by
/// `AppAgentViewController` / `AppAgentOverlay`.
///
/// The host (e.g. the bound-page coordinator) adopts this to show/hide/refresh the page
/// bound to the active session.
@MainActor
public protocol AppAgentPresentationDelegate: AnyObject {
    /// The displayed session changed. `old` is the previously bound session id (nil on first bind),
    /// `new` is the now-current session id (nil if unbound).
    func appAgent(didSwitchSessionFrom old: String?, to new: String?)

    /// The chat panel (overlay window) is about to become visible.
    func appAgentChatPanelWillShow()

    /// The chat panel (overlay window) has been hidden.
    func appAgentChatPanelDidHide()
}

// Default no-op implementations so adopters implement only what they need.
public extension AppAgentPresentationDelegate {
    func appAgent(didSwitchSessionFrom old: String?, to new: String?) {}
    func appAgentChatPanelWillShow() {}
    func appAgentChatPanelDidHide() {}
}

#endif
